-- Post-run validation queries for the Rust worker kind validation.
-- Run inside the kind Postgres pod:
--   kubectl --context kind-noetl -n postgres exec postgres-... -- \
--     psql -U noetl -d noetl -f /tmp/validate-event-shape.sql
--
-- The Rust worker is pinned to worker_id = noetl-worker-rust-* via
-- WORKER_ID = metadata.name on the Deployment.

\echo '== Most recent events from the Rust worker =='
SELECT
    event_id,
    execution_id,
    event_type,
    node_name,           -- must be NON-NULL (proves step → node_name alias worked)
    status,
    worker_id,           -- must contain 'noetl-worker-rust-*'
    meta,                -- must contain {"attempts": N}
    created_at
FROM noetl.event
WHERE worker_id LIKE 'noetl-worker-rust-%'
ORDER BY event_time DESC
LIMIT 20;

\echo
\echo '== event_id source check — should be application-stamped, not the gen_snowflake() default =='
-- The Rust worker generates ids with node_id derived from WORKER_ID hash.
-- Default DB-side gen_snowflake() uses a server-side node id (typically 0).
-- Different node-id bits in the ids prove the worker stamped them.
SELECT
    event_id,
    (event_id >> 12) & 1023 AS node_id_bits,
    worker_id
FROM noetl.event
WHERE worker_id LIKE 'noetl-worker-rust-%'
ORDER BY event_time DESC
LIMIT 10;

\echo
\echo '== meta.attempts populated =='
SELECT
    event_type,
    node_name,
    meta->>'attempts' AS attempts,
    COUNT(*) AS n
FROM noetl.event
WHERE worker_id LIKE 'noetl-worker-rust-%'
GROUP BY event_type, node_name, meta->>'attempts'
ORDER BY event_type, node_name;

\echo
\echo '== Validation summary =='
SELECT
    COUNT(*) FILTER (WHERE worker_id LIKE 'noetl-worker-rust-%') AS rust_events,
    COUNT(*) FILTER (WHERE worker_id LIKE 'noetl-worker-rust-%' AND node_name IS NOT NULL) AS with_node_name,
    COUNT(*) FILTER (WHERE worker_id LIKE 'noetl-worker-rust-%' AND meta ? 'attempts') AS with_meta_attempts,
    COUNT(*) FILTER (WHERE worker_id LIKE 'noetl-worker-rust-%' AND event_id > 0) AS with_event_id
FROM noetl.event;
