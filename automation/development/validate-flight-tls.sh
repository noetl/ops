#!/usr/bin/env bash
# Kind-cluster end-to-end validation for the R-2.3 Phase C2 trust
# boundary: server TLS (C2.1) + client TLS (C2.2) + bearer-token
# middleware (C2.3) + mTLS (C2.4) — all four knobs on.
#
# Runs from the ops repo root after the worker + server images are
# loaded into kind:
#
#     ./automation/development/validate-flight-tls.sh
#
# Companion files in the same directory:
# - flight-tls-validation.yaml  -- playbook fixture (producer +
#   fetch_via_flight_secure).
# - validate-flight-tls.sql     -- post-run SQL probes.
# - generate-flight-tls.sh      -- bootstrap script that creates
#   the certs + Secrets + patches the deployments.  This runner
#   invokes it for you on entry + tears it down on exit (success
#   or failure).
#
# Lifecycle: the script `generate-flight-tls.sh` is invoked once on
# entry to turn the auth path on, then the noauth result-fetch rig's
# same producer + auth'd fetch step runs, SQL probes confirm the
# call.done carries `status=COMPLETED` (i.e. the mTLS + bearer
# handshake succeeded), and finally the cleanup hook reverts the
# deployments back to no-auth + drops the Secrets so the next rig
# starts from a clean slate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER="http://localhost:8082"
POSTGRES_POD=${POSTGRES_POD:-postgres-685d4bb64b-l76dn}
PLAYBOOK_FILE="$SCRIPT_DIR/flight-tls-validation.yaml"
SQL_FILE="$SCRIPT_DIR/validate-flight-tls.sql"
GENERATE_SCRIPT="$SCRIPT_DIR/generate-flight-tls.sh"

# Pin to the Rust worker (same convention as the result-fetch rig).
# The Phase C2.4 mTLS path lives in noetl-arrow-flight-client +
# noetl-tools, both of which the Rust worker dispatches.
PIN_RUST_WORKER=${PIN_RUST_WORKER:-1}
ORIGINAL_PY_REPLICAS=""

cleanup() {
    echo
    echo "==> Cleanup: reverting Flight TLS auth + restoring workers"
    bash "$GENERATE_SCRIPT" --off || echo "    (Flight TLS revert failed; tolerated)"
    if [[ "$PIN_RUST_WORKER" == "1" && -n "$ORIGINAL_PY_REPLICAS" ]]; then
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

echo
echo "==> Turning on Flight TLS + bearer + mTLS via $GENERATE_SCRIPT"
bash "$GENERATE_SCRIPT"

echo
echo "==> Waiting for noetl-server /api/health to settle after rollout"
for i in $(seq 1 30); do
    if curl -sf "$SERVER/api/health" >/dev/null 2>&1; then
        echo "    healthy after ${i}s"
        break
    fi
    sleep 1
done

echo
echo "==> Registering playbook (injecting bearer token from noetl-flight-bearer Secret)"
# The playbook's `bearer_token` field is a keychain alias by
# convention.  The worker's ExecutionContext.secrets map isn't
# currently populated from envFrom Secrets at startup (that's a
# noetl-worker code gap tracked separately), so the alias falls
# through as a literal and the server rejects with
# `Unauthenticated`.  Until the alias-resolution path lands,
# substitute the literal token into the playbook at registration
# time.  The generated token only exists in the cluster catalog +
# this kind run, never in the repo (per safety.md).
ACTUAL_TOKEN=$(kubectl --context kind-noetl -n noetl get secret noetl-flight-bearer \
    -o jsonpath='{.data.NOETL_FLIGHT_BEARER_TOKENS}' | base64 -d)
if [[ -z "$ACTUAL_TOKEN" ]]; then
    echo "FATAL: couldn't read bearer token from noetl-flight-bearer Secret"
    exit 1
fi
RENDERED_PLAYBOOK=$(mktemp -t flight-tls-validation-rendered.XXXXXX.yaml)
trap 'rm -f "$RENDERED_PLAYBOOK"' RETURN
# Replace the keychain alias placeholder with the literal token.
sed "s|bearer_token: NOETL_FLIGHT_BEARER_TOKEN|bearer_token: \"$ACTUAL_TOKEN\"|" \
    "$PLAYBOOK_FILE" > "$RENDERED_PLAYBOOK"
PLAYBOOK_CONTENT=$(python3 -c "import json,sys; print(json.dumps({'content': open(sys.argv[1]).read(), 'resource_type': 'Playbook'}))" "$RENDERED_PLAYBOOK")
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
# Brief settle for catalog propagation across the server's
# event-log + projector tiers — without this the first execute
# call after a fresh registration can race and return 4xx.
sleep 3
EXEC_RESPONSE=$(curl -sf -X POST "$SERVER/api/execute" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"tests/fixtures/flight_tls_validation\", \"version\": $VERSION}")
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
kubectl --context kind-noetl -n postgres cp "$SQL_FILE" "$POSTGRES_POD:/tmp/validate-flight-tls.sql"

echo
echo "==> Running SQL probes (exec_id=$EXECUTION_ID)"
kubectl --context kind-noetl -n postgres exec "$POSTGRES_POD" -- \
    psql -U noetl -d noetl -v "exec_id=$EXECUTION_ID" -f /tmp/validate-flight-tls.sql

echo
echo "==> Done.  Execution ID for further inspection: $EXECUTION_ID"
