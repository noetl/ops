-- Post-run SQL probes for the `result_fetch` tool kind validation
-- (noetl-tools 2.11.0+ via noetl-worker 5.7.0+).  Pairs with
-- `result-fetch-validation.yaml` + the matching .sh runner.
--
-- Usage:
--   kubectl --context kind-noetl -n postgres exec deployment/postgres -- \
--     psql -U noetl -d noetl -v exec_id=<execution_id> \
--     -f /tmp/validate-result-fetch.sql
--
-- IMPORTANT: producer + fetch steps MUST land on the Rust worker
-- (`noetl-worker-rust`) for the over-budget path to trigger.  Scale
-- the Python `noetl-worker` deployment to 0 before invoking
-- `validate-result-fetch.sh` so command routing pins to the Rust
-- worker.

-- =============================================================
-- 1. producer step — confirm it emitted result.reference (the
--    > 100 KB tabular output triggered the over-budget path).
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
--   reference_kind  = 'result_ref' (Phase A durable path)
--   reference_ref   LIKE 'noetl://execution/.../result/producer/%'
--   ipc_media_type  = 'application/vnd.apache.arrow.stream'
--   ipc_row_count   = '6000'

-- =============================================================
-- 2. fetch_via_flight step — the tool ran via the Rust worker's
--    dispatcher AND materialised rows from the producer's ref via
--    the noetl-server's Arrow Flight do_get endpoint.
--
--    KNOWN ISSUE (noetl-tools 2.11.0): the Flight client raises
--    `Bad :scheme header` against the derived endpoint.  Tracked
--    separately; see the README + linked ai-task issue.
-- =============================================================

\echo '== fetch_via_flight call.done =='
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
  AND node_name = 'fetch_via_flight'
  AND event_type IN ('call.done', 'call.error')
ORDER BY event_id DESC
LIMIT 1;

-- Expected (when Flight works):
--   status      = 'COMPLETED'
--   fetch_status = 'success'
--   new_ref     LIKE 'noetl://execution/.../result/fetch_via_flight/%'
--
-- Current (Bad :scheme bug, tracked):
--   status      = 'FAILED'
--   error       LIKE '%Bad :scheme header%'

-- =============================================================
-- 3. fetch_via_http step — same data, HTTP fallback path.
--    The tool's response is a new reference pointing at the
--    fetched bytes (the producer's result, re-stored under the
--    fetch step's URI).  Resolve the URI for inspection;
--    redaction is verified producer-side.
-- =============================================================

\echo '== fetch_via_http call.done =='
SELECT
    event_id,
    node_name,
    status,
    result#>>'{context,status}' AS fetch_status,
    result#>>'{context,reference,ref}' AS new_ref,
    result#>>'{context,reference,meta,bytes}' AS bytes,
    result#>>'{context,reference,meta,sha256}' AS sha256
FROM noetl.event
WHERE execution_id = :exec_id
  AND node_name = 'fetch_via_http'
  AND event_type = 'call.done'
ORDER BY event_id DESC
LIMIT 1;

-- Expected:
--   status        = 'COMPLETED'
--   fetch_status  = 'success'
--   new_ref       LIKE 'noetl://execution/.../result/fetch_via_http/%'
--   bytes         > 0
--   sha256        non-null (content hash of the fetched payload)

-- =============================================================
-- 4. Event distribution — how many lifecycle events per step.
-- =============================================================

\echo '== Step lifecycle counts =='
SELECT
    node_name,
    event_type,
    COUNT(*) AS n
FROM noetl.event
WHERE execution_id = :exec_id
  AND node_name IN ('producer', 'fetch_via_flight', 'fetch_via_http', 'done')
GROUP BY node_name, event_type
ORDER BY node_name, event_type;

-- Expected: each step has command.issued, command.claimed,
-- command.started, call.done (or call.error for the Flight
-- known-failure), command.completed (+ optional step.enter/exit).
