#!/usr/bin/env bash
# Kind e2e: the gateway's /noetl/agents route in front of the server's /api/agents
# (build plan item 7, gateway half), exercised as real guest sessions.
#
#   0  gates     load, kind API, images
#   1  arm       snapshot the server; NOETL_AGENT_ENDPOINT on; register echo (guest
#                allowlisted) + hidden_echo (not); run a gateway pod in `noetl`
#                (EHDB KV owners on the cmdbus writer, guest sessions on)
#   2  control   GATEWAY_AGENTS_PROXY unset: a guest gets 403 on /noetl/agents
#                (generic proxy, admins only), as today
#   3  armed     GATEWAY_AGENTS_PROXY=true, guest A:
#                  list shows echo only; hidden card 404; send hidden 404;
#                  send with callback_url 403; send echo 202 → task completes
#                  through /noetl/agents/tasks/{id} with the greeting;
#                guest B: the same task id → 404 (owner-only)
#                no token at all → 401
#   4  restore   server as found; gateway pod, secret, test paths removed
#
# Usage:
#   GATEWAY_IMAGE=localhost/noetl-gateway:<tag> [SERVER_IMAGE=ghcr.io/noetl/server:3.156.2-arm64] \
#     ci/kind/e2e_gateway_agents.sh
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$OPS/ci/kind/agents"
GATEWAY_IMAGE=${GATEWAY_IMAGE:?set GATEWAY_IMAGE to a gateway with /noetl/agents}
SERVER_IMAGE=${SERVER_IMAGE:-ghcr.io/noetl/server:3.156.2-arm64}
MAX_LOAD=${MAX_LOAD:-6}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PORT=${PORT:-38091}; GPORT=${GPORT:-38092}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/gw-agents.XXXXXX")}
ARMED=0; PF=; GPF=
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

restore() {
  if [ -n "$PF" ] && [ -n "${S:-}" ]; then
    for p in tests/agents/hidden_echo; do
      api -X POST "$S/api/catalog/delete" -d "$(jq -n --arg p "$p" '{path:$p}')" >/dev/null 2>&1 || true
    done
  fi
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  [ -n "$GPF" ] && kill "$GPF" 2>/dev/null || true
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring"
    $K delete pod,svc e2e-gateway --ignore-not-found >/dev/null 2>&1 || true
    $K delete secret e2e-gateway-guest --ignore-not-found >/dev/null 2>&1 || true
    $K replace -f "$W/snap/noetl-server-rust.json" >/dev/null && echo "  restored noetl-server-rust" || echo "  !! could not restore (snapshot: $W/snap/noetl-server-rust.json)"
    $K rollout status deploy/noetl-server-rust --timeout=300s >/dev/null || true
  fi
  echo
  echo "passed: $pass  failed: ${#fails[@]}"
  for f in ${fails[@]+"${fails[@]}"}; do echo "  - $f"; done
}
trap restore EXIT

step "0. gates"
L=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || cut -d' ' -f1 /proc/loadavg)
awk -v l="$L" -v m="$MAX_LOAD" 'BEGIN{exit !(l<m)}' || { echo "REFUSED: 1-min load $L >= $MAX_LOAD"; exit 3; }
ok "host load $L (< $MAX_LOAD)"
kubectl --context $CTX get --raw /readyz >/dev/null 2>&1 || { echo "REFUSED: kind API not ready"; exit 4; }
for img in "$SERVER_IMAGE" "$GATEWAY_IMAGE"; do
  podman exec "$NODE" crictl inspecti "$img" >/dev/null 2>&1 && ok "image in node: $img" || { echo "REFUSED: $img not loaded in $NODE"; exit 5; }
done

step "1. arm"
mkdir -p "$W/snap"
$K get deploy noetl-server-rust -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap/noetl-server-rust.json"
ARMED=1
jq --arg img "$SERVER_IMAGE" '
  .spec.template.spec.containers[0].image = $img
  | .spec.template.spec.containers[0].env += [{"name":"NOETL_AGENT_ENDPOINT","value":"true"}]
' "$W/snap/noetl-server-rust.json" | $K replace -f - >/dev/null
$K rollout status deploy/noetl-server-rust --timeout=600s >/dev/null && ok "server ($SERVER_IMAGE) with NOETL_AGENT_ENDPOINT=true" || { bad "server rollout"; exit 1; }
$K port-forward svc/noetl-server-rust "$PORT:8082" >/dev/null 2>&1 & PF=$!
S=http://127.0.0.1:$PORT; i=0
until curl -fsS -m 2 "$S/api/health" >/dev/null 2>&1 || curl -fsS -m 2 "$S/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 90 ] || { bad "server unreachable"; exit 1; }; sleep 1; done
IT=$($K get secret noetl-internal-api-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
api() { curl -sS -m 60 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }
for pb in echo hidden_echo; do
  api -X POST "$S/api/catalog/register" -d "$(jq -n --rawfile c "$FIX/$pb.yaml" '{content:$c,resource_type:"Playbook"}')" > "$W/reg-$pb.json"
  jq -e '.status=="success" or .path!=null' "$W/reg-$pb.json" >/dev/null && ok "registered $pb" || bad "register $pb: $(head -c 300 "$W/reg-$pb.json")"
done
n=$(api "$S/api/agents" | jq '[.agents[]?.agent] | map(select(.=="tests/agents/echo" or .=="tests/agents/hidden_echo")) | length')
[ "$n" = 2 ] && ok "server /api/agents lists both test agents (the unfiltered view)" || bad "server agents: $n"

$K create secret generic e2e-gateway-guest --from-literal=key="$(openssl rand -hex 32)" --dry-run=client -o yaml | $K apply -f - >/dev/null
gateway() { # gateway <agents-proxy: true|unset>
  $K delete pod,svc e2e-gateway --ignore-not-found --wait=true >/dev/null 2>&1 || true
  local extra=""
  [ "$1" = true ] && extra='        - { name: GATEWAY_AGENTS_PROXY, value: "true" }'
  $K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: e2e-gateway, labels: { app: e2e-gateway } }
spec:
  containers:
    - name: gateway
      image: $GATEWAY_IMAGE
      imagePullPolicy: IfNotPresent
      ports: [ { containerPort: 8090 } ]
      env:
        - { name: ROUTER_PORT, value: "8090" }
        - { name: NOETL_BASE_URL, value: "http://noetl-server-rust.noetl.svc.cluster.local:8082" }
        - { name: NOETL_KV_ADDR, value: "noetl-cmdbus-writer-0.noetl.svc.cluster.local:9107" }
        - { name: NOETL_EVENT_FEED_ADDR, value: "noetl-cmdbus-writer-0.noetl.svc.cluster.local:9105" }
        - { name: RUST_LOG, value: "info,gateway=debug" }
        - { name: GATEWAY_GUEST_PLAYBOOKS, value: "tests/agents/echo" }
        - { name: GATEWAY_GUEST_TOKEN_KEY, valueFrom: { secretKeyRef: { name: e2e-gateway-guest, key: key } } }
$extra
YAML
  $K wait --for=condition=Ready pod/e2e-gateway --timeout=120s >/dev/null || return 1
  [ -n "$GPF" ] && kill "$GPF" 2>/dev/null || true
  $K port-forward pod/e2e-gateway "$GPORT:8090" >/dev/null 2>&1 & GPF=$!
  local i=0; until curl -s -m 2 -o /dev/null "http://127.0.0.1:$GPORT/health"; do i=$((i+1)); [ $i -lt 60 ] || return 1; sleep 1; done
}
G=http://127.0.0.1:$GPORT
guest() { curl -sS -m 10 -X POST "$G/api/auth/guest" | jq -r '.session_token // empty'; }
gw() { local t=$1; shift; curl -sS -m 60 -o "$W/gw.json" -w '%{http_code}' -H 'Content-Type: application/json' ${t:+-H "Authorization: Bearer $t"} "$@"; }

step "2. control: GATEWAY_AGENTS_PROXY unset"
gateway unset && ok "gateway pod up ($GATEWAY_IMAGE), agents proxy off" || { bad "gateway pod: $($K logs e2e-gateway --tail=3 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-220)"; exit 1; }
A=$(guest); [ -n "$A" ] && ok "guest session minted" || { bad "guest mint failed"; exit 1; }
c=$(gw "$A" "$G/noetl/agents"); [ "$c" = 403 ] && ok "guest GET /noetl/agents → 403 (generic proxy: admins only)" || bad "control list: $c $(head -c 200 "$W/gw.json")"

step "3. armed: GATEWAY_AGENTS_PROXY=true"
gateway true && ok "gateway pod restarted with GATEWAY_AGENTS_PROXY=true" || { bad "gateway pod: $($K logs e2e-gateway --tail=3 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-220)"; exit 1; }
$K logs e2e-gateway > "$W/gw.log" 2>&1 || true
grep -q "Agents proxy enabled" "$W/gw.log" && ok "gateway logged: Agents proxy enabled" || bad "no enable log line"
A=$(guest); B=$(guest)
c=$(gw "" "$G/noetl/agents"); [ "$c" = 401 ] && ok "no session token → 401" || bad "no-token list: $c"
c=$(gw "$A" "$G/noetl/agents")
if [ "$c" = 200 ] && [ "$(jq -c '[.agents[].agent]' "$W/gw.json")" = '["tests/agents/echo"]' ] && [ "$(jq 'has("not_served")' "$W/gw.json")" = false ]; then
  ok "guest list: only tests/agents/echo (hidden_echo filtered out, not_served removed)"
else
  bad "guest list: $c $(jq -c '[.agents[]?.agent]' "$W/gw.json" 2>/dev/null)"
fi
c=$(gw "$A" "$G/noetl/agents/cards/tests/agents/echo"); [ "$c" = 200 ] && ok "guest card echo → 200" || bad "card echo: $c"
c=$(gw "$A" "$G/noetl/agents/cards/tests/agents/hidden_echo"); [ "$c" = 404 ] && ok "guest card hidden_echo → 404 (looks missing)" || bad "card hidden: $c"
c=$(gw "$A" -X POST "$G/noetl/agents/send" -d '{"agent":"tests/agents/hidden_echo","input":{"who":"x"}}'); [ "$c" = 404 ] && ok "guest send hidden_echo → 404" || bad "send hidden: $c $(head -c 200 "$W/gw.json")"
c=$(gw "$A" -X POST "$G/noetl/agents/send" -d '{"agent":"tests/agents/echo","input":{"who":"x"},"callback_url":"http://example.invalid/cb"}'); [ "$c" = 403 ] && ok "guest send with callback_url → 403 (admin-only)" || bad "send callback: $c"
c=$(gw "$A" -X POST "$G/noetl/agents/send" -d '{"agent":"tests/agents/echo","input":{"who":"guest-a"}}')
T=$(jq -r '.task_id // empty' "$W/gw.json")
[ "$c" = 202 ] && [ -n "$T" ] && ok "guest A send echo → 202, task $T" || bad "send echo: $c $(head -c 300 "$W/gw.json")"
st=; i=0
while [ -n "$T" ]; do c=$(gw "$A" "$G/noetl/agents/tasks/$T"); st=$(jq -r '.status // empty' "$W/gw.json"); case "$st" in completed|failed|canceled|cancelled) break;; esac; i=$((i+1)); [ $i -lt 90 ] || break; sleep 2; done
cp "$W/gw.json" "$W/task-a.json"
[ "$st" = completed ] && jq -e 'tostring|contains("hello guest-a")' "$W/task-a.json" >/dev/null \
  && ok "guest A polls its task through the gateway: completed, \"hello guest-a\"" || bad "task via gateway: status '$st' $(head -c 300 "$W/task-a.json")"
c=$(gw "$B" "$G/noetl/agents/tasks/$T"); [ "$c" = 404 ] && ok "guest B reading guest A's task → 404 (owner-only)" || bad "other guest task read: $c"
c=$(gw "$A" "$G/noetl/agents/tasks/1%20OR%201"); [ "$c" = 400 ] && ok "malformed task id → 400" || bad "bad id: $c"
$K logs e2e-gateway > "$W/gw.log" 2>&1 || true
grep -q "agent send refused" "$W/gw.log" && ok "gateway logged the refused send" || bad "no refusal log line"

[ ${#fails[@]} -eq 0 ]
