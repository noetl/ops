-- Post-run validation queries for the Rust worker R-2.x kind
-- validation rig.  Verifies the over-budget call.done payload
-- shape + the producer-side credential scrub.  Run after invoking
-- `rust-worker-r2-validation.yaml`.
--
-- Usage (invoked by the runner; not typically run by hand):
--   kubectl --context kind-noetl -n postgres exec postgres-685d4bb64b-l76dn -- \
--     psql -U noetl -d noetl -v exec_id=<execution_id> \
--     -f /tmp/validate-rust-worker-r2.sql
--
-- For the actual data-fetch step (resolve the ResultRef back to its
-- bytes), see the matching curl recipe in the validate-rust-worker-r2.sh
-- script alongside this SQL.
--
-- NOTE on column naming: the post-EE-4 schema splits the old `payload`
-- jsonb into two columns — `context` (jsonb, the event's incoming
-- context) and `result` (jsonb, the call.done payload's `result`
-- object).  The probes below access the call.done result via the
-- `result` column at the row level, then drill into `result.context`
-- / `result.reference` jsonb sub-objects (NOT `payload.result.*`).
--
-- NOTE on event filtering: `worker_id` only lands on `command.claimed`
-- events in the current schema — `call.done` rows have `worker_id`
-- NULL.  Probes filter by `execution_id = :exec_id` instead; the .sh
-- runner already pins to the Rust worker via `PIN_RUST_WORKER=1`, so
-- the execution_id is sufficient on its own.

-- =============================================================
-- 1. Inline path (small_select)
--    Result fits under 100 KB → `result.context` is populated,
--    `result.reference` is absent, rows in
--    `result.context.data.rows[*]` have password / api_key
--    redacted.
-- =============================================================

\echo '== Inline path: small_select event =='
SELECT
    event_id,
    execution_id,
    event_type,
    node_name,
    result ? 'context' AS has_context,
    result ? 'reference' AS has_reference,
    result#>'{context,data,rows,0,password}' AS first_row_password,
    result#>'{context,data,rows,0,api_key}' AS first_row_api_key,
    result#>'{context,data,rows,0,username}' AS first_row_username
FROM noetl.event
WHERE execution_id = :exec_id
  AND node_name = 'small_select'
  AND event_type = 'call.done'
ORDER BY event_id DESC
LIMIT 1;

-- Expected: has_context=t, has_reference=f, first_row_password="[REDACTED]",
-- first_row_api_key="[REDACTED]", first_row_username (unredacted).

-- =============================================================
-- 2. Over-budget tabular path (big_select)
--    Result > 100 KB → `result.reference` carries a `result_ref`-
--    shaped dict with a nested `ipc.media_type = "application/
--    vnd.apache.arrow.stream"`.  `result.context` ALSO populated
--    by the broker (which preserves the worker's emitted ToolResult
--    JSON under that key); both can coexist.
-- =============================================================

\echo '== Over-budget tabular path: big_select event =='
SELECT
    event_id,
    execution_id,
    event_type,
    node_name,
    result ? 'context' AS has_context,
    result ? 'reference' AS has_reference,
    result#>>'{reference,kind}' AS reference_kind,
    result#>>'{reference,ref}' AS reference_ref,
    result#>>'{reference,store}' AS reference_store,
    result#>>'{reference,meta,bytes}' AS durable_bytes,
    result#>>'{reference,ipc,media_type}' AS ipc_media_type,
    result#>>'{reference,ipc,row_count}' AS ipc_row_count,
    result#>>'{reference,ipc,schema_digest}' AS ipc_schema_digest,
    result#>>'{reference,ipc,shm_name}' AS ipc_shm_name
FROM noetl.event
WHERE execution_id = :exec_id
  AND node_name = 'big_select'
  AND event_type = 'call.done'
ORDER BY event_id DESC
LIMIT 1;

-- Expected:
--   has_reference      = t
--   reference_kind     = 'result_ref'
--   reference_ref      LIKE 'noetl://execution/%/result/big_select/%'
--   reference_store    IN ('memory', 'kv', 'disk', 's3', 'gcs')
--   ipc_media_type     = 'application/vnd.apache.arrow.stream'
--   ipc_row_count      = '6000'
--   ipc_schema_digest  = 'arrow'
--   ipc_shm_name       (non-null string)

-- =============================================================
-- 3. Durable result-store row (noetl.result_ref)
--    The PUT /api/result/{execution_id} call lands a row here for
--    disk-tier results.  For `store_tier = kv` the data lives in
--    NATS KV instead + this query returns no rows — fetch the
--    payload via `GET /api/result/resolve?ref=...` in the .sh
--    runner.
-- =============================================================

\echo '== Durable result-store row for big_select (disk-tier only) =='
SELECT
    ref_id,
    ref,
    execution_id,
    name,
    scope,
    store_tier,
    physical_uri,
    bytes_size,
    content_type,
    preview->'rows'->0->>'password' AS preview_first_password,
    preview->'rows'->0->>'api_key'  AS preview_first_api_key,
    preview->'rows'->0->>'username' AS preview_first_username
FROM noetl.result_ref
WHERE execution_id = :exec_id
  AND name = 'big_select'
ORDER BY created_at DESC
LIMIT 1;

-- For disk-tier results (large payloads or when configured):
--   store_tier             = 'disk'
--   bytes_size             > 100000
--   preview_first_password = '[REDACTED]'
--   preview_first_api_key  = '[REDACTED]'
--   preview_first_username (unredacted)
-- For kv-tier results: (0 rows) — fetch via /api/result/resolve.

-- =============================================================
-- 4. Sanity counter — how many events did each path emit?
-- =============================================================

\echo '== Event distribution per node_name =='
SELECT
    node_name,
    event_type,
    COUNT(*) AS n,
    COUNT(*) FILTER (WHERE result ? 'context')   AS with_inline_context,
    COUNT(*) FILTER (WHERE result ? 'reference') AS with_reference
FROM noetl.event
WHERE execution_id = :exec_id
  AND node_name IN ('small_select', 'big_select', 'done')
GROUP BY node_name, event_type
ORDER BY node_name, event_type;
