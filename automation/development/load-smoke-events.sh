#!/usr/bin/env bash
# Phase B Round 4 of noetl/server#21 (noetl/ai-meta#49) —
# load smoke against the Rust server's POST /api/events.
#
# Drives N concurrent requests through ApacheBench (the only
# load tool widely available out of the box on macOS) with a
# synthetic but schema-valid event payload, scrapes /metrics
# before + after, computes the rate and p99 from the
# noetl_event_ingest_duration_seconds histogram.
#
# Acceptance per noetl/server#21:
#   ~1k events/s sustained for 60s, p99 < 20ms on local kind
#
# Usage:
#   ./automation/development/load-smoke-events.sh
#   TOTAL=60000 CONCURRENCY=50 ./automation/development/load-smoke-events.sh
#
# The harness uses an existing `step.enter` event_type (which is
# in `skip_engine_events` on the server, so the handler does a
# pure DB write — perfect for benchmarking the write boundary
# itself without orchestrator overhead).

set -euo pipefail

NS=${NS:-noetl}
KCTX=${KCTX:-kind-noetl}
RUST_SERVER_SVC=${RUST_SERVER_SVC:-noetl-server-rust}
RUST_SERVER_LOCAL_PORT=${RUST_SERVER_LOCAL_PORT:-38082}
TOTAL=${TOTAL:-60000}
CONCURRENCY=${CONCURRENCY:-50}
TEST_PLAYBOOK_PATH=${TEST_PLAYBOOK_PATH:-tests/fixtures/routing_test}

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
yellow(){ printf '\033[33m%s\033[0m' "$1"; }
cyan()  { printf '\033[36m%s\033[0m' "$1"; }

step() { printf '\n%s %s\n' "$(cyan '==>')" "$1"; }
ok()   { printf '    %s %s\n' "$(green PASS)" "$1"; }
warn() { printf '    %s %s\n' "$(yellow WARN)" "$1"; }
fail() { printf '    %s %s\n' "$(red FAIL)" "$1"; }

# ---------------------------------------------------------------------------
# Sanity
# ---------------------------------------------------------------------------
if ! command -v ab >/dev/null 2>&1; then
    fail "Apache Bench (ab) not found — install via 'brew install httpd'"
    exit 1
fi
if ! kubectl --context "${KCTX}" -n "${NS}" get svc "${RUST_SERVER_SVC}" >/dev/null 2>&1; then
    fail "Rust server service '${RUST_SERVER_SVC}' not found in ${NS}"
    exit 1
fi
ok "Tools + cluster discovered"

# ---------------------------------------------------------------------------
# Port-forward
# ---------------------------------------------------------------------------
step "Port-forwarding Rust server to localhost:${RUST_SERVER_LOCAL_PORT}"
PF_LOG=$(mktemp)
kubectl --context "${KCTX}" -n "${NS}" port-forward "svc/${RUST_SERVER_SVC}" \
    "${RUST_SERVER_LOCAL_PORT}:8082" >"${PF_LOG}" 2>&1 &
PF_PID=$!
cleanup() {
    kill "${PF_PID}" 2>/dev/null || true
    rm -f "${PF_LOG}" /tmp/load-smoke-payload.json /tmp/load-smoke-metrics-{before,after}.txt /tmp/load-smoke-ab.out 2>/dev/null || true
}
trap cleanup EXIT
SECONDS_WAITED=0
until curl -sS -o /dev/null -w "%{http_code}" "http://localhost:${RUST_SERVER_LOCAL_PORT}/api/health" 2>/dev/null | grep -q "200"; do
    sleep 1
    SECONDS_WAITED=$((SECONDS_WAITED + 1))
    if (( SECONDS_WAITED > 20 )); then
        fail "Port-forward did not come up within 20s"
        exit 1
    fi
done
ok "Port-forward up"

# ---------------------------------------------------------------------------
# Generate a real execution_id via /api/execute so the synthetic
# events have a parent that satisfies the get_catalog_id lookup.
# ---------------------------------------------------------------------------
step "Allocating execution_id via /api/execute on ${TEST_PLAYBOOK_PATH}"
EXEC_RESPONSE=$(curl -sS -X POST -H "Content-Type: application/json" \
    -d "{\"path\":\"${TEST_PLAYBOOK_PATH}\",\"payload\":{}}" \
    "http://localhost:${RUST_SERVER_LOCAL_PORT}/api/execute")
EXECUTION_ID=$(echo "${EXEC_RESPONSE}" | jq -r '.execution_id // empty')
if [[ -z "${EXECUTION_ID}" ]]; then
    fail "No execution_id in response: ${EXEC_RESPONSE}"
    exit 1
fi
ok "execution_id=${EXECUTION_ID}"

# ---------------------------------------------------------------------------
# Build the synthetic payload.
#
# `step.enter` is in `skip_engine_events` on the server, so the
# handler does a pure DB write — ideal for benchmarking the
# write boundary without orchestrator overhead.  Payload is
# minimal but result-shape-compliant (the chk_event_result_shape
# constraint requires `result` to be an object with `status` +
# only allowed keys).
# ---------------------------------------------------------------------------
cat >/tmp/load-smoke-payload.json <<EOF
{
  "execution_id": "${EXECUTION_ID}",
  "step": "load_smoke",
  "event_type": "step.enter",
  "result_kind": "data",
  "payload": {"status": "OK"},
  "actionable": false,
  "informative": true
}
EOF

# ---------------------------------------------------------------------------
# Snapshot /metrics before
# ---------------------------------------------------------------------------
step "Snapshotting /metrics BEFORE the run"
curl -sS "http://localhost:${RUST_SERVER_LOCAL_PORT}/metrics" >/tmp/load-smoke-metrics-before.txt
# `|| true` tolerates the fresh-pod case where the counter
# hasn't been lazy-initialised yet (no metric lines yet → grep
# returns 1 → pipefail aborts the script under set -e).
BEFORE_COUNT=$( (grep '^noetl_events_ingested_total' /tmp/load-smoke-metrics-before.txt || true) | awk -F'} ' '{s+=$2} END {print (s+0)}')
ok "events_ingested_total (sum across labels): ${BEFORE_COUNT}"

# ---------------------------------------------------------------------------
# Run Apache Bench
# ---------------------------------------------------------------------------
step "Running ab -n ${TOTAL} -c ${CONCURRENCY} (${TEST_PLAYBOOK_PATH} execution_id=${EXECUTION_ID})"
START_TS=$(perl -e 'print time')
ab -n "${TOTAL}" -c "${CONCURRENCY}" -k \
    -p /tmp/load-smoke-payload.json \
    -T 'application/json' \
    "http://localhost:${RUST_SERVER_LOCAL_PORT}/api/events" \
    >/tmp/load-smoke-ab.out 2>&1
END_TS=$(perl -e 'print time')
WALL_SECONDS=$((END_TS - START_TS))
ok "ab finished in ${WALL_SECONDS}s"

echo
echo "    --- ab summary ---"
grep -E "Requests per second|Time per request|Complete requests|Failed requests|Time taken|Non-2xx" /tmp/load-smoke-ab.out | sed 's/^/    /'

echo
echo "    --- ab percentiles (ms) ---"
grep -E "^\s+(50%|66%|75%|80%|90%|95%|98%|99%|100%)" /tmp/load-smoke-ab.out | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Snapshot /metrics after + compute deltas
# ---------------------------------------------------------------------------
step "Snapshotting /metrics AFTER the run"
curl -sS "http://localhost:${RUST_SERVER_LOCAL_PORT}/metrics" >/tmp/load-smoke-metrics-after.txt

AFTER_COUNT=$( (grep '^noetl_events_ingested_total' /tmp/load-smoke-metrics-after.txt || true) | awk -F'} ' '{s+=$2} END {print (s+0)}')
DELTA=$((AFTER_COUNT - BEFORE_COUNT))
ok "events_ingested_total delta: ${DELTA} (${BEFORE_COUNT} → ${AFTER_COUNT})"

OK_AFTER=$( (grep '^noetl_events_ingested_total{event_type="step.enter",status="ok"}' /tmp/load-smoke-metrics-after.txt || true) | awk -F'} ' '{print $2+0; exit}')
OK_BEFORE=$( (grep '^noetl_events_ingested_total{event_type="step.enter",status="ok"}' /tmp/load-smoke-metrics-before.txt || true) | awk -F'} ' '{print $2+0; exit}')
ERR_AFTER=$( (grep '^noetl_events_ingested_total{event_type="step.enter",status="error"}' /tmp/load-smoke-metrics-after.txt || true) | awk -F'} ' '{print $2+0; exit}')
ERR_BEFORE=$( (grep '^noetl_events_ingested_total{event_type="step.enter",status="error"}' /tmp/load-smoke-metrics-before.txt || true) | awk -F'} ' '{print $2+0; exit}')
OK_AFTER=${OK_AFTER:-0}; OK_BEFORE=${OK_BEFORE:-0}; ERR_AFTER=${ERR_AFTER:-0}; ERR_BEFORE=${ERR_BEFORE:-0}
OK_SMOKE=$((OK_AFTER - OK_BEFORE))
ERR_SMOKE=$((ERR_AFTER - ERR_BEFORE))
echo "    status=ok increments:    ${OK_SMOKE}"
echo "    status=error increments: ${ERR_SMOKE}"

# ---------------------------------------------------------------------------
# Extract p99 from the duration histogram
# ---------------------------------------------------------------------------
step "Histogram bucket counts (cumulative, step.enter):"
grep '^noetl_event_ingest_duration_seconds_bucket{event_type="step.enter",le="' /tmp/load-smoke-metrics-after.txt 2>/dev/null | sed 's/^/    /' || warn "no histogram lines yet"

step "Done."
echo "    Phase B Round 4 baseline captured."
echo "    Tail: target ~1k events/s sustained, p99 < 20ms."
echo "    Actual: ${OK_SMOKE} ok + ${ERR_SMOKE} err over ${WALL_SECONDS}s."
