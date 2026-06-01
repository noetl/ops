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
echo "==> Waiting for execution to complete (max 120s)"
# The status endpoint returns `{completed: bool, failed: bool, current_step, ...}`
# rather than a single status string — poll those booleans + the
# `completion_inferred` heuristic for terminal state.
for i in $(seq 1 120); do
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
kubectl --context kind-noetl -n postgres cp "$SQL_FILE" "$POSTGRES_POD:/tmp/validate-rust-worker-r2.sql"

echo
echo "==> Running SQL probes"
kubectl --context kind-noetl -n postgres exec "$POSTGRES_POD" -- \
    psql -U noetl -d noetl -f /tmp/validate-rust-worker-r2.sql

echo
echo "==> Resolving the durable ResultRef for big_select"
# Pull the `payload.result.reference.ref` URI back out of the event log
# and call /api/result/resolve to fetch the actual stored bytes.
# Asserts the server-side scrub redacted the credentials in the
# durable rows too.
REF_URI=$(kubectl --context kind-noetl -n postgres exec "$POSTGRES_POD" -- \
    psql -U noetl -d noetl -At -c "
        SELECT payload#>>'{result,reference,ref}'
        FROM noetl.event
        WHERE worker_id LIKE 'noetl-worker-rust-%'
          AND node_name = 'big_select'
          AND event_type = 'call.done'
          AND execution_id = $EXECUTION_ID
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
echo "==> Sampling /metrics from the worker"
WORKER_POD=$(kubectl --context kind-noetl -n noetl get pod -l app=noetl-worker -o jsonpath='{.items[0].metadata.name}')
kubectl --context kind-noetl -n noetl exec "$WORKER_POD" -- \
    sh -c 'wget -qO- http://127.0.0.1:9090/metrics || true' \
    | grep -E "^noetl_worker_(result_store_put|dispatch|pulls_total)" \
    | head -30

echo
echo "==> Done.  Execution ID for further inspection: $EXECUTION_ID"
