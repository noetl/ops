-- Post-run SQL probes for the R-2.3 Phase C2 full trust-boundary
-- kind-validation rig (server TLS + client TLS + bearer + mTLS).
-- Pairs with `flight-tls-validation.yaml` + `validate-flight-tls.sh`.
--
-- Usage (invoked by the runner; not typically run by hand):
--   kubectl --context kind-noetl -n postgres exec deployment/postgres -- \
--     psql -U noetl -d noetl -v exec_id=<execution_id> \
--     -f /tmp/validate-flight-tls.sql

-- =============================================================
-- 1. producer step — same over-budget shape as the no-auth rig;
--    confirm the durable result-store + Arrow IPC ref still works
--    when the cluster is locked down for mTLS + bearer.
-- =============================================================

\echo '== producer step result.reference =='
SELECT
    event_id,
    node_name,
    result ? 'reference' AS has_reference,
    result#>>'{reference,kind}' AS reference_kind,
    result#>>'{reference,ref}' AS reference_ref,
    result#>>'{reference,ipc,media_type}' AS ipc_media_type,
    result#>>'{reference,ipc,row_count}' AS ipc_row_count
FROM noetl.event
WHERE execution_id = :exec_id
  AND node_name = 'producer'
  AND event_type = 'call.done'
ORDER BY event_id DESC
LIMIT 1;

-- Expected:
--   has_reference   = t
--   reference_kind  = 'result_ref'
--   ipc_media_type  = 'application/vnd.apache.arrow.stream'
--   ipc_row_count   = '6000'

-- =============================================================
-- 2. fetch_via_flight_secure — the worker negotiated TLS with the
--    server, presented its client cert (mTLS), included the bearer
--    token, and the call.done shows the fetched result.  Failure
--    modes (cert mismatch, bad token, etc.) surface as
--    call.error with an `unauthenticated` / TLS-handshake-shaped
--    error message — that's the negative test the manual
--    inspection follows up on.
-- =============================================================

\echo '== fetch_via_flight_secure call.done =='
SELECT
    event_id,
    node_name,
    status,
    result#>>'{context,status}' AS fetch_status,
    result#>>'{context,reference,ref}' AS new_ref,
    result#>>'{context,reference,meta,bytes}' AS bytes,
    result#>>'{context,error}' AS error
FROM noetl.event
WHERE execution_id = :exec_id
  AND node_name = 'fetch_via_flight_secure'
  AND event_type IN ('call.done', 'call.error')
ORDER BY event_id DESC
LIMIT 1;

-- Expected on success:
--   status        = 'COMPLETED'
--   fetch_status  = 'success'
--   new_ref       LIKE 'noetl://execution/.../result/fetch_via_flight_secure/%'
--   error         IS NULL

-- =============================================================
-- 3. Lifecycle counts — sanity-check that every step ran exactly
--    once.  A retry storm would show inflated counts; an auth
--    rejection that the worker classified as transport would
--    cause the producer to be rescheduled.
-- =============================================================

\echo '== Step lifecycle counts =='
SELECT
    node_name,
    event_type,
    COUNT(*) AS n
FROM noetl.event
WHERE execution_id = :exec_id
  AND node_name IN ('producer', 'fetch_via_flight_secure', 'done')
GROUP BY node_name, event_type
ORDER BY node_name, event_type;

-- Expected: each step has the standard
--   command.issued, command.claimed, command.started,
--   call.done, command.completed
-- (+ optional step.enter/exit) line set.
