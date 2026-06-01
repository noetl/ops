#!/usr/bin/env bash
# Kind-cluster end-to-end validation for the `result_fetch` tool kind
# (noetl-tools 2.11.0+ via noetl-worker 5.7.0+).
#
# Run from the ops repo root after building + loading the worker
# image into kind and rolling the deployment:
#
#   ./automation/development/validate-result-fetch.sh
#
# Companion files in the same directory:
# - result-fetch-validation.yaml -- playbook fixture exercising
#   producer + fetch_via_flight + fetch_via_http.
# - validate-result-fetch.sql    -- post-run SQL probes.

set -euo pipefail

SERVER="http://localhost:8082"
POSTGRES_POD=${POSTGRES_POD:-postgres-685d4bb64b-l76dn}
PLAYBOOK_FILE="$(cd "$(dirname "$0")" && pwd)/result-fetch-validation.yaml"
SQL_FILE="$(cd "$(dirname "$0")" && pwd)/validate-result-fetch.sql"

# The producer step's over-budget Arrow IPC path is implemented only
# in the Rust worker (build_call_done_result, R-2.2).  The Python
# noetl-worker uses a sample-format that never triggers the
# > 100 KB ref path, so the rig would silently mis-route.  Scale the
# Python pool to 0 for the duration of the validation + restore it
# afterwards.  Override with PIN_RUST_WORKER=0 to skip (assumes the
# Python pool is already 0).
PIN_RUST_WORKER=${PIN_RUST_WORKER:-1}
ORIGINAL_PY_REPLICAS=""
restore_python_workers() {
    if [[ "$PIN_RUST_WORKER" == "1" && -n "$ORIGINAL_PY_REPLICAS" ]]; then
        echo "==> Restoring python noetl-worker to $ORIGINAL_PY_REPLICAS replicas"
        kubectl --context kind-noetl -n noetl scale deployment noetl-worker --replicas="$ORIGINAL_PY_REPLICAS" >/dev/null 2>&1 || true
    fi
}
trap restore_python_workers EXIT

if [[ "$PIN_RUST_WORKER" == "1" ]]; then
    ORIGINAL_PY_REPLICAS=$(kubectl --context kind-noetl -n noetl get deployment noetl-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "3")
    echo "==> Pinning workload to Rust worker (scaling python noetl-worker $ORIGINAL_PY_REPLICAS -> 0)"
    kubectl --context kind-noetl -n noetl scale deployment noetl-worker --replicas=0 >/dev/null 2>&1
    # `rollout status` returns when replicas-spec is satisfied, but pods may
    # still be terminating + draining their NATS subscription.  A draining
    # Python pod will race the Rust worker for the producer command + the
    # over-budget Arrow IPC branch only fires inside the Rust worker, so
    # wait for the actual pod count to hit zero before registering.
    echo "    waiting for python noetl-worker pods to fully terminate..."
    for i in $(seq 1 60); do
        py_pods=$(kubectl --context kind-noetl -n noetl get pods -l app=noetl-worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$py_pods" == "0" ]]; then
            echo "    python noetl-worker pods drained after ${i}s"
            break
        fi
        sleep 1
    done
fi

echo "==> Registering playbook"
PLAYBOOK_CONTENT=$(python3 -c "import json,sys; print(json.dumps({'content': open(sys.argv[1]).read(), 'resource_type': 'Playbook'}))" "$PLAYBOOK_FILE")
REGISTER_RESPONSE=$(curl -sf -X POST "$SERVER/api/catalog/register" \
    -H "Content-Type: application/json" \
    --data-binary "$PLAYBOOK_CONTENT")
echo "$REGISTER_RESPONSE" | python3 -m json.tool
VERSION=$(echo "$REGISTER_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))")
if [[ -z "$VERSION" ]]; then
    echo "FATAL: no version in register response"
    exit 1
fi

echo
echo "==> Executing"
EXEC_RESPONSE=$(curl -sf -X POST "$SERVER/api/execute" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"tests/fixtures/result_fetch_validation\", \"version\": $VERSION}")
echo "$EXEC_RESPONSE" | python3 -m json.tool
EXECUTION_ID=$(echo "$EXEC_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('execution_id',''))")
if [[ -z "$EXECUTION_ID" ]]; then
    echo "FATAL: no execution_id in execute response"
    exit 1
fi
echo "Execution ID: $EXECUTION_ID"

echo
echo "==> Waiting for completion (max 180s)"
for i in $(seq 1 180); do
    RAW=$(curl -sf "$SERVER/api/executions/$EXECUTION_ID/status" 2>/dev/null || echo "{}")
    SUMMARY=$(echo "$RAW" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('completed=? failed=? step=?')
    sys.exit(0)
print(f\"completed={d.get('completed')} failed={d.get('failed')} step={d.get('current_step','?')}\")
" 2>/dev/null)
    echo "[$i] $SUMMARY"
    if echo "$SUMMARY" | grep -q "completed=True"; then
        break
    fi
    if echo "$SUMMARY" | grep -q "failed=True"; then
        echo "WARN: execution failed"
        break
    fi
    sleep 1
done

echo
echo "==> Copying SQL into postgres pod"
kubectl --context kind-noetl -n postgres cp "$SQL_FILE" "$POSTGRES_POD:/tmp/validate-result-fetch.sql"

echo
echo "==> Running SQL probes (exec_id=$EXECUTION_ID)"
kubectl --context kind-noetl -n postgres exec "$POSTGRES_POD" -- \
    psql -U noetl -d noetl -v "exec_id=$EXECUTION_ID" -f /tmp/validate-result-fetch.sql

echo
echo "==> Sampling /metrics from the Rust worker"
WORKER_POD=$(kubectl --context kind-noetl -n noetl get pod -l app=noetl-worker-rust -o jsonpath='{.items[0].metadata.name}')
kubectl --context kind-noetl -n noetl exec "$WORKER_POD" -- \
    python3 -c "
import urllib.request
text = urllib.request.urlopen('http://127.0.0.1:9090/metrics').read().decode()
for line in text.split('\n'):
    if any(k in line for k in ['noetl_worker_dispatch_duration_seconds_count{tool_kind=\"result_fetch\"',
                                'noetl_worker_dispatch_errors_total{tool_kind=\"result_fetch\"',
                                'noetl_worker_dispatch_duration_seconds_count{tool_kind=\"duckdb\"']):
        if not line.startswith('#'):
            print(line)
" || true

echo
echo "==> Done.  Execution ID for further inspection: $EXECUTION_ID"
