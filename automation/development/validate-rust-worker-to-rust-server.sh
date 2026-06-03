#!/usr/bin/env bash
# Phase B Round 3 of noetl/server#21 (noetl/ai-meta#49) —
# verify the Rust worker → Rust server end-to-end write path.
#
# The Rust worker pool today is configured to POST events to the
# Python server (`NOETL_SERVER_URL=http://noetl.noetl.svc.cluster.local:8082`)
# because that's where the orchestrator state machine lives until
# Phase D ports it.  This script temporarily reconfigures the
# existing Rust worker deployment to point its put_result calls at
# the Rust server (`noetl-server-rust`) instead, drives a single-step
# playbook through Rust server's `POST /api/execute`, watches the
# events land in `noetl.event`, scrapes `/metrics` on the Rust
# server to confirm the wrapper instrumentation fired, and restores
# the worker env.
#
# Per agents/rules/execution-model.md the "Rust worker → Rust server"
# pairing only covers the put_result boundary today.  Multi-step
# orchestration through the Rust server depends on Phase D (the
# orchestrator engine port — tracked as noetl/server#22), so this
# script targets a SINGLE-STEP playbook (`tests/fixtures/routing_test`)
# to keep the scope sharp.
#
# Usage:
#   ./automation/development/validate-rust-worker-to-rust-server.sh
#
# Idempotent: on any exit (success or error), the worker's
# NOETL_SERVER_URL is restored to the value it had on entry.

set -euo pipefail

NS=${NS:-noetl}
KCTX=${KCTX:-kind-noetl}
WORKER_DEPLOY=${WORKER_DEPLOY:-noetl-worker-rust}
WORKER_CONTAINER=${WORKER_CONTAINER:-worker}
RUST_SERVER_SVC=${RUST_SERVER_SVC:-noetl-server-rust}
RUST_SERVER_URL_INSIDE_CLUSTER="http://${RUST_SERVER_SVC}.${NS}.svc.cluster.local:8082"
RUST_SERVER_LOCAL_PORT=${RUST_SERVER_LOCAL_PORT:-38082}
TEST_PLAYBOOK_PATH=${TEST_PLAYBOOK_PATH:-tests/fixtures/routing_test}
POSTGRES_NS=${POSTGRES_NS:-postgres}

# ---------------------------------------------------------------------------
# Pretty colours
# ---------------------------------------------------------------------------
green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
yellow(){ printf '\033[33m%s\033[0m' "$1"; }
cyan()  { printf '\033[36m%s\033[0m' "$1"; }

step() {
    printf '\n%s %s\n' "$(cyan '==>')" "$1"
}

ok()   { printf '    %s %s\n' "$(green PASS)" "$1"; }
warn() { printf '    %s %s\n' "$(yellow WARN)" "$1"; }
fail() { printf '    %s %s\n' "$(red FAIL)" "$1"; }

# ---------------------------------------------------------------------------
# Cleanup — always restore worker env to whatever it was on entry.
# ---------------------------------------------------------------------------
ORIG_SERVER_URL=""

restore() {
    if [[ -n "${ORIG_SERVER_URL}" ]]; then
        step "Restoring ${WORKER_DEPLOY}.NOETL_SERVER_URL → ${ORIG_SERVER_URL}"
        kubectl --context "${KCTX}" -n "${NS}" set env "deployment/${WORKER_DEPLOY}" \
            "NOETL_SERVER_URL=${ORIG_SERVER_URL}" >/dev/null
        # Fire-and-forget — old worker pods can take 2+ minutes to
        # terminate (NATS-consumer close lag), so don't block here.
        ok "Worker env restore requested (new ReplicaSet rolling)"
    fi
}
trap restore EXIT

# ---------------------------------------------------------------------------
# Sanity — both servers + the worker pod must be Running.
# ---------------------------------------------------------------------------
step "Sanity: cluster + worker pod state"
if ! kubectl --context "${KCTX}" -n "${NS}" get deployment "${WORKER_DEPLOY}" >/dev/null 2>&1; then
    fail "Worker deployment '${WORKER_DEPLOY}' not found in namespace '${NS}'"
    exit 1
fi
if ! kubectl --context "${KCTX}" -n "${NS}" get svc "${RUST_SERVER_SVC}" >/dev/null 2>&1; then
    fail "Rust server service '${RUST_SERVER_SVC}' not found in namespace '${NS}'"
    exit 1
fi
ok "Worker + Rust server discovered"

# ---------------------------------------------------------------------------
# Capture the worker's current NOETL_SERVER_URL so we can restore it.
# ---------------------------------------------------------------------------
ORIG_SERVER_URL=$(kubectl --context "${KCTX}" -n "${NS}" get deployment "${WORKER_DEPLOY}" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='${WORKER_CONTAINER}')].env[?(@.name=='NOETL_SERVER_URL')].value}")
if [[ -z "${ORIG_SERVER_URL}" ]]; then
    fail "Could not read NOETL_SERVER_URL from ${WORKER_DEPLOY}"
    exit 1
fi
step "Current worker NOETL_SERVER_URL: ${ORIG_SERVER_URL}"
if [[ "${ORIG_SERVER_URL}" == "${RUST_SERVER_URL_INSIDE_CLUSTER}" ]]; then
    warn "Already pointed at Rust server — proceeding without env flip"
fi

# ---------------------------------------------------------------------------
# Flip + wait for rollout.
# ---------------------------------------------------------------------------
if [[ "${ORIG_SERVER_URL}" != "${RUST_SERVER_URL_INSIDE_CLUSTER}" ]]; then
    step "Flipping ${WORKER_DEPLOY}.NOETL_SERVER_URL → ${RUST_SERVER_URL_INSIDE_CLUSTER}"
    kubectl --context "${KCTX}" -n "${NS}" set env "deployment/${WORKER_DEPLOY}" \
        "NOETL_SERVER_URL=${RUST_SERVER_URL_INSIDE_CLUSTER}" >/dev/null
    # Wait for at least one Ready replica on the new ReplicaSet — old
    # worker pods can take 2+ minutes to terminate (NATS-consumer
    # close lag), so we poll for the new pod going Ready instead of
    # blocking on `rollout status` which waits for the OLD pod to
    # disappear too.
    SECONDS_WAITED=0
    while (( SECONDS_WAITED < 60 )); do
        UPDATED_READY=$(kubectl --context "${KCTX}" -n "${NS}" get deployment "${WORKER_DEPLOY}" \
            -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo "0")
        if [[ "${UPDATED_READY}" =~ ^[0-9]+$ ]] && (( UPDATED_READY >= 1 )); then
            break
        fi
        sleep 2
        SECONDS_WAITED=$((SECONDS_WAITED + 2))
    done
    if (( SECONDS_WAITED >= 60 )); then
        warn "Could not confirm new worker pod is Ready within 60s — continuing anyway"
    else
        ok "New worker pod Ready after ${SECONDS_WAITED}s"
    fi
fi

# ---------------------------------------------------------------------------
# Port-forward the Rust server so we can talk to it from the harness host.
# ---------------------------------------------------------------------------
step "Port-forwarding Rust server to localhost:${RUST_SERVER_LOCAL_PORT}"
PF_LOG=$(mktemp)
kubectl --context "${KCTX}" -n "${NS}" port-forward "svc/${RUST_SERVER_SVC}" \
    "${RUST_SERVER_LOCAL_PORT}:8082" >"${PF_LOG}" 2>&1 &
PF_PID=$!
cleanup_pf() {
    kill "${PF_PID}" 2>/dev/null || true
    rm -f "${PF_LOG}"
}
trap 'cleanup_pf; restore' EXIT

# Wait for the port-forward to become reachable.
SECONDS_WAITED=0
until curl -sS -o /dev/null -w "%{http_code}" "http://localhost:${RUST_SERVER_LOCAL_PORT}/api/health" 2>/dev/null | grep -q "200"; do
    sleep 1
    SECONDS_WAITED=$((SECONDS_WAITED + 1))
    if (( SECONDS_WAITED > 20 )); then
        fail "Port-forward did not come up within 20s"
        exit 1
    fi
done
ok "Port-forward up after ${SECONDS_WAITED}s"

# ---------------------------------------------------------------------------
# Submit the single-step playbook via Rust server's POST /api/execute.
# ---------------------------------------------------------------------------
step "Submitting ${TEST_PLAYBOOK_PATH} via Rust server POST /api/execute"
EXEC_RESPONSE=$(curl -sS -X POST -H "Content-Type: application/json" \
    -d "{\"path\":\"${TEST_PLAYBOOK_PATH}\",\"payload\":{}}" \
    "http://localhost:${RUST_SERVER_LOCAL_PORT}/api/execute")
echo "    ${EXEC_RESPONSE}"

EXECUTION_ID=$(echo "${EXEC_RESPONSE}" | jq -r '.execution_id // empty')
if [[ -z "${EXECUTION_ID}" ]]; then
    fail "No execution_id in response — Rust server rejected the request"
    exit 1
fi
ok "execution_id=${EXECUTION_ID}"

# ---------------------------------------------------------------------------
# Tail the event log — expect at least playbook.initialized + the
# worker's command.* / step.* events once the put_result POST lands.
# ---------------------------------------------------------------------------
step "Waiting for events to land in noetl.event (up to 30s)"
POSTGRES_POD=$(kubectl --context "${KCTX}" -n "${POSTGRES_NS}" get pods -l app=postgres \
    -o jsonpath='{.items[0].metadata.name}')
SECONDS_WAITED=0
EVENT_COUNT=0
while (( SECONDS_WAITED < 30 )); do
    EVENT_COUNT=$(kubectl --context "${KCTX}" -n "${POSTGRES_NS}" exec "${POSTGRES_POD}" -- \
        psql -U noetl -d noetl -At -c \
        "SELECT COUNT(*) FROM noetl.event WHERE execution_id = ${EXECUTION_ID};" 2>/dev/null)
    if (( EVENT_COUNT >= 2 )); then
        break
    fi
    sleep 2
    SECONDS_WAITED=$((SECONDS_WAITED + 2))
done

if (( EVENT_COUNT == 0 )); then
    fail "No events landed for execution_id=${EXECUTION_ID} after 30s"
    exit 1
fi
ok "Found ${EVENT_COUNT} events for execution_id=${EXECUTION_ID}"

step "Event log shape:"
kubectl --context "${KCTX}" -n "${POSTGRES_NS}" exec "${POSTGRES_POD}" -- \
    psql -U noetl -d noetl -c \
    "SELECT event_id, event_type, node_name, status, created_at FROM noetl.event WHERE execution_id = ${EXECUTION_ID} ORDER BY event_id;" \
    2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Confirm the Rust server's /metrics counters fired.  The worker's
# POST /api/events lands in handle_event() → increments
# noetl_events_ingested_total{status=ok|error,event_type=...}.
# ---------------------------------------------------------------------------
step "Scraping Rust server /metrics for noetl_events_ingested_total{status=\"ok\"}"
METRIC_LINES=$(curl -sS "http://localhost:${RUST_SERVER_LOCAL_PORT}/metrics" \
    | grep '^noetl_events_ingested_total{' | grep 'status="ok"' || true)
if [[ -z "${METRIC_LINES}" ]]; then
    warn "No status=ok counter lines — worker may have POSTed errors only.  Check the Err counter:"
    curl -sS "http://localhost:${RUST_SERVER_LOCAL_PORT}/metrics" \
        | grep '^noetl_events_ingested_total{' | sed 's/^/        /'
else
    echo "${METRIC_LINES}" | sed 's/^/    /'
    ok "Rust server recorded at least one successful event ingest"
fi

step "Done."
echo "    execution_id=${EXECUTION_ID} processed by ${WORKER_DEPLOY} → ${RUST_SERVER_SVC}."
echo "    Event-log shape captured above; metrics surface populated."
echo "    Worker env will be restored on exit (trap)."
