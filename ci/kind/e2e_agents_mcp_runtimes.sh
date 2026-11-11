#!/usr/bin/env bash
# End-to-end for the MCP + agents capability on the distributed runtime (kind), plus the
# local runtime calling into the cluster. Build plan items 3, 4, 6 (ai-meta
# docs/rfc/interop-missing-tools-build-plan.md) and ai-meta#330. Local kind only.
#
#   0  gates            load, kind API, images present in the node, noetl CLI with `serve`
#   1  arm (kind only)  server: NOETL_TOOL_KIND_MCP, NOETL_TOOL_KIND_AGENT, NOETL_MCP_SERVER,
#                       NOETL_AGENT_ENDPOINT; worker: the image under test +
#                       NOETL_WORKER_AGENT_TOOL=true; an in-cluster stub pod (model, A2A, MCP)
#   2  register         keychain credentials (MCP bearer, model api_key) + 7 playbooks
#   3  direction 1      cluster playbook → third-party MCP (keychain bearer); → the server's
#                       own /api/mcp (a playbook served as MCP, run on the workers)
#   4  direction 2      framework remote → the server's /api/agents (playbook-as-agent) and
#                       → an A2A agent; a model whose tools are an MCP server and a NoETL
#                       agent, answered by the worker's AgentTool
#   5  refusals         a playbook-bound agent tool fails the step on the worker
#   6  local → cluster  `noetl run` (local runtime): kind: mcp → /api/mcp, framework
#                       remote → /api/agents, through the port-forward
#   7  restore          server + worker deployments as found, stub pod and credentials removed
#
#   SERVER_IMAGE=ghcr.io/noetl/server:3.156.0-arm64 WORKER_IMAGE=localhost/noetl-worker:<tag> \
#   NOETL_CLI_BIN=/path/to/noetl ci/kind/e2e_agents_mcp_runtimes.sh
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$OPS/ci/kind/agents"
SERVER_IMAGE=${SERVER_IMAGE:?set SERVER_IMAGE to a server image with items 5 and 7 (server >= 3.156.0)}
WORKER_IMAGE=${WORKER_IMAGE:?set WORKER_IMAGE to a worker with noetl-tools >= 4.5 and NOETL_WORKER_AGENT_TOOL}
CLI=${NOETL_CLI_BIN:?set NOETL_CLI_BIN to a noetl CLI with kind: mcp and framework remote (cli > 6.0.0)}
MAX_LOAD=${MAX_LOAD:-5}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PORT=${PORT:-38084}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/agents-e2e.XXXXXX")}
ARMED=0; PF=
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

restore() {
  if [ -n "${HOLD_FILE:-}" ]; then
    touch "$HOLD_FILE"; echo "holding (rm $HOLD_FILE to restore)"; i=0
    while [ -e "$HOLD_FILE" ] && [ $i -lt 360 ]; do i=$((i+1)); sleep 5; done
  fi
  if [ -n "$PF" ] && [ -n "${S:-}" ]; then
    for c in e2e_agents_mcp e2e_agents_model; do api -X DELETE "$S/api/credentials/$c" >/dev/null 2>&1 || true; done
  fi
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring deployments from $W/snap"
    for d in noetl-server-rust noetl-worker-rust; do
      $K replace -f "$W/snap/$d.json" >/dev/null && echo "  restored $d" || echo "  !! could not restore $d (snapshot: $W/snap/$d.json)"
    done
    for d in noetl-server-rust noetl-worker-rust; do $K rollout status "deploy/$d" --timeout=300s >/dev/null || true; done
    $K delete pod,svc agents-stubs --ignore-not-found >/dev/null || true
    $K delete configmap agents-stubs --ignore-not-found >/dev/null || true
  fi
}
trap restore EXIT

step "0. gates"
L=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || cut -d' ' -f1 /proc/loadavg)
awk -v l="$L" -v m="$MAX_LOAD" 'BEGIN{exit !(l<m)}' || { echo "REFUSED: 1-min load $L >= $MAX_LOAD"; exit 3; }
ok "host load $L (< $MAX_LOAD)"
kubectl --context $CTX get --raw /readyz >/dev/null 2>&1 || { echo "REFUSED: kind API not ready ($CTX)"; exit 4; }
ok "kind API ready ($CTX)"
for img in "$SERVER_IMAGE" "$WORKER_IMAGE"; do
  podman exec "$NODE" crictl inspecti "$img" >/dev/null 2>&1 && ok "image in node: $img" || { echo "REFUSED: $img not loaded in $NODE"; exit 5; }
done
"$CLI" serve --help >/dev/null 2>&1 || { echo "REFUSED: $CLI has no \`serve\` command"; exit 5; }
ok "cli: $("$CLI" --version 2>/dev/null | head -1)"

step "1. arm in kind (snapshot first)"
mkdir -p "$W/snap"
for d in noetl-server-rust noetl-worker-rust; do
  $K get deploy "$d" -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap/$d.json"
done
ok "snapshot: $(ls "$W/snap" | tr '\n' ' ')"
for f in NOETL_TOOL_KIND_MCP NOETL_TOOL_KIND_AGENT NOETL_MCP_SERVER NOETL_AGENT_ENDPOINT; do
  jq -e --arg f "$f" '[.spec.template.spec.containers[0].env[]?|select(.name==$f)]|length==0' "$W/snap/noetl-server-rust.json" >/dev/null \
    && ok "as found, the server does not set $f (gate closed)" || bad "the server as found already sets $f"
done
jq -e '[.spec.template.spec.containers[0].env[]?|select(.name=="NOETL_WORKER_AGENT_TOOL")]|length==0' "$W/snap/noetl-worker-rust.json" >/dev/null \
  && ok "as found, the worker does not set NOETL_WORKER_AGENT_TOOL" || bad "the worker as found already sets NOETL_WORKER_AGENT_TOOL"
MCP_TOKEN=$(openssl rand -hex 24)
ARMED=1
$K delete pod,svc agents-stubs --ignore-not-found >/dev/null 2>&1 || true
$K create configmap agents-stubs --from-file=stubs.py="$FIX/stubs.py" --dry-run=client -o yaml | $K apply -f - >/dev/null
$K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: agents-stubs, labels: { app: agents-stubs } }
spec:
  containers:
    - name: stubs
      image: docker.io/library/python:3.12-alpine
      imagePullPolicy: IfNotPresent
      command: ["python3", "-u", "/stubs/stubs.py"]
      env: [ { name: MCP_TOKEN, value: "$MCP_TOKEN" } ]
      ports: [ { containerPort: 8081 }, { containerPort: 8082 }, { containerPort: 8083 } ]
      volumeMounts: [ { name: stubs, mountPath: /stubs } ]
  volumes: [ { name: stubs, configMap: { name: agents-stubs } } ]
---
apiVersion: v1
kind: Service
metadata: { name: agents-stubs }
spec:
  selector: { app: agents-stubs }
  ports:
    - { name: model, port: 8081 }
    - { name: a2a, port: 8082 }
    - { name: mcp, port: 8083 }
YAML
$K wait --for=condition=Ready pod/agents-stubs --timeout=120s >/dev/null && ok "stub pod up (model :8081, a2a :8082, mcp :8083)" || bad "stub pod not ready"
jq --arg img "$SERVER_IMAGE" '
  .spec.template.spec.containers[0].image = $img
  | .spec.template.spec.containers[0].env += [
      {"name":"NOETL_TOOL_KIND_MCP","value":"true"},
      {"name":"NOETL_TOOL_KIND_AGENT","value":"true"},
      {"name":"NOETL_MCP_SERVER","value":"true"},
      {"name":"NOETL_AGENT_ENDPOINT","value":"true"}]
' "$W/snap/noetl-server-rust.json" | $K replace -f - >/dev/null
jq --arg img "$WORKER_IMAGE" '
  .spec.template.spec.containers[0].image = $img
  | .spec.template.spec.containers[0].env += [{"name":"NOETL_WORKER_AGENT_TOOL","value":"true"}]
' "$W/snap/noetl-worker-rust.json" | $K replace -f - >/dev/null
for d in noetl-server-rust noetl-worker-rust; do
  $K rollout status "deploy/$d" --timeout=600s >/dev/null && ok "$d rolled out" || { bad "$d rollout"; exit 1; }
done

$K port-forward svc/noetl-server-rust "$PORT:8082" >/dev/null 2>&1 & PF=$!
S=http://127.0.0.1:$PORT; i=0
until curl -fsS -m 2 "$S/health" >/dev/null 2>&1 || curl -fsS -m 2 "$S/api/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 60 ] || { bad "server not reachable on $S"; exit 1; }; sleep 1; done
ok "server reachable on $S (port-forward to kind)"
IT=$($K get secret -o json | jq -r '[.items[]|select(.data["NOETL_INTERNAL_API_TOKEN"]!=null)][0].data["NOETL_INTERNAL_API_TOKEN"] // empty' | base64 -d 2>/dev/null || true)
api() { curl -sS -m 150 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }

step "2. register"
api -X POST "$S/api/credentials" -d "$(jq -n --arg t "$MCP_TOKEN" '{name:"e2e_agents_mcp",type:"bearer",data:{token:$t},description:"kind e2e: stub MCP server bearer"}')" > "$W/cred-mcp.json"
jq -e '.name=="e2e_agents_mcp" or .id!=null' "$W/cred-mcp.json" >/dev/null && ok "credential e2e_agents_mcp (bearer)" || bad "credential: $(head -c 300 "$W/cred-mcp.json")"
api -X POST "$S/api/credentials" -d '{"name":"e2e_agents_model","type":"api_key","data":{"api_key":"stub-model-key"},"description":"kind e2e: stub model key"}' > "$W/cred-model.json"
jq -e '.name=="e2e_agents_model" or .id!=null' "$W/cred-model.json" >/dev/null && ok "credential e2e_agents_model (api_key)" || bad "credential: $(head -c 300 "$W/cred-model.json")"
for pb in echo d1_mcp_external d1_mcp_self d2_remote_noetl d2_remote_a2a d2_sources d2_refused; do
  api -X POST "$S/api/catalog/register" -d "$(jq -n --rawfile c "$FIX/$pb.yaml" '{content:$c,resource_type:"Playbook"}')" > "$W/reg-$pb.json"
  jq -e '.status=="success" or .path!=null' "$W/reg-$pb.json" >/dev/null && ok "registered $pb" || bad "register $pb: $(head -c 400 "$W/reg-$pb.json")"
done

run() {  # run <path> → "<execution_id> <STATUS>"
  local eid st i=0
  eid=$(api -X POST "$S/api/execute" -d "$(jq -n --arg p "$1" '{path:$p,payload:{}}')" | jq -r '.execution_id // .id // empty')
  [ -n "$eid" ] || { echo ""; return; }
  while :; do
    st=$(api "$S/api/executions/$eid/status" | jq -r '.status // .state // empty' | tr '[:lower:]' '[:upper:]')
    case "$st" in COMPLETED|FAILED|CANCELLED) break ;; esac
    i=$((i+1)); [ $i -lt 120 ] || { api -X POST "$S/api/executions/$eid/cancel" -d '{}' >/dev/null || true; break; }; sleep 2
  done
  api "$S/api/executions/$eid" > "$W/exec-$eid.json"
  echo "$eid $st"
}
# The step's call.done payload (the tool result), as one JSON value.
calldone() { jq -c --arg s "$2" '[.. | objects | select(has("event_type")) | select(.event_type=="call.done" and (.node_name==$s or .step==$s))][0] // empty' "$W/exec-$1.json"; }
check_run() {  # check_run <path> <step> <label> <jq predicate on the call.done event>
  local E St d
  read -r E St <<<"$(run "$1")"
  [ "$St" = COMPLETED ] || { bad "$3: execution ${E:-<none>} ended ${St:-<no status>} $(jq -c '[..|objects|select(has("error"))|.error]|map(select(.!=null))|.[0:2]' "$W/exec-$E.json" 2>/dev/null | head -c 400)"; return; }
  d=$(calldone "$E" "$2")
  echo "$d" > "$W/calldone-$E.json"
  echo "$d" | jq -e "$4" >/dev/null && ok "$3 (execution $E)" || bad "$3: call.done $(echo "$d" | head -c 500)"
}

step "3. direction 1: a cluster playbook calls an MCP server"
check_run tests/agents/d1_external call "third-party MCP with a keychain bearer credential" \
  'tostring | (contains("site ranch: 3 links up") and contains("authorization"))'
check_run tests/agents/d1_self call "the server's own /api/mcp (a playbook served as MCP, run on the workers)" \
  'tostring | contains("hello d1-self")'

step "4. direction 2: a cluster playbook calls an external agent"
check_run tests/agents/d2_remote_noetl ask "framework remote → /api/agents (playbook-as-agent), result returned" \
  'tostring | (contains("hello d2-remote") and contains("completed"))'
check_run tests/agents/d2_remote_a2a ask "framework remote → A2A agent" \
  'tostring | contains("a2a says: d2-a2a")'
check_run tests/agents/d2_sources ask "model with an MCP server tool and a NoETL agent tool, answered on the worker" \
  'tostring | (contains("site from-model: 3 links up") and contains("hello from-model") and contains("source_tool_calls"))'

step "5. refusals on the worker"
read -r E St <<<"$(run tests/agents/d2_refused)"
[ "$St" = FAILED ] && grep -q "bound to a playbook" "$W/exec-$E.json" \
  && ok "a playbook-bound agent tool fails the step with the reason (execution $E)" || bad "d2_refused ended ${St:-?}: $(grep -o 'bound to a playbook' "$W/exec-$E.json" | head -1)"

step "6. local runtime → cluster"
cat > "$W/local_mcp.yaml" <<YAML
apiVersion: noetl.io/v2
kind: Playbook
metadata: { name: local_to_cluster_mcp }
workflow:
  - step: start
    next: [ { step: call } ]
  - step: call
    tool: { kind: mcp, endpoint: "$S/api/mcp", tool: agents_echo, arguments: { who: from-laptop }, timeout: 100, on_provider_error: fail }
YAML
out=$("$CLI" run "$W/local_mcp.yaml" -r local --json 2>"$W/local_mcp.err" || true)
echo "$out" | grep -q "hello from-laptop" && ok "noetl run (local) kind: mcp → the cluster's /api/mcp" || bad "local mcp: $(echo "$out" | head -c 400) $(tail -3 "$W/local_mcp.err")"
cat > "$W/local_agent.yaml" <<YAML
apiVersion: noetl.io/v2
kind: Playbook
metadata: { name: local_to_cluster_agent }
workflow:
  - step: start
    next: [ { step: ask } ]
  - step: ask
    tool: { kind: agent, framework: remote, remote: { endpoint: "$S", protocol: noetl, agent: tests/agents/echo, timeout: 120 }, input: { who: from-laptop-agent } }
YAML
out=$("$CLI" run "$W/local_agent.yaml" -r local --json 2>"$W/local_agent.err" || true)
echo "$out" | grep -q "hello from-laptop-agent" && ok "noetl run (local) framework remote → the cluster's /api/agents" || bad "local agent: $(echo "$out" | head -c 400) $(tail -3 "$W/local_agent.err")"

step "summary"
echo "  passed: $pass   failed: ${#fails[@]}   (work dir: $W)"
[ ${#fails[@]} -eq 0 ] || { printf '  - %s\n' "${fails[@]}"; exit 1; }
