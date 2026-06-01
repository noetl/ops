-- Post-run validation queries for the Rust worker R-2.x kind
-- validation (5.6.0).  Verifies the over-budget call.done payload
-- shape + the producer-side credential scrub.  Run after invoking
-- `rust-worker-r2-validation.yaml`.
--
-- Usage:
--   kubectl --context kind-noetl -n postgres exec postgres-685d4bb64b-l76dn -- \
--     psql -U noetl -d noetl -f /tmp/validate-rust-worker-r2.sql
--
-- For the actual data-fetch step (resolve the ResultRef back to its
-- bytes), see the matching curl recipe in the validate-rust-worker-r2.sh
-- script alongside this SQL.

-- =============================================================
-- 1. Inline path (small_select)
--    Result fits under 100 KB → `payload.result.context` is
--    populated; `payload.result.reference` is absent; rows in
--    `payload.result.context.data.rows[*]` have password / api_key
--    redacted.
-- =============================================================

\echo '== Inline path: small_select event =='
SELECT
    event_id,
    execution_id,
    event_type,
    node_name,
    payload->'result' ? 'context' AS has_context,
    payload->'result' ? 'reference' AS has_reference,
    payload#>'{result,context,data,rows,0,password}' AS first_row_password,
    payload#>'{result,context,data,rows,0,api_key}' AS first_row_api_key,
    payload#>'{result,context,data,rows,0,username}' AS first_row_username
FROM noetl.event
WHERE worker_id LIKE 'noetl-worker-rust-%'
  AND node_name = 'small_select'
  AND event_type = 'call.done'
ORDER BY event_id DESC
LIMIT 1;

-- Expected: has_context=t, has_reference=f, first_row_password="[REDACTED]",
-- first_row_api_key="[REDACTED]", first_row_username (unredacted).

-- =============================================================
-- 2. Over-budget tabular path (big_select)
--    Result > 100 KB → `payload.result.context` is ABSENT;
--    `payload.result.reference` is a `result_ref`-shaped dict
--    with a nested `ipc.media_type = "application/vnd.apache.arrow.stream"`.
-- =============================================================

\echo '== Over-budget tabular path: big_select event =='
SELECT
    event_id,
    execution_id,
    event_type,
    node_name,
    payload->'result' ? 'context' AS has_context,
    payload->'result' ? 'reference' AS has_reference,
    payload#>>'{result,reference,kind}' AS reference_kind,
    payload#>>'{result,reference,ref}' AS reference_ref,
    payload#>>'{result,reference,store}' AS reference_store,
    payload#>>'{result,reference,meta,bytes}' AS durable_bytes,
    payload#>>'{result,reference,ipc,media_type}' AS ipc_media_type,
    payload#>>'{result,reference,ipc,row_count}' AS ipc_row_count,
    payload#>>'{result,reference,ipc,schema_digest}' AS ipc_schema_digest,
    payload#>>'{result,reference,ipc,shm_name}' AS ipc_shm_name
FROM noetl.event
WHERE worker_id LIKE 'noetl-worker-rust-%'
  AND node_name = 'big_select'
  AND event_type = 'call.done'
ORDER BY event_id DESC
LIMIT 1;

-- Expected:
--   has_context        = f
--   has_reference      = t
--   reference_kind     = 'result_ref'
--   reference_ref      LIKE 'noetl://execution/%/result/big_select/%'
--   reference_store    IN ('memory', 'kv', 'disk', 's3', 'gcs')
--   durable_bytes      > 100000
--   ipc_media_type     = 'application/vnd.apache.arrow.stream'
--   ipc_row_count      = '6000'
--   ipc_schema_digest  = 'arrow'
--   ipc_shm_name       (non-null string)

-- =============================================================
-- 3. Durable result-store row (noetl.result_ref)
--    The PUT /api/result/{execution_id} call landed a row here.
--    Confirms the cross-node consumer path has something to fetch.
--    The actual bytes live in the storage tier (NATS KV / disk /
--    object store) — we cross-check the metadata only.
-- =============================================================

\echo '== Durable result-store row for big_select =='
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
WHERE execution_id IN (
    SELECT execution_id
    FROM noetl.event
    WHERE worker_id LIKE 'noetl-worker-rust-%'
      AND node_name = 'big_select'
      AND event_type = 'call.done'
    ORDER BY event_id DESC LIMIT 1
)
  AND name = 'big_select'
ORDER BY created_at DESC
LIMIT 1;

-- Expected:
--   store_tier             IN ('kv', 'disk', 'memory', 's3', 'gcs')
--   bytes_size             > 100000
--   preview_first_password = '[REDACTED]' (the server's preview is
--                            stripped from the SAME scrubbed body the
--                            worker sent, so the credential is
--                            redacted on the durable side too)
--   preview_first_api_key  = '[REDACTED]'
--   preview_first_username (unredacted)

-- =============================================================
-- 4. Sanity counter — how many events did each path emit?
-- =============================================================

\echo '== Event distribution per node_name =='
SELECT
    node_name,
    event_type,
    COUNT(*) AS n,
    COUNT(*) FILTER (WHERE payload->'result' ? 'context')   AS with_inline_context,
    COUNT(*) FILTER (WHERE payload->'result' ? 'reference') AS with_reference
FROM noetl.event
WHERE worker_id LIKE 'noetl-worker-rust-%'
  AND node_name IN ('small_select', 'big_select', 'done')
GROUP BY node_name, event_type
ORDER BY node_name, event_type;
