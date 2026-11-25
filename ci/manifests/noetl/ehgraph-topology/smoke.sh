#!/usr/bin/env bash
# Smoke for the topology-writer standup. Opens its own port-forward to the server Service.
#   phase a: /ehgraph/noetl-cluster/healthz serving; MCP initialize with the grant token;
#            graph.node in `topology` authorized with the grant; no token / a wrong token → UNAUTHORIZED
#   phase b: the same, plus the server log shows no topology-writer error since the roll
#   always:  the app smokes (ci/prod-smoke/server_smoke.sh + gateway_smoke.sh) unless APP_SMOKE=0
# SKIP_GRAPH=1 checks only that the graph is gone (rollback) and runs the app smokes.
# TOKEN_CMD prints the grant token to stdout (default: GSM); it is held in a variable only.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); OPS=$(cd "$HERE/../../../.." && pwd)
CTX=${CTX:-noetl-prod}; NS=${NS:-noetl}; SVC=${SVC:-noetl-server-rust}; STS=${STS:-noetl-server-rust-embedded}; KIND=${KIND:-statefulset}
PORT=${PORT:-18082}; LABEL=${1:-smoke}
TOKEN_CMD=${TOKEN_CMD:-gcloud secrets versions access latest --secret noetl-ehgraph-topology-token --project shastaratech-noetl-prod}
fail=0; say() { printf '  %-5s %s\n' "$1" "$2"; }
S=http://127.0.0.1:$PORT
pkill -f "port-forward svc/$SVC $PORT:8082" 2>/dev/null || true
kubectl --context "$CTX" -n "$NS" port-forward "svc/$SVC" "$PORT:8082" >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for i in $(seq 1 40); do curl -fsS -m 3 "$S/api/health" >/dev/null 2>&1 && break; sleep 1; done
echo "== topology smoke [$LABEL] on $CTX"
hz=$(curl -sS -m 5 -w ' %{http_code}' "$S/ehgraph/noetl-cluster/healthz")
if [ "${SKIP_GRAPH:-}" = 1 ]; then
  case "$hz" in *' 404'|*' 503') say ok "embedded ehgraph not mounted (${hz##* })" ;; *) say FAIL "graph still answers: $hz"; fail=1 ;; esac
else
  echo "${hz% *}" | jq -e '.domain=="noetl-cluster" and .state=="serving"' >/dev/null 2>&1 \
    && say ok "ehgraph serving: $(echo "${hz% *}" | jq -c '{instance_id,mode,state}')" || { say FAIL "healthz: $hz"; fail=1; }
  TOKEN=$(eval "$TOKEN_CMD" 2>/dev/null | tr -d '\n')
  [ -n "$TOKEN" ] || { say FAIL "could not read the grant token"; fail=1; }
  # ehgraph by design answers initialize / tools/list without a token and enforces the grant
  # per tools/call (the envelope carries UNAUTHORIZED), so the auth checks use tools/call.
  READ='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"graph.node","arguments":{"namespace":"topology","id":"control:smoke-probe"}}}'
  call() { curl -sS -m 10 -H 'Content-Type: application/json' ${1:+-H "Authorization: Bearer $1"} "$S/ehgraph/noetl-cluster/mcp" -d "$READ" | jq -r '.result.content[0].text // empty'; }
  t=$(call "$TOKEN")
  [ -n "$t" ] && ! echo "$t" | grep -q UNAUTHORIZED && say ok "graph.node in topology with the grant: authorized ($(echo "$t" | jq -c '{ok,code:.error.code}' 2>/dev/null))" \
    || { say FAIL "graph.node with the grant: $(echo "$t" | head -c 200)"; fail=1; }
  t=$(call ""); echo "$t" | grep -q UNAUTHORIZED && say ok "no token → UNAUTHORIZED" || { say FAIL "no token: $(echo "$t" | head -c 200)"; fail=1; }
  t=$(call "wrong-$RANDOM"); echo "$t" | grep -q UNAUTHORIZED && say ok "wrong token → UNAUTHORIZED" || { say FAIL "wrong token: $(echo "$t" | head -c 200)"; fail=1; }
  unset TOKEN
  if [ "$LABEL" = b ]; then
    n=$(kubectl --context "$CTX" -n "$NS" logs "$KIND/$STS" --since=5m 2>/dev/null | grep -c 'NOETL_EHGRAPH_TOPOLOGY_WRITER=true but')
    [ "$n" = 0 ] && say ok "no topology-writer error in the server log" || { say FAIL "topology writer did not start ($n errors)"; fail=1; }
  fi
fi
if [ "${APP_SMOKE:-1}" != 0 ]; then
  S=$S bash "$OPS/ci/prod-smoke/server_smoke.sh" "topology-$LABEL" || fail=1
  bash "$OPS/ci/prod-smoke/gateway_smoke.sh" "topology-$LABEL" || fail=1
fi
exit $fail
