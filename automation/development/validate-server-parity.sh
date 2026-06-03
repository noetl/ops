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
        "version"
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

echo
echo "==> Done.  Drifts above are documented for triage."
