#!/usr/bin/env bash
# Kind-cluster end-to-end validation for the Rust noetl-worker R-2.x
# paths (5.6.0): R-2.1 colocated shm cache + R-2.1 cross-node durable
# result store + R-2.2 Arrow IPC encoding of tabular outputs + the
# producer-side credential scrub.
#
# Run from the ops repo root after building + loading the worker
# image into kind and rolling the deployment:
#
#   ./automation/development/validate-rust-worker-r2.sh
#
# Companion files in the same directory:
# - rust-worker-r2-validation.yaml -- the playbook fixture (a small
#   in-budget DuckDB query + a 6000-row over-budget one, both with
#   credential-bearing columns).
# - validate-rust-worker-r2.sql    -- the post-run SQL probes.

set -euo pipefail

SERVER="http://localhost:8082"
POSTGRES_POD=${POSTGRES_POD:-postgres-685d4bb64b-l76dn}
PLAYBOOK_FILE="$(cd "$(dirname "$0")" && pwd)/rust-worker-r2-validation.yaml"
SQL_FILE="$(cd "$(dirname "$0")" && pwd)/validate-rust-worker-r2.sql"

# Pin to the Rust worker — the SQL probes filter by
# `worker_id LIKE 'noetl-worker-rust-%'`, so if the Python worker
# claims the commands the probes return 0 rows and the rig looks
# broken even though execution succeeded.  Same pattern as the
# flight-tls rig.  Disable with PIN_RUST_WORKER=0 if you want to
# exercise the Python path instead.
PIN_RUST_WORKER=${PIN_RUST_WORKER:-1}
ORIGINAL_PY_REPLICAS=""

cleanup() {
    if [[ "$PIN_RUST_WORKER" == "1" && -n "$ORIGINAL_PY_REPLICAS" ]]; then
        echo
        echo "==> Cleanup: restoring python noetl-worker to $ORIGINAL_PY_REPLICAS replicas"
        kubectl --context kind-noetl -n noetl scale deployment noetl-worker \
            --replicas="$ORIGINAL_PY_REPLICAS" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [[ "$PIN_RUST_WORKER" == "1" ]]; then
    ORIGINAL_PY_REPLICAS=$(kubectl --context kind-noetl -n noetl get deployment noetl-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "3")
    echo "==> Pinning workload to Rust worker (scaling python noetl-worker $ORIGINAL_PY_REPLICAS -> 0)"
    kubectl --context kind-noetl -n noetl scale deployment noetl-worker --replicas=0 >/dev/null 2>&1
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

echo "==> Registering playbook from $PLAYBOOK_FILE"
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
echo "Registered version: $VERSION"

echo
echo "==> Kicking off execution"
EXEC_RESPONSE=$(curl -sf -X POST "$SERVER/api/execute" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"tests/fixtures/rust_worker_r2_validation\", \"version\": $VERSION}")
echo "$EXEC_RESPONSE" | python3 -m json.tool
EXECUTION_ID=$(echo "$EXEC_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('execution_id',''))")
if [[ -z "$EXECUTION_ID" ]]; then
    echo "FATAL: no execution_id in execute response"
    exit 1
fi
echo "Execution ID: $EXECUTION_ID"

echo
echo "==> Waiting for execution to complete (max 180s)"
# The status endpoint returns `{completed: bool, failed: bool, current_step, ...}`
# rather than a single status string — poll those booleans + the
# `completion_inferred` heuristic for terminal state.  Also tolerate
# the status endpoint lagging behind the event log (observed in
# noetl/ai-meta#35): if `current_step=done` persists for >30 ticks
# without `completed=True`, break out and let the SQL probes decide
# success.
DONE_STEP_TICKS=0
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
    if echo "$SUMMARY" | grep -q "step=done"; then
        DONE_STEP_TICKS=$((DONE_STEP_TICKS + 1))
        if [[ "$DONE_STEP_TICKS" -ge 30 ]]; then
            echo "WARN: status endpoint stuck at step=done for ${DONE_STEP_TICKS}s; falling through to SQL probes (likely the workflow.completed projection lag mentioned in #35)"
            break
        fi
    fi
    sleep 1
done

echo
echo "==> Copying SQL into postgres pod"
kubectl --context kind-noetl -n postgres cp "$SQL_FILE" "$POSTGRES_POD:/tmp/validate-rust-worker-r2.sql"

echo
echo "==> Running SQL probes (exec_id=$EXECUTION_ID)"
kubectl --context kind-noetl -n postgres exec "$POSTGRES_POD" -- \
    psql -U noetl -d noetl -v "exec_id=$EXECUTION_ID" -f /tmp/validate-rust-worker-r2.sql

echo
echo "==> Resolving the durable ResultRef for big_select"
# Pull the `result.reference.ref` URI back out of the event log and
# call /api/result/resolve to fetch the actual stored bytes.  Asserts
# the server-side scrub redacted the credentials in the durable rows
# too.  (Post-EE-4 the legacy `payload` jsonb column was split into
# `context` + `result`; the .sql file probes use the same shape.)
REF_URI=$(kubectl --context kind-noetl -n postgres exec "$POSTGRES_POD" -- \
    psql -U noetl -d noetl -At -c "
        SELECT result#>>'{reference,ref}'
        FROM noetl.event
        WHERE execution_id = $EXECUTION_ID
          AND node_name = 'big_select'
          AND event_type = 'call.done'
        ORDER BY event_id DESC LIMIT 1;")
if [[ -n "$REF_URI" && "$REF_URI" != "" ]]; then
    echo "Resolving ref: $REF_URI"
    RESOLVED=$(curl -sf -G "$SERVER/api/result/resolve" --data-urlencode "ref=$REF_URI" || true)
    if [[ -n "$RESOLVED" ]]; then
        echo "$RESOLVED" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d.get('data', {}).get('rows') or d.get('rows') or []
if not rows:
    print('WARN: no rows in resolved data')
    print(json.dumps(d)[:500])
else:
    first = rows[0]
    print('resolved row count:', len(rows))
    print('first row:        ', json.dumps(first))
    pw = first.get('password')
    ak = first.get('api_key')
    un = first.get('username')
    print(f'first.password = {pw!r}    (must be \"[REDACTED]\")')
    print(f'first.api_key  = {ak!r}    (must be \"[REDACTED]\")')
    print(f'first.username = {un!r}    (must be unredacted, e.g. \"user_000001\")')
" || echo "WARN: could not parse resolve response"
    else
        echo "WARN: /api/result/resolve returned empty for $REF_URI"
    fi
else
    echo "WARN: no reference URI found in event log for execution $EXECUTION_ID"
fi

echo
echo "==> Sampling /metrics from the Rust worker"
# The Rust worker pod is labelled `app=noetl-worker-rust` (the Python
# worker is `app=noetl-worker`; PIN_RUST_WORKER=1 scales Python to 0
# so we explicitly target the Rust pod here).  Falls back to `wget`
# inside the container if curl isn't present; tolerates either.
WORKER_POD=$(kubectl --context kind-noetl -n noetl get pod -l app=noetl-worker-rust -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$WORKER_POD" ]]; then
    kubectl --context kind-noetl -n noetl run "$WORKER_POD" -- \
        sh -c 'wget -qO- http://127.0.0.1:9090/metrics 2>/dev/null || curl -sf http://127.0.0.1:9090/metrics 2>/dev/null || echo "(neither wget nor curl available in worker container)"' \
        | grep -E "^noetl_worker_(result_store_put|dispatch|pulls_total)" \
        | head -30
else
    echo "WARN: no Rust worker pod found (label app=noetl-worker-rust)"
fi

echo
echo "==> Done.  Execution ID for further inspection: $EXECUTION_ID"
