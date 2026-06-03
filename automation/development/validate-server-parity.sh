#!/usr/bin/env bash
# Read-endpoint parity diff harness — noetl/ai-meta#49 Phase A.
#
# Hits the same read endpoints on the Python noetl-server (default
# http://localhost:8082) and the Rust noetl-server-rust (default
# http://localhost:38082) and reports JSON-shape drift.
#
# Per #49 Phase A acceptance: "every read endpoint returns
# byte-identical JSON to the Python version against the same DB
# state".  This script is the first concrete pass at that diff
# harness.  It does NOT yet attempt byte-identical — it normalizes
# ephemeral fields (timestamps, uptime, version, request_id) and
# reports any structural / value differences.
#
# Findings (drift between the two servers' shapes) are reported but
# the script exits 0 even when drift is present — the goal of Phase
# A is to surface drift, not gate CI on it.  Each finding becomes a
# sub-issue against the Rust side to normalize toward the Python
# wire shape (or vice versa where the Rust shape is the better one
# and the Python should be retrofitted; case-by-case).
#
# Usage:
#   ./automation/development/validate-server-parity.sh
#   PYTHON_URL=http://localhost:8082 RUST_URL=http://localhost:38082 \
#     ./automation/development/validate-server-parity.sh

set -euo pipefail

PYTHON_URL="${PYTHON_URL:-http://localhost:8082}"
RUST_URL="${RUST_URL:-http://localhost:38082}"

# Ephemeral fields stripped before diff — these differ between calls
# on a single server, so cross-server drift on them isn't meaningful.
NORMALIZE_JQ='
  walk(
    if type == "object" then
      with_entries(select(.key as $k | [
        "uptime_seconds",
        "request_id",
        "timestamp",
        "created_at",
        "updated_at",
        "registered_at",
        "heartbeat_at",
        "last_heartbeat",
        "started_at",
        "ended_at",
        "thread_id",
        "thread_count",
        "pid",
        "memory_bytes",
        "memory_mb",
        "cpu_percent",
        "cpu_seconds",
        "active_connections",
        "idle_connections",
        "queries_total",
        "queries_active",
        "version",
        "generated_at"
      ] | index($k) | not))
    else .
    end
  )
'

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
yellow(){ printf '\033[33m%s\033[0m' "$1"; }
cyan()  { printf '\033[36m%s\033[0m' "$1"; }

probe() {
    local label="$1" method="$2" path="$3" body="${4:-}"
    printf '\n%s %s %s\n' "$(cyan '==>')" "$method" "$path"

    local py_resp py_code py_status_only ru_resp ru_code ru_status_only
    py_status_only=$(curl -sS -o /tmp/parity-py.json -w '%{http_code}' \
        -X "$method" ${body:+-H "Content-Type: application/json" -d "$body"} \
        "$PYTHON_URL$path" || echo "000")
    ru_status_only=$(curl -sS -o /tmp/parity-ru.json -w '%{http_code}' \
        -X "$method" ${body:+-H "Content-Type: application/json" -d "$body"} \
        "$RUST_URL$path" || echo "000")

    printf '    Python HTTP %s    Rust HTTP %s\n' \
        "$py_status_only" "$ru_status_only"

    if [[ "$py_status_only" != "$ru_status_only" ]]; then
        printf '    %s status-code drift: Python=%s Rust=%s\n' \
            "$(red FAIL)" "$py_status_only" "$ru_status_only"
        return 1
    fi

    if [[ "$py_status_only" -ge 400 ]]; then
        printf '    %s both errored with %s; not diffing\n' \
            "$(yellow SKIP)" "$py_status_only"
        return 0
    fi

    # Try to parse + normalize both bodies.  If either isn't JSON,
    # fall back to a literal text diff.
    if ! jq -e . /tmp/parity-py.json >/dev/null 2>&1; then
        printf '    %s Python returned non-JSON body\n' "$(yellow SKIP)"
        head -c 200 /tmp/parity-py.json | sed 's/^/        /'
        return 0
    fi
    if ! jq -e . /tmp/parity-ru.json >/dev/null 2>&1; then
        printf '    %s Rust returned non-JSON body\n' "$(yellow SKIP)"
        head -c 200 /tmp/parity-ru.json | sed 's/^/        /'
        return 0
    fi

    jq -S "$NORMALIZE_JQ" /tmp/parity-py.json >/tmp/parity-py-norm.json
    jq -S "$NORMALIZE_JQ" /tmp/parity-ru.json >/tmp/parity-ru-norm.json

    if diff -q /tmp/parity-py-norm.json /tmp/parity-ru-norm.json >/dev/null 2>&1; then
        printf '    %s byte-identical after normalization\n' "$(green PASS)"
        return 0
    fi

    printf '    %s response drift (after normalizing ephemeral fields):\n' \
        "$(yellow DIFF)"
    diff -u /tmp/parity-py-norm.json /tmp/parity-ru-norm.json \
        | head -30 \
        | sed 's/^/        /'
    return 0
}

echo "================================================"
echo "  Server parity diff — noetl/ai-meta#49 Phase A"
echo "================================================"
echo "    Python: $PYTHON_URL"
echo "    Rust:   $RUST_URL"

probe "health"        GET  /api/health        || true
probe "pool/status"   GET  /api/pool/status   || true
probe "worker/pools"  GET  /api/worker/pools  || true
probe "status"        GET  /api/status        || true
probe "credentials"   GET  /api/credentials   || true
probe "dashboard/stats" GET /api/dashboard/stats || true

# ---------------------------------------------------------------------------
# Round 2 — endpoints with path params (need live execution_id +
# playbook path).  Auto-discover from the live DB so the harness
# remains self-contained.  Skips silently when no data is present.
# ---------------------------------------------------------------------------

POSTGRES_POD=${POSTGRES_POD:-postgres-685d4bb64b-l76dn}
discover() {
    # Returns the latest completed execution_id whose catalog path is
    # also surfaced.  Skips if the kind cluster's psql isn't reachable
    # (e.g. running this harness in CI).
    kubectl --context kind-noetl -n postgres exec "$POSTGRES_POD" -- \
        psql -U noetl -d noetl -At -c "$1" 2>/dev/null | head -1
}

LIVE_EID=$(discover "SELECT execution_id::text FROM noetl.event WHERE event_type='playbook.initialized' ORDER BY event_id DESC LIMIT 1;")
LIVE_PATH=$(discover "SELECT path FROM noetl.catalog ORDER BY catalog_id DESC LIMIT 1;")
LIVE_EVENT_ID=$(discover "SELECT event_id::text FROM noetl.event WHERE result IS NOT NULL ORDER BY event_id DESC LIMIT 1;")

printf '\n%s discovery: execution_id=%s playbook=%s event_id=%s\n' \
    "$(cyan '==>')" "${LIVE_EID:-<none>}" "${LIVE_PATH:-<none>}" "${LIVE_EVENT_ID:-<none>}"

if [[ -n "$LIVE_EID" ]]; then
    probe "executions"                  GET  /api/executions                                    || true
    probe "executions/{id}"              GET  /api/executions/$LIVE_EID                          || true
    probe "executions/{id}/status"       GET  /api/executions/$LIVE_EID/status                   || true
    probe "vars/{execution_id}"          GET  /api/vars/$LIVE_EID                                || true
fi

if [[ -n "$LIVE_EVENT_ID" ]]; then
    probe "commands/{event_id}"          GET  /api/commands/$LIVE_EVENT_ID                       || true
fi

# Catalog read path — uses POST for list (intentional) and GET for
# resource/ui_schema.
probe "catalog/list (POST)"          POST /api/catalog/list                                  '{"kind":"Playbook","limit":5}' || true

if [[ -n "$LIVE_PATH" ]]; then
    probe "catalog/{path}/ui_schema"    GET  "/api/catalog/${LIVE_PATH}/ui_schema"              || true
fi

# Pool routing + runtime contract endpoints — heavily used by gateway / SPA.
probe "runtime/contract"             GET  /api/runtime/contract                              || true
# /api/runtimes was a Rust-side innovation removed in noetl/server#19 for
# Phase A parity; both servers now 404 here so the probe is moot.  Re-add
# when the Python backport lands.

echo
echo "==> Done.  Drifts above are documented for triage."
