-- Log-analytics schema. Converged by automation/iap/kind/log_analytics.yaml (step
-- converge_schema) with `clickhouse-client --multiquery` as the localhost-only default
-- user. Every statement is idempotent (IF NOT EXISTS / MODIFY), so re-running apply
-- is a no-op once the schema exists. Spec: docs/specs/noetl-iac-log-analytics.md
--
-- One table for every source. `source` says where a row came from:
--   k8s      container logs from every pod on the kind node, shipped by Vector
--   qnetmon  the qnetmon edge daemon's event log and launchd stdout/stderr,
--            shipped by the edge playbook (qnetmon playbooks/housekeeping/logs.yaml)
--   noetl    anything a playbook inserts directly (the verify step writes here)

CREATE DATABASE IF NOT EXISTS logs;

CREATE TABLE IF NOT EXISTS logs.events
(
    ts          DateTime64(3, 'UTC') CODEC(Delta, ZSTD(3)),
    received_at DateTime64(3, 'UTC') DEFAULT now64(3) CODEC(Delta, ZSTD(3)),
    source      LowCardinality(String),
    host        LowCardinality(String),
    namespace   LowCardinality(String),
    pod         String,
    container   LowCardinality(String),
    stream      LowCardinality(String),
    level       LowCardinality(String),
    event_type  LowCardinality(String),
    execution_id String,
    message     String CODEC(ZSTD(3)),
    attrs       String CODEC(ZSTD(3)),
    INDEX idx_message message TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 4,
    INDEX idx_execution execution_id TYPE bloom_filter GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toDate(ts)
ORDER BY (source, namespace, container, ts)
TTL toDateTime(ts) + INTERVAL 7 DAY DELETE
SETTINGS
    -- Retried inserts that carry the same insert_deduplication_token are dropped,
    -- so the edge shipper can resend a chunk after a timeout without duplicating it.
    non_replicated_deduplication_window = 1000,
    ttl_only_drop_parts = 1;

-- Retention is part of the desired state: re-applying converges a changed TTL. Don't
-- rewrite existing parts on every apply; merges and ttl_only_drop_parts enforce it.
SET materialize_ttl_after_modify = 0;
ALTER TABLE logs.events MODIFY TTL toDateTime(ts) + INTERVAL 7 DAY DELETE;

-- Per-minute volume by source/namespace/level, for dashboards and cheap MCP questions
-- ("which namespace got noisy in the last hour?") without scanning messages.
CREATE TABLE IF NOT EXISTS logs.events_per_minute
(
    minute    DateTime('UTC'),
    source    LowCardinality(String),
    namespace LowCardinality(String),
    level     LowCardinality(String),
    rows      UInt64
)
ENGINE = SummingMergeTree
PARTITION BY toDate(minute)
ORDER BY (source, namespace, level, minute)
TTL minute + INTERVAL 30 DAY DELETE;

CREATE MATERIALIZED VIEW IF NOT EXISTS logs.events_per_minute_mv
TO logs.events_per_minute AS
SELECT
    toStartOfMinute(ts) AS minute,
    source,
    namespace,
    level,
    count() AS rows
FROM logs.events
GROUP BY minute, source, namespace, level;
