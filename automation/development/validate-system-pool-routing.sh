#!/usr/bin/env bash
# Kind-cluster validation for noetl/ai-meta#46 Phase 2.a.2 —
# path-based pool routing for `system/*` playbooks.
#
# Validates:
#   1. A playbook whose catalog path starts with `system/` has its
#      commands routed to the `system` pool segment (NATS subject
#      `noetl.commands.system.<eid>`).
#   2. A control playbook under any other path routes to `shared`
#      (NATS subject `noetl.commands.shared.<eid>`).
#   3. The system worker pool's NATS consumer
#      (`noetl_worker_pool_system`, filter `noetl.commands.system.>`)
#      observes the delivery of the system command (delivered + pending
#      counters in the consumer info).
#
# Trigger by registering two trivial single-step `tool: python`
# playbooks (one under `system/`, one under `tests/fixtures/`),
# executing both, then probing:
#   - `noetl.event` rows for the resulting `command.issued` events
#   - NATS stream subjects for the published subject
#   - Consumer info JSON for delivery counts
#
# Companion files:
#   - validate-system-pool-routing-system.yaml — system/ playbook fixture
#   - validate-system-pool-routing-user.yaml   — user playbook fixture
#
# Run from the ops repo root after building + loading the noetl-server
# image into kind and rolling the deployment.

set -euo pipefail

SERVER="${SERVER:-http://localhost:8082}"
POSTGRES_POD=${POSTGRES_POD:-postgres-685d4bb64b-l76dn}
NATS_POD=${NATS_POD:-}
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEM_FIXTURE="$THIS_DIR/validate-system-pool-routing-system.yaml"
USER_FIXTURE="$THIS_DIR/validate-system-pool-routing-user.yaml"

if [[ -z "$NATS_POD" ]]; then
    NATS_POD=$(kubectl --context kind-noetl -n nats get pods -l app=nats \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
if [[ -z "$NATS_POD" ]]; then
    echo "FATAL: no NATS pod found in namespace 'nats'"
    exit 1
fi

echo "==> Validating Phase 2.a.2 path-based routing"
echo "    Server:       $SERVER"
echo "    Postgres pod: $POSTGRES_POD"
echo "    NATS pod:     $NATS_POD"
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
    # Returns the cumulative ``delivered.consumer_seq`` for one of the
    # NOETL_COMMANDS consumers via the NATS HTTP monitoring endpoint.
    # We compare the value before + after the test publishes to assert
    # that the delta matches the expected per-pool counts.
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

# Start a port-forward to the NATS HTTP monitoring port (8222) so we
# can read consumer delivery counts.  Tear it down on exit.
NATS_PF_PORT="${NATS_PF_PORT:-38222}"
echo "==> Starting NATS monitoring port-forward on ${NATS_PF_PORT}"
kubectl --context kind-noetl -n nats port-forward svc/nats \
    "${NATS_PF_PORT}:8222" >/tmp/nats-pf-routing.log 2>&1 &
NATS_PF_PID=$!
trap "kill ${NATS_PF_PID} 2>/dev/null || true" EXIT
sleep 2

echo "==> Sampling consumer baselines"
SYSTEM_BEFORE=$(probe_consumer_deliveries "noetl_worker_pool_system")
SHARED_BEFORE=$(probe_consumer_deliveries "noetl_worker_pool_shared")
echo "    system pool delivered (before): $SYSTEM_BEFORE"
echo "    shared pool delivered (before): $SHARED_BEFORE"
echo

echo "==> Registering fixture playbooks"
SYSTEM_VERSION=$(register "$SYSTEM_FIXTURE" "system playbook")
USER_VERSION=$(register "$USER_FIXTURE" "user playbook")
echo

echo "==> Executing both playbooks"
SYSTEM_EID=$(execute "system/routing_test" "$SYSTEM_VERSION" "system")
USER_EID=$(execute "tests/fixtures/routing_test" "$USER_VERSION" "user")
echo

# Give NATS a moment to receive the publishes + the consumer to pull.
sleep 3

echo "==> Sampling consumer deltas"
SYSTEM_AFTER=$(probe_consumer_deliveries "noetl_worker_pool_system")
SHARED_AFTER=$(probe_consumer_deliveries "noetl_worker_pool_shared")
SYSTEM_DELTA=$((SYSTEM_AFTER - SYSTEM_BEFORE))
SHARED_DELTA=$((SHARED_AFTER - SHARED_BEFORE))
echo "    system pool delivered (after):  $SYSTEM_AFTER  (delta=$SYSTEM_DELTA)"
echo "    shared pool delivered (after):  $SHARED_AFTER  (delta=$SHARED_DELTA)"
echo

failures=0

assert_delta() {
    local actual="$1" expected_min="$2" label="$3"
    if [[ "$actual" -ge "$expected_min" ]]; then
        echo "    ✅ $label: delta=$actual (≥ $expected_min)"
    else
        echo "    ❌ $label: delta=$actual (expected ≥ $expected_min)"
        failures=$((failures + 1))
    fi
}

# Each playbook has a single workflow step → exactly one command.issued
# is published per execution.  The system playbook should drive at
# least 1 new delivery on the system consumer; the user playbook should
# drive at least 1 new delivery on the shared consumer.
assert_delta "$SYSTEM_DELTA" 1 "system pool received system-playbook command"
assert_delta "$SHARED_DELTA" 1 "shared pool received user-playbook command"
echo

echo "==> Probing noetl.event for command.issued events"
kubectl --context kind-noetl -n postgres exec "$POSTGRES_POD" -- \
    psql -U noetl -d noetl -At -c "
        SELECT
            execution_id,
            event_type,
            node_name,
            node_type AS tool_kind,
            (SELECT path FROM noetl.catalog WHERE catalog_id = e.catalog_id) AS playbook_path
        FROM noetl.event e
        WHERE execution_id IN ($SYSTEM_EID, $USER_EID)
          AND event_type = 'command.issued'
        ORDER BY execution_id, event_id;
    " | awk -F'|' '{printf "    exec=%s type=%s step=%s tool=%s path=%s\n", $1, $2, $3, $4, $5}'
echo

if [[ "$failures" -gt 0 ]]; then
    echo "==> FAIL: $failures assertion(s) failed"
    exit 1
fi
echo "==> All routing assertions passed"
