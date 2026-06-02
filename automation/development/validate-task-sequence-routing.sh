#!/usr/bin/env bash
# Kind-cluster validation for noetl/ai-meta#47 — route ``task_sequence``
# tool kind to the python pool segment.
#
# Validates:
#   1. A playbook with a ``task_sequence`` step (tool is a list of named
#      tasks) publishes its command to ``noetl.commands.python.<eid>``
#      when the routing flag is on (the Rust pool's consumer's filter
#      ``noetl.commands.shared.>`` no longer matches).
#   2. The Python pool's catch-all consumer (``noetl_worker_pool``,
#      filter=None) claims the command and the
#      ``TaskSequenceExecutor`` dispatches the inner pipeline.
#   3. The execution does NOT log
#      ``Tool not found: task_sequence`` on the Rust pool (the
#      regression #47 was filed for).
#
# Run from the ops repo root after building + loading the noetl-server
# image into kind and rolling the deployment.

set -euo pipefail

SERVER="${SERVER:-http://localhost:8082}"
POSTGRES_POD=${POSTGRES_POD:-postgres-685d4bb64b-l76dn}
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$THIS_DIR/validate-task-sequence-routing.yaml"

echo "==> Validating #47 task_sequence routing"
echo "    Server:       $SERVER"
echo "    Postgres pod: $POSTGRES_POD"
echo

register() {
    local file="$1" label="$2"
    local content
    content=$(python3 -c "import json,sys; print(json.dumps({'content': open(sys.argv[1]).read(), 'resource_type': 'Playbook'}))" "$file")
    local response version
    response=$(curl -sf -X POST "$SERVER/api/catalog/register" \
        -H "Content-Type: application/json" \
        --data-binary "$content")
    version=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))")
    if [[ -z "$version" ]]; then
        echo "FATAL: register failed for $label: $response" >&2
        exit 1
    fi
    echo "    $label: registered v$version" >&2
    echo "$version"
}

execute() {
    local path="$1" version="$2" label="$3"
    local response eid
    response=$(curl -sf -X POST "$SERVER/api/execute" \
        -H "Content-Type: application/json" \
        -d "{\"path\":\"$path\",\"version\":$version}")
    eid=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('execution_id',''))")
    if [[ -z "$eid" ]]; then
        echo "FATAL: execute failed for $label: $response" >&2
        exit 1
    fi
    echo "    $label: execution_id=$eid" >&2
    echo "$eid"
}

probe_consumer_deliveries() {
    local consumer="$1"
    curl -sf "http://localhost:${NATS_PF_PORT}/jsz?streams=true&consumers=true&account=NOETL" 2>&1 \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
for acc in d.get('account_details', []):
    if acc.get('name') != 'NOETL':
        continue
    for s in acc.get('stream_detail', []):
        if s['name'] != 'NOETL_COMMANDS':
            continue
        for c in s.get('consumer_detail', []):
            if c['name'] == '$consumer':
                print(c.get('delivered', {}).get('consumer_seq', 0))
                sys.exit(0)
print(0)
"
}

NATS_PF_PORT="${NATS_PF_PORT:-38222}"
echo "==> Starting NATS monitoring port-forward on ${NATS_PF_PORT}"
kubectl --context kind-noetl -n nats port-forward svc/nats \
    "${NATS_PF_PORT}:8222" >/tmp/nats-pf-ts.log 2>&1 &
NATS_PF_PID=$!
trap "kill ${NATS_PF_PID} 2>/dev/null || true" EXIT
sleep 2

echo "==> Sampling consumer baselines"
PYTHON_POOL_BEFORE=$(probe_consumer_deliveries "noetl_worker_pool")
RUST_POOL_BEFORE=$(probe_consumer_deliveries "noetl_worker_pool_shared")
echo "    Python pool (noetl_worker_pool) before:        $PYTHON_POOL_BEFORE"
echo "    Rust pool   (noetl_worker_pool_shared) before: $RUST_POOL_BEFORE"
echo

echo "==> Registering + executing task_sequence fixture"
VERSION=$(register "$FIXTURE" "task_sequence playbook")
EID=$(execute "tests/fixtures/task_sequence_routing" "$VERSION" "task_sequence")
echo

# Let NATS deliver + the Python worker pick up.  task_sequence
# executes a tiny two-task pipeline (~1s wall clock).
echo "==> Waiting up to 30s for execution to complete"
for i in $(seq 1 30); do
    STATUS=$(curl -sf "$SERVER/api/executions/$EID/status" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('current_step','?'),d.get('completed'),d.get('failed'))" 2>/dev/null \
        || echo "? ? ?")
    echo "[$i] $STATUS"
    if echo "$STATUS" | grep -q "True False"; then
        echo "    completed"
        break
    fi
    if echo "$STATUS" | grep -q "True$"; then
        echo "    FAILED"
        break
    fi
    sleep 1
done
echo

echo "==> Sampling consumer deltas"
PYTHON_POOL_AFTER=$(probe_consumer_deliveries "noetl_worker_pool")
RUST_POOL_AFTER=$(probe_consumer_deliveries "noetl_worker_pool_shared")
PYTHON_DELTA=$((PYTHON_POOL_AFTER - PYTHON_POOL_BEFORE))
RUST_DELTA=$((RUST_POOL_AFTER - RUST_POOL_BEFORE))
echo "    Python pool delta:  $PYTHON_DELTA"
echo "    Rust pool   delta:  $RUST_DELTA"
echo

failures=0

assert() {
    local cond="$1" label="$2"
    if [[ "$cond" == "true" ]]; then
        echo "    ✅ $label"
    else
        echo "    ❌ $label"
        failures=$((failures + 1))
    fi
}

[[ "$PYTHON_DELTA" -ge 1 ]] && assert true  "Python pool claimed the task_sequence command (delta=$PYTHON_DELTA ≥ 1)" \
                            || assert false "Python pool delta=$PYTHON_DELTA (expected ≥ 1)"

# The Rust pool's consumer filter is ``noetl.commands.shared.>`` so it
# MUST NOT pick up commands routed to ``noetl.commands.python.<eid>``.
# A non-zero delta here means routing failed and the regression #47
# is still live.
[[ "$RUST_DELTA" -eq 0 ]] && assert true  "Rust pool did NOT claim the task_sequence command (delta=$RUST_DELTA)" \
                          || assert false "Rust pool delta=$RUST_DELTA (expected 0 — routing leak)"

echo
echo "==> Probing noetl.event for command.issued events"
kubectl --context kind-noetl -n postgres exec "$POSTGRES_POD" -- \
    psql -U noetl -d noetl -At -c "
        SELECT event_type, node_name, node_type, status
        FROM noetl.event
        WHERE execution_id = $EID
          AND event_type IN ('command.issued', 'command.claimed', 'command.completed', 'command.failed', 'call.done')
        ORDER BY event_id;
    " | awk -F'|' '{printf "    %s %s tool=%s status=%s\n", $1, $2, $3, $4}'
echo

echo "==> Scanning Rust pool logs for 'Tool not found: task_sequence'"
RUST_POD=$(kubectl --context kind-noetl -n noetl get pod -l app=noetl-worker-rust \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$RUST_POD" ]]; then
    if kubectl --context kind-noetl -n noetl logs "$RUST_POD" --since=1m 2>/dev/null \
        | grep -q "Tool not found: task_sequence"; then
        assert false "Rust worker logged 'Tool not found: task_sequence' (regression still live)"
    else
        assert true "Rust worker did not log 'Tool not found: task_sequence'"
    fi
fi
echo

if [[ "$failures" -gt 0 ]]; then
    echo "==> FAIL: $failures assertion(s) failed"
    exit 1
fi
echo "==> All task_sequence routing assertions passed"
