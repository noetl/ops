#!/usr/bin/env bash
# Kind-cluster validation for noetl/ai-meta#156 — tail-attach scoping.
#
# Proves the server attaches the per-execution event tail ONLY to allowlisted
# playbooks (the planner + MCP children) and NEVER to the auth path — the
# property that makes login safe by construction after the 2026-06-29 outage
# (global flag-on regressed auth0_login past the gateway's 15s callback budget).
#
# Preconditions (operator):
#   1. Build + load the scoped server image into kind, roll noetl-server-rust.
#   2. Set on the server deploy:
#        NOETL_OFFSERVER_ATTACH_TAIL=true
#        NOETL_OFFSERVER_TAIL_PLAYBOOK_PREFIXES=muno/playbooks/itinerary-planner,automation/agents/mcp/
#   3. Server reachable at $SERVER (default localhost:8082).
#
# Asserts (global counters, diffed across two sequential drives):
#   - planner arm (path muno/playbooks/itinerary-planner-tailscope) →
#       noetl_offserver_tail_attached_total{outcome="attached"} increases,
#       {outcome="scoped_out"} unchanged.
#   - auth arm (path api_integration/auth0/auth0_login-tailscope) →
#       {outcome="scoped_out"} increases, {outcome="attached"} unchanged.
#   - both executions reach COMPLETED.
set -euo pipefail

SERVER="${SERVER:-http://localhost:8082}"
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLANNER_FIXTURE="$THIS_DIR/validate-tail-attach-scope-planner.yaml"
AUTH_FIXTURE="$THIS_DIR/validate-tail-attach-scope-auth.yaml"
CTX="${KCTX:-kind-noetl}"
NS="${NS:-noetl}"

pyget() { python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))"; }

register() {
  local file="$1" label="$2" content response version
  content=$(python3 -c "import json,sys; print(json.dumps({'content': open(sys.argv[1]).read(), 'resource_type': 'Playbook'}))" "$file")
  response=$(curl -sf -X POST "$SERVER/api/catalog/register" -H "Content-Type: application/json" --data-binary "$content")
  version=$(echo "$response" | pyget version)
  [[ -z "$version" ]] && { echo "FATAL: register $label failed: $response" >&2; exit 1; }
  echo "    $label registered v$version" >&2
  echo "$version"
}

execute() {
  local path="$1" version="$2" label="$3" response eid
  response=$(curl -sf -X POST "$SERVER/api/execute" -H "Content-Type: application/json" \
    -d "{\"path\":\"$path\",\"version\":$version,\"tenant_id\":\"muno/tail-scope-rca\"}")
  eid=$(echo "$response" | pyget execution_id)
  [[ -z "$eid" ]] && { echo "FATAL: execute $label failed: $response" >&2; exit 1; }
  echo "    $label execution_id=$eid" >&2
  echo "$eid"
}

wait_completed() {
  local eid="$1" label="$2" i status
  for i in $(seq 1 60); do
    status=$(curl -sf "$SERVER/api/replay/state?execution_id=$eid" 2>/dev/null \
      | python3 -c "import json,sys;
try:
  print(json.load(sys.stdin).get('execution',{}).get('status',''))
except Exception:
  print('')" || echo "")
    [[ "$status" == "COMPLETED" ]] && { echo "    $label COMPLETED (poll $i)" >&2; return 0; }
    [[ "$status" == "FAILED" ]] && { echo "FATAL: $label FAILED" >&2; exit 1; }
    sleep 1
  done
  echo "FATAL: $label did not COMPLETE in 60s (last status=$status)" >&2; exit 1
}

# Scrape one metric series value (0 if absent).
metric() {
  local outcome="$1"
  curl -sf "$SERVER/metrics" 2>/dev/null \
    | grep "^noetl_offserver_tail_attached_total{outcome=\"$outcome\"}" \
    | awk '{print $2}' | head -1 || echo 0
}
snap() { echo "attached=$(metric attached) empty=$(metric empty) scoped_out=$(metric scoped_out)"; }

echo "==> #156 tail-attach scoping validation"
echo "    Server: $SERVER"
echo

echo "==> Registering fixtures"
PV=$(register "$PLANNER_FIXTURE" planner)
AV=$(register "$AUTH_FIXTURE" auth)
echo

A0=$(metric attached); S0=$(metric scoped_out)
echo "==> Baseline: $(snap)"

echo "==> Drive planner arm (IN allowlist → expect attached++)"
PEID=$(execute "muno/playbooks/itinerary-planner-tailscope" "$PV" planner)
wait_completed "$PEID" planner
A1=$(metric attached); S1=$(metric scoped_out)
echo "    after planner: $(snap)"

echo "==> Drive auth arm (OUT of allowlist → expect scoped_out++, attached unchanged)"
AEID=$(execute "api_integration/auth0/auth0_login-tailscope" "$AV" auth)
wait_completed "$AEID" auth
A2=$(metric attached); S2=$(metric scoped_out)
echo "    after auth: $(snap)"
echo

echo "==> Assertions"
fail=0
if (( $(echo "$A1 > $A0" | bc -l) )); then echo "  PASS planner attached++ ($A0 -> $A1)"; else echo "  FAIL planner did not attach ($A0 -> $A1)"; fail=1; fi
if (( $(echo "$S1 == $S0" | bc -l) )); then echo "  PASS planner did NOT scope_out ($S0 -> $S1)"; else echo "  FAIL planner scoped_out moved ($S0 -> $S1)"; fail=1; fi
if (( $(echo "$S2 > $S1" | bc -l) )); then echo "  PASS auth scoped_out++ ($S1 -> $S2)"; else echo "  FAIL auth did not scope_out ($S1 -> $S2)"; fail=1; fi
if (( $(echo "$A2 == $A1" | bc -l) )); then echo "  PASS auth did NOT attach ($A1 -> $A2)"; else echo "  FAIL auth attached moved ($A1 -> $A2) — LOGIN-UNSAFE"; fail=1; fi
echo
if [[ $fail -eq 0 ]]; then echo "==> ALL ASSERTIONS PASSED — auth is scoped out, planner gets the tail."; else echo "==> VALIDATION FAILED"; exit 1; fi
