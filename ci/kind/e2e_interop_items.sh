#!/usr/bin/env bash
# End-to-end for build plan items 5, 7 and 9 (ai-meta docs/rfc/interop-missing-tools-build-plan.md)
# in the local kind cluster, against a real server image, the kind workers, Postgres and the
# ehdb buses. Local kind only. Nothing here touches a cloud project.
#
#   0  gates            load, kind API, server image in the node, noetl CLI with `instance`
#   1  arm (kind only)  server: NOETL_MCP_SERVER, NOETL_AGENT_ENDPOINT (+ callback origin),
#                       NOETL_INSTANCE_REGISTRY (trust open), topology writer into embedded
#                       ehgraph; a throwaway callback receiver pod
#   2  register         tests/interop/echo (expose.mcp + expose.agent) through the catalog
#   3  item 5 /api/mcp  initialize, tools/list lists interop_echo, tools/call runs it on the
#                       workers and returns the python step's result; an unexposed argument
#                       is refused
#   4  item 7 agents    card listed; send with callback_url → 202 + token; the receiver gets
#                       the final task with that bearer; GET /api/agents/tasks/{id} agrees;
#                       a callback origin not on the allowlist is refused
#   5  item 9 instances two `noetl instance` processes: serve + register/discover/handoff;
#                       admin view lists both; the topology graph holds the instance nodes
#   6  gates closed     on the snapshot, none of the flags are set (prod-shaped default)
#   7  restore          server deployment put back exactly as found, receiver removed
#
#   SERVER_IMAGE=ghcr.io/noetl/server:3.156.0-arm64 NOETL_CLI_BIN=/path/to/noetl \
#     ci/kind/e2e_interop_items.sh
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$OPS/ci/kind/interop"
SERVER_IMAGE=${SERVER_IMAGE:?set SERVER_IMAGE to a server image with items 5/7/9 (server >= 3.156.0)}
CLI=${NOETL_CLI_BIN:?set NOETL_CLI_BIN to a noetl CLI with `noetl instance` (cli >= 5.7.0)}
MAX_LOAD=${MAX_LOAD:-5}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PORT=${PORT:-38083}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/interop-e2e.XXXXXX")}
CB_HOST=interop-cb.$NS.svc.cluster.local:8080
ARMED=0; PF=; SERVE=
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

restore() {
  if [ -n "${HOLD_FILE:-}" ]; then
    touch "$HOLD_FILE"; echo "holding (rm $HOLD_FILE to restore)"; i=0
    while [ -e "$HOLD_FILE" ] && [ $i -lt 360 ]; do i=$((i+1)); sleep 5; done
  fi
  [ -n "$SERVE" ] && kill "$SERVE" 2>/dev/null || true
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring noetl-server-rust from $W/snap"
    $K replace -f "$W/snap/noetl-server-rust.json" >/dev/null && echo "  restored noetl-server-rust" \
      || echo "  !! could not restore (snapshot: $W/snap/noetl-server-rust.json)"
    $K rollout status deploy/noetl-server-rust --timeout=300s >/dev/null || true
    $K exec deploy/noetl-server-rust -- rm -rf /data/ehgraph-interop-e2e 2>/dev/null || true
    $K delete secret noetl-interop-e2e --ignore-not-found >/dev/null || true
    $K delete pod,svc interop-cb --ignore-not-found >/dev/null || true
  fi
}
trap restore EXIT

step "0. gates"
L=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || cut -d' ' -f1 /proc/loadavg)
awk -v l="$L" -v m="$MAX_LOAD" 'BEGIN{exit !(l<m)}' || { echo "REFUSED: 1-min load $L >= $MAX_LOAD"; exit 3; }
ok "host load $L (< $MAX_LOAD)"
kubectl --context $CTX get --raw /readyz >/dev/null 2>&1 || { echo "REFUSED: kind API not ready ($CTX)"; exit 4; }
ok "kind API ready ($CTX)"
"$CLI" instance --help >/dev/null 2>&1 || { echo "REFUSED: $CLI has no \`instance\` command"; exit 5; }
ok "cli: $("$CLI" --version 2>/dev/null | head -1)"

step "1. arm items 5/7/9 in kind (snapshot first)"
mkdir -p "$W/snap"
$K get deploy noetl-server-rust -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap/noetl-server-rust.json"
ok "snapshot taken"
for f in NOETL_MCP_SERVER NOETL_AGENT_ENDPOINT NOETL_INSTANCE_REGISTRY NOETL_EHGRAPH_TOPOLOGY_WRITER; do
  jq -e --arg f "$f" '[.spec.template.spec.containers[0].env[]?|select(.name==$f)]|length==0' "$W/snap/noetl-server-rust.json" >/dev/null \
    && ok "as found, the server does not set $f (gate closed)" || bad "the server as found already sets $f"
done
TOKEN=$(openssl rand -hex 24)
printf '%s' "$TOKEN" > "$W/topology.token"
cat > "$W/ehgraph.toml" <<EOF
instance_id = "ehgraph-noetl-cluster-interop-e2e"
domain = "noetl-cluster"
data_dir = "/data/ehgraph-interop-e2e/data"
backup_prefix = "/data/ehgraph-interop-e2e/backup"

[[auth.grants]]
token = "$TOKEN"
principal = "noetl-instance-registry"
namespace = "topology"
read = true
write = true
EOF
$K create secret generic noetl-interop-e2e --from-file=config.toml="$W/ehgraph.toml" --from-file=topology.token="$W/topology.token" \
  --dry-run=client -o yaml | $K apply -f - >/dev/null
ARMED=1
# Callback receiver: records every POST (headers + body) as one JSON line.
$K delete pod,svc interop-cb --ignore-not-found >/dev/null 2>&1 || true
$K run interop-cb --image=docker.io/library/python:3.12-alpine --image-pull-policy=IfNotPresent --port=8080 --labels=app=interop-cb \
  --command -- python3 -u -c '
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n).decode()
        with open("/tmp/hits.jsonl", "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("authorization"), "body": body}) + "\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
' >/dev/null
$K expose pod interop-cb --port=8080 >/dev/null
$K wait --for=condition=Ready pod/interop-cb --timeout=120s >/dev/null && ok "callback receiver up ($CB_HOST)" || bad "callback receiver not ready"
jq --arg img "$SERVER_IMAGE" --arg cb "http://$CB_HOST" '
  .spec.template.spec.containers[0].image = $img
  | .spec.template.spec.containers[0].env += [
      {"name":"NOETL_MCP_SERVER","value":"true"},
      {"name":"NOETL_AGENT_ENDPOINT","value":"true"},
      {"name":"NOETL_AGENT_CALLBACK_ORIGINS","value":$cb},
      {"name":"NOETL_INSTANCE_REGISTRY","value":"true"},
      {"name":"NOETL_INSTANCE_TRUST","value":"open"},
      {"name":"NOETL_RUNTIME_TTL_SECS","value":"30"},
      {"name":"NOETL_EHGRAPH_EMBEDDED","value":"true"},
      {"name":"NOETL_EHGRAPH_CONFIG","value":"/etc/noetl-interop/config.toml"},
      {"name":"NOETL_EHGRAPH_HOST_REPLICAS","value":"1"},
      {"name":"NOETL_EHGRAPH_HOST_ORDINAL","value":"0"},
      {"name":"NOETL_EHGRAPH_TOPOLOGY_WRITER","value":"true"},
      {"name":"NOETL_EHGRAPH_TOPOLOGY_TOKEN_FILE","value":"/etc/noetl-interop/topology.token"}]
  | .spec.template.spec.volumes += [{"name":"interop-e2e","secret":{"secretName":"noetl-interop-e2e"}}]
  | .spec.template.spec.containers[0].volumeMounts += [{"name":"interop-e2e","mountPath":"/etc/noetl-interop","readOnly":true}]
' "$W/snap/noetl-server-rust.json" | $K replace -f - >/dev/null
$K rollout status deploy/noetl-server-rust --timeout=600s >/dev/null && ok "server rolled out on $SERVER_IMAGE" || { bad "server rollout"; exit 1; }

$K port-forward svc/noetl-server-rust "$PORT:8082" >/dev/null 2>&1 & PF=$!
S=http://127.0.0.1:$PORT; i=0
until curl -fsS -m 2 "$S/health" >/dev/null 2>&1 || curl -fsS -m 2 "$S/api/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 60 ] || { bad "server not reachable on $S"; exit 1; }; sleep 1; done
ok "server reachable on $S"
IT=$($K get secret -o json | jq -r '[.items[]|select(.data["NOETL_INTERNAL_API_TOKEN"]!=null)][0].data["NOETL_INTERNAL_API_TOKEN"] // empty' | base64 -d 2>/dev/null || true)
api() { curl -sS -m 120 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }
rpc() { api -X POST "$S/api/mcp" -d "$(jq -n --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",id:1,method:$m,params:$p}')"; }

step "2. register tests/interop/echo"
api -X POST "$S/api/catalog/register" -d "$(jq -n --rawfile c "$FIX/echo.yaml" '{content:$c,resource_type:"Playbook"}')" > "$W/reg.json"
jq -e '.status=="success" or .path!=null' "$W/reg.json" >/dev/null && ok "registered tests/interop/echo" || bad "register: $(head -c 400 "$W/reg.json")"

step "3. item 5: playbooks over MCP at /api/mcp"
rpc initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"kind-e2e","version":"1"}}' > "$W/mcp-init.json"
jq -e '.result.serverInfo.name and .result.capabilities.tools' "$W/mcp-init.json" >/dev/null && ok "initialize: $(jq -c '.result.serverInfo' "$W/mcp-init.json")" || bad "initialize: $(head -c 300 "$W/mcp-init.json")"
rpc tools/list '{}' > "$W/mcp-list.json"
jq -e '[.result.tools[].name]|index("interop_echo")!=null' "$W/mcp-list.json" >/dev/null && ok "tools/list lists interop_echo ($(jq -c '[.result.tools[].name]' "$W/mcp-list.json"))" || bad "tools/list: $(head -c 400 "$W/mcp-list.json")"
rpc tools/call '{"name":"interop_echo","arguments":{"who":"mcp"}}' > "$W/mcp-call.json"
jq -e '.result.isError==false and (tostring|contains("hello mcp"))' "$W/mcp-call.json" >/dev/null \
  && ok "tools/call ran on the workers: $(jq -c '.result.structuredContent // .result.content[0].text' "$W/mcp-call.json" | head -c 200)" \
  || bad "tools/call: $(head -c 600 "$W/mcp-call.json")"
rpc tools/call '{"name":"interop_echo","arguments":{"who":"x","sneaky":"override"}}' > "$W/mcp-bad.json"
jq -e '(.error!=null) or (.result.isError==true)' "$W/mcp-bad.json" >/dev/null && ok "an argument outside input_schema is refused" || bad "unexposed argument accepted: $(head -c 300 "$W/mcp-bad.json")"

step "4. item 7: agents with completion callbacks"
api "$S/api/agents" > "$W/agents.json"
jq -e '[.agents[]?|select(.agent=="tests/interop/echo")]|length==1' "$W/agents.json" >/dev/null && ok "card listed for tests/interop/echo" || bad "agents: $(head -c 400 "$W/agents.json")"
api -X POST "$S/api/agents/send" -d "$(jq -n --arg cb "http://$CB_HOST/hook" '{agent:"tests/interop/echo",input:{who:"agent"},callback_url:$cb}')" -w '\n%{http_code}' > "$W/send.out"
code=$(tail -1 "$W/send.out"); sed '$d' "$W/send.out" > "$W/send.json"
TID=$(jq -r '.task_id // empty' "$W/send.json"); CBT=$(jq -r '.callback_token // empty' "$W/send.json")
[ "$code" = 202 ] && [ -n "$TID" ] && [ -n "$CBT" ] && ok "send → 202 task $TID with a callback token" || bad "send: $code $(head -c 300 "$W/send.json")"
hit=; i=0
while [ $i -lt 60 ]; do
  hit=$($K exec interop-cb -- cat /tmp/hits.jsonl 2>/dev/null | grep "$TID" | head -1 || true)
  [ -n "$hit" ] && break; i=$((i+1)); sleep 2
done
if [ -n "$hit" ]; then
  echo "$hit" > "$W/callback.json"
  [ "$(jq -r .auth "$W/callback.json")" = "Bearer $CBT" ] && ok "callback delivered with the task's bearer token" || bad "callback auth mismatch"
  jq -r .body "$W/callback.json" | jq -e '.status=="completed" and (tostring|contains("hello agent"))' >/dev/null \
    && ok "callback body: completed, result carries 'hello agent'" || bad "callback body: $(jq -r .body "$W/callback.json" | head -c 400)"
else
  bad "no callback for $TID within 120 s"
fi
api "$S/api/agents/tasks/$TID" > "$W/task.json"
jq -e '.status=="completed" and (tostring|contains("hello agent"))' "$W/task.json" >/dev/null && ok "GET /api/agents/tasks/$TID agrees" || bad "task: $(head -c 400 "$W/task.json")"
code=$(api -o "$W/send-bad.json" -w '%{http_code}' -X POST "$S/api/agents/send" -d '{"agent":"tests/interop/echo","input":{"who":"x"},"callback_url":"http://evil.example:9/hook"}')
[ "$code" -ge 400 ] && ok "callback origin not on the allowlist refused ($code)" || bad "foreign callback origin accepted ($code)"

step "5. item 9: instance register, discover, handoff (two CLI instances)"
mkdir -p "$W/books/edge"
cat > "$W/books/edge/hello.yaml" <<'EOF'
apiVersion: noetl.io/v2
kind: Playbook
metadata: { name: hello }
workload: { who: nobody }
workflow:
  - step: start
    next: [ { step: greet } ]
  - step: greet
    tool: { kind: shell, cmds: [ 'echo "hello {{ workload.who }}"' ] }
EOF
A=$("$CLI" instance init --key "$W/a/key.json"); B=$("$CLI" instance init --key "$W/b/key.json")
[[ "$A" == ni-* && "$B" == ni-* ]] && ok "identities A=$A B=$B (ML-DSA-87)" || bad "init: A=$A B=$B"
"$CLI" instance serve --server "$S" --key "$W/b/key.json" --runtime-kind daemon --site kind-e2e --offer 'edge/*' \
  --playbook-dir "$W/books" --max-tasks 1 >"$W/serve.out" 2>"$W/serve.err" & SERVE=$!
i=0; until api "$S/api/runtime/instances" | jq -e --arg b "$B" '[..|objects|select(.instance_id?==$b)]|length>0' >/dev/null 2>&1; do
  i=$((i+1)); [ $i -lt 60 ] || break; sleep 1; done
[ $i -lt 60 ] && ok "B registered (seen in GET /api/runtime/instances)" || bad "B never showed up: $(tail -5 "$W/serve.err")"
"$CLI" instance register --once --server "$S" --key "$W/a/key.json" --peer "$B" > "$W/reg-a.json" 2>"$W/reg-a.err" \
  && jq -e --arg a "$A" '.instance_id==$a' "$W/reg-a.json" >/dev/null && ok "A registered once, knows B" || bad "register A: $(cat "$W/reg-a.err" | head -c 300)"
"$CLI" instance discover --server "$S" --key "$W/a/key.json" --runs edge/hello > "$W/disc.json" 2>"$W/disc.err" || true
jq -e --arg b "$B" '.count==1 and .instances[0].instance_id==$b and .instances[0].runtime_kind=="daemon"' "$W/disc.json" >/dev/null \
  && ok "discover --runs edge/hello → B (daemon, site kind-e2e)" || bad "discover: $(head -c 400 "$W/disc.json") $(head -c 200 "$W/disc.err")"
"$CLI" instance handoff --server "$S" --key "$W/a/key.json" --at-site kind-e2e --playbook edge/hello \
  --pin "$W/books/edge/hello.yaml" --payload '{"who":"kind"}' --wait 90 > "$W/handoff.json" 2>"$W/handoff.err" || true
jq -e --arg a "$A" --arg b "$B" '.state=="completed" and .from==$a and .to==$b and (.result|tostring|contains("hello kind"))' "$W/handoff.json" >/dev/null \
  && ok "handoff A→B completed through the kind server, result 'hello kind'" || bad "handoff: $(head -c 500 "$W/handoff.json") $(head -c 300 "$W/handoff.err")"
wait "$SERVE" 2>/dev/null && ok "B served one task and exited cleanly" || bad "serve exit: $(tail -5 "$W/serve.err")"; SERVE=
gnode() {
  curl -sS -m 10 -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" "$S/ehgraph/noetl-cluster/mcp" \
    -d "$(jq -n --arg id "$1" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"graph.node",arguments:{namespace:"topology",id:$id}}}')"
}
for who in A B; do
  id=${!who}; gnode "instance:$id" > "$W/gnode-$who.json"
  jq -r '.result.content[0].text // empty' "$W/gnode-$who.json" | jq -e --arg id "instance:$id" '.ok==true and ((.data.node.id // .data.id)==$id)' >/dev/null 2>&1 \
    && ok "topology graph holds instance:$id ($who)" || bad "graph.node instance:$id: $(head -c 300 "$W/gnode-$who.json")"
done

step "6. gates closed by default"
echo "  (checked on the snapshot in step 1: the deployment as found sets none of the item 5/7/9 flags)"

step "summary"
echo "  passed: $pass   failed: ${#fails[@]}   (work dir: $W)"
[ ${#fails[@]} -eq 0 ] || { printf '  - %s\n' "${fails[@]}"; exit 1; }
