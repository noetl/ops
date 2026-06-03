#!/usr/bin/env bash
# Kind-cluster validation for noetl/ai-meta#48 — Rust worker resolves
# string `auth:` values (keychain aliases) before tool dispatch.
#
# Validates:
#   1. A playbook with `auth: "{{ pg_auth }}"` (resolves to a string
#      after template render) registers + executes without the
#      "invalid type: string ..., expected struct AuthConfig" serde
#      error that #48 was filed for.
#   2. The Rust worker pool (`noetl_worker_pool_shared`) is the one
#      that claimed the command — pin Python to 0 replicas so this
#      isn't an accidental Python win.
#   3. The execution completes with status=COMPLETED.
#   4. The Rust worker logs do NOT contain the AuthConfig fingerprint.
#
# Run from the ops repo root after building + loading the
# noetl-worker image into kind and rolling the worker pod.

set -euo pipefail

SERVER="${SERVER:-http://localhost:8082}"
POSTGRES_POD=${POSTGRES_POD:-postgres-685d4bb64b-l76dn}
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$THIS_DIR/validate-credential-alias-resolution.yaml"

echo "==> Validating #48 credential alias resolution"
echo "    Server:       $SERVER"
echo "    Postgres pod: $POSTGRES_POD"
echo

# Pin to Rust worker so the test asserts the Rust path specifically.
PIN_RUST_WORKER=${PIN_RUST_WORKER:-1}
ORIGINAL_PY_REPLICAS=""
cleanup() {
    if [[ "$PIN_RUST_WORKER" == "1" && -n "$ORIGINAL_PY_REPLICAS" ]]; then
        echo "==> Cleanup: restoring python noetl-worker to $ORIGINAL_PY_REPLICAS replicas"
        kubectl --context kind-noetl -n noetl scale deployment noetl-worker \
            --replicas="$ORIGINAL_PY_REPLICAS" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [[ "$PIN_RUST_WORKER" == "1" ]]; then
    ORIGINAL_PY_REPLICAS=$(kubectl --context kind-noetl -n noetl get deployment noetl-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    echo "==> Pinning workload to Rust worker (scaling python noetl-worker $ORIGINAL_PY_REPLICAS -> 0)"
    kubectl --context kind-noetl -n noetl scale deployment noetl-worker --replicas=0 >/dev/null 2>&1
    for i in $(seq 1 60); do
        py_pods=$(kubectl --context kind-noetl -n noetl get pods -l app=noetl-worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$py_pods" == "0" ]]; then
            echo "    python noetl-worker drained after ${i}s"
            break
        fi
        sleep 1
    done
fi

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

echo "==> Registering + executing fixture"
VERSION=$(register "$FIXTURE" "fixture")
EID=$(execute "tests/fixtures/credential_alias_resolution" "$VERSION" "alias test")
echo

echo "==> Waiting up to 60s for execution to complete"
for i in $(seq 1 60); do
    RAW=$(curl -sf "$SERVER/api/executions/$EID/status" 2>/dev/null || echo "{}")
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
    if echo "$SUMMARY" | grep -q "completed=True failed=False"; then
        break
    fi
    if echo "$SUMMARY" | grep -q "failed=True"; then
        echo "    FAILED"
        break
    fi
    sleep 1
done
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

echo "==> Probing noetl.event for command lifecycle"
EVENTS=$(kubectl --context kind-noetl -n postgres exec "$POSTGRES_POD" -- \
    psql -U noetl -d noetl -At -c "
        SELECT event_type, node_name, status, worker_id
        FROM noetl.event
        WHERE execution_id = $EID
          AND event_type IN ('command.issued', 'command.claimed', 'command.completed', 'command.failed', 'call.done')
        ORDER BY event_id;
    ")
echo "$EVENTS" | awk -F'|' '{printf "    %s %s status=%s worker=%s\n", $1, $2, $3, $4}'
echo

if echo "$EVENTS" | grep -q "command.completed"; then
    assert true "execution reached command.completed"
elif echo "$EVENTS" | grep -q "command.failed"; then
    assert false "execution failed (command.failed event recorded)"
else
    assert false "execution did not reach a terminal command event"
fi

# Confirm a Rust worker claimed it (worker_id starts with
# `noetl-worker-rust-`).
CLAIM_WORKER=$(echo "$EVENTS" | awk -F'|' '$1=="command.claimed" {print $4; exit}')
if [[ "$CLAIM_WORKER" == noetl-worker-rust-* ]]; then
    assert true "Rust worker claimed the command (worker_id=$CLAIM_WORKER)"
else
    assert false "Expected a Rust worker claim, got worker_id=$CLAIM_WORKER"
fi
echo

echo "==> Scanning Rust pool logs for 'expected struct AuthConfig'"
RUST_POD=$(kubectl --context kind-noetl -n noetl get pod -l app=noetl-worker-rust \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$RUST_POD" ]]; then
    if kubectl --context kind-noetl -n noetl logs "$RUST_POD" --since=2m 2>/dev/null \
        | grep -q "expected struct AuthConfig"; then
        assert false "Rust worker logged 'expected struct AuthConfig' (regression still live)"
    else
        assert true "Rust worker did not log 'expected struct AuthConfig'"
    fi
fi
echo

if [[ "$failures" -gt 0 ]]; then
    echo "==> FAIL: $failures assertion(s) failed"
    exit 1
fi
echo "==> All credential-alias resolution assertions passed"
