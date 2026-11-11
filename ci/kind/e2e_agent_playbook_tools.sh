#!/usr/bin/env bash
# Kind e2e: playbook-bound agent tools on the cluster pools (build plan item 8).
#
#   0  gates     load, kind API, images
#   1  arm       snapshot server + worker; server agent gate on; stub model pod;
#                model credential; register the agent + its two tool playbooks
#   2  control   worker with NOETL_WORKER_AGENT_TOOL only: the agent is refused by
#                name before any model call (today's behaviour)
#   3  budget    + NOETL_WORKER_AGENT_PLAYBOOK_TOOLS, NOETL_AGENT_MAX_TOOL_CALLS=1:
#                the host stops the second tool call, step FAILS naming the budget
#   4  hosted    + NOETL_WORKER_AGENT_PLAYBOOK_TOOLS (default budget): the agent
#                COMPLETES; `greet` ran as a child execution (parent = the agent's
#                execution) claimed by a pool worker, its result reached the model;
#                `broken` failed as a child and came back as an is_error result;
#                agent.turn ×2, agent.tool_call ×2 (child ids), agent.final are on
#                the execution's event log, and in EHDB's view of it
#   5  restore   deployments as found; stub pod, credential, test paths removed
#
# Usage:
#   WORKER_IMAGE=localhost/noetl-worker:<tag> [SERVER_IMAGE=ghcr.io/noetl/server:3.156.2-arm64] \
#     ci/kind/e2e_agent_playbook_tools.sh
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$OPS/ci/kind/agents"
WORKER_IMAGE=${WORKER_IMAGE:?set WORKER_IMAGE to a worker with the hosted agent loop}
SERVER_IMAGE=${SERVER_IMAGE:-ghcr.io/noetl/server:3.156.2-arm64}
MAX_LOAD=${MAX_LOAD:-6}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PORT=${PORT:-38090}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/agent-pbt.XXXXXX")}
ARMED=0; PF=
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

restore() {
  if [ -n "$PF" ] && [ -n "${S:-}" ]; then
    api -X DELETE "$S/api/credentials/e2e_agents_model" >/dev/null 2>&1 || true
    for p in tests/agents/d8_playbook_tools tests/agents/d8_broken; do
      api -X POST "$S/api/catalog/delete" -d "$(jq -n --arg p "$p" '{path:$p}')" >/dev/null 2>&1 || true
    done
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
for img in "$SERVER_IMAGE" "$WORKER_IMAGE"; do
  podman exec "$NODE" crictl inspecti "$img" >/dev/null 2>&1 && ok "image in node: $img" || { echo "REFUSED: $img not loaded in $NODE"; exit 5; }
done

step "1. arm"
mkdir -p "$W/snap"
for d in noetl-server-rust noetl-worker-rust; do
  $K get deploy "$d" -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap/$d.json"
done
for f in NOETL_WORKER_AGENT_TOOL NOETL_WORKER_AGENT_PLAYBOOK_TOOLS; do
  jq -e --arg f "$f" '[.spec.template.spec.containers[0].env[]?|select(.name==$f)]|length==0' "$W/snap/noetl-worker-rust.json" >/dev/null \
    && ok "as found, the worker does not set $f" || bad "the worker as found already sets $f"
done
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
      env: [ { name: MCP_TOKEN, value: "unused" } ]
      ports: [ { containerPort: 8081 } ]
      volumeMounts: [ { name: stubs, mountPath: /stubs } ]
  volumes: [ { name: stubs, configMap: { name: agents-stubs } } ]
---
apiVersion: v1
kind: Service
metadata: { name: agents-stubs }
spec:
  selector: { app: agents-stubs }
  ports: [ { name: model, port: 8081 } ]
YAML
$K wait --for=condition=Ready pod/agents-stubs --timeout=120s >/dev/null && ok "stub model pod up (:8081)" || bad "stub pod not ready"

jq --arg img "$SERVER_IMAGE" '
  .spec.template.spec.containers[0].image = $img
  | .spec.template.spec.containers[0].env += [{"name":"NOETL_TOOL_KIND_AGENT","value":"true"}]
' "$W/snap/noetl-server-rust.json" | $K replace -f - >/dev/null
# Roll the worker to WORKER_IMAGE with the agent gate plus `extra` env (a jq array).
roll_worker() {
  jq --arg img "$WORKER_IMAGE" --argjson extra "$1" '
    .spec.template.spec.containers[0].image = $img
    | .spec.template.spec.containers[0].env += ([{"name":"NOETL_WORKER_AGENT_TOOL","value":"true"}] + $extra)
  ' "$W/snap/noetl-worker-rust.json" | $K replace -f - >/dev/null
  $K rollout status deploy/noetl-worker-rust --timeout=600s >/dev/null
}
roll_worker '[]' || { bad "worker rollout"; exit 1; }
$K rollout status deploy/noetl-server-rust --timeout=600s >/dev/null && ok "server ($SERVER_IMAGE, NOETL_TOOL_KIND_AGENT) + worker ($WORKER_IMAGE, NOETL_WORKER_AGENT_TOOL) rolled out" || { bad "server rollout"; exit 1; }

$K port-forward svc/noetl-server-rust "$PORT:8082" >/dev/null 2>&1 & PF=$!
S=http://127.0.0.1:$PORT; i=0
until curl -fsS -m 2 "$S/api/health" >/dev/null 2>&1 || curl -fsS -m 2 "$S/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 90 ] || { bad "server unreachable"; exit 1; }; sleep 1; done
IT=$($K get secret noetl-internal-api-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
api() { curl -sS -m 150 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }
api -X POST "$S/api/credentials" -d '{"name":"e2e_agents_model","type":"api_key","data":{"api_key":"stub-model-key"},"description":"kind e2e: stub model key"}' > "$W/cred.json"
jq -e '.name=="e2e_agents_model" or .id!=null' "$W/cred.json" >/dev/null && ok "credential e2e_agents_model" || bad "credential: $(head -c 300 "$W/cred.json")"
for pb in echo d8_broken d8_playbook_tools; do
  api -X POST "$S/api/catalog/register" -d "$(jq -n --rawfile c "$FIX/$pb.yaml" '{content:$c,resource_type:"Playbook"}')" > "$W/reg-$pb.json"
  jq -e '.status=="success" or .path!=null' "$W/reg-$pb.json" >/dev/null && ok "registered $pb" || bad "register $pb: $(head -c 300 "$W/reg-$pb.json")"
done

run() {  # run <path> → "<execution_id> <STATUS>"
  local eid st i=0
  eid=$(api -X POST "$S/api/execute" -d "$(jq -n --arg p "$1" '{path:$p,payload:{}}')" | jq -r '.execution_id // empty')
  [ -n "$eid" ] || { echo ""; return; }
  while :; do
    st=$(api "$S/api/executions/$eid/status" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]')
    case "$st" in COMPLETED|FAILED|CANCELLED) break ;; esac
    i=$((i+1)); [ $i -lt 150 ] || { st=TIMEOUT; break; }; sleep 2
  done
  api "$S/api/executions/$eid" > "$W/exec-$eid.json"
  echo "$eid $st"
}
events() { jq -c --arg t "$2" '[.. | objects | select(has("event_type")) | select(.event_type==$t)]' "$W/exec-$1.json"; }
calldone() { jq -c --arg s "$2" '[.. | objects | select(has("event_type")) | select(.event_type=="call.done" and (.node_name==$s or .step==$s))][0] // empty' "$W/exec-$1.json"; }

step "2. control: playbook tools refused without the new flag"
read -r E St <<<"$(run tests/agents/d8_playbook_tools)"
if [ "$St" = FAILED ] && grep -q "is bound to a playbook" "$W/exec-$E.json"; then
  ok "NOETL_WORKER_AGENT_TOOL alone: execution $E FAILED, refused by name (bound to a playbook)"
else
  bad "control: execution $E ended $St; refusal text present: $(grep -c 'bound to a playbook' "$W/exec-$E.json" 2>/dev/null)"
fi

step "3. budget: the host stops the model at NOETL_AGENT_MAX_TOOL_CALLS=1"
roll_worker '[{"name":"NOETL_WORKER_AGENT_PLAYBOOK_TOOLS","value":"true"},{"name":"NOETL_AGENT_MAX_TOOL_CALLS","value":"1"}]' \
  && ok "worker + NOETL_WORKER_AGENT_PLAYBOOK_TOOLS=true NOETL_AGENT_MAX_TOOL_CALLS=1" || { bad "budget rollout"; exit 1; }
read -r E St <<<"$(run tests/agents/d8_playbook_tools)"
if [ "$St" = FAILED ] && grep -q "tool-call budget of 1" "$W/exec-$E.json"; then
  ok "execution $E FAILED naming the budget; the model asked for 2 tools in one turn, the host ran 1"
else
  bad "budget: execution $E ended $St; budget text: $(grep -c 'tool-call budget' "$W/exec-$E.json" 2>/dev/null)"
fi
n=$(events "$E" agent.tool_call | jq length)
[ "$n" = 1 ] && ok "exactly 1 agent.tool_call record before the refusal" || bad "budget run: $n agent.tool_call records"

step "4. hosted: playbook tools run as child executions on the pools"
roll_worker '[{"name":"NOETL_WORKER_AGENT_PLAYBOOK_TOOLS","value":"true"}]' \
  && ok "worker + NOETL_WORKER_AGENT_PLAYBOOK_TOOLS=true (default budget)" || { bad "hosted rollout"; exit 1; }
read -r E St <<<"$(run tests/agents/d8_playbook_tools)"
[ "$St" = COMPLETED ] && ok "agent execution $E COMPLETED" || bad "agent execution $E ended $St: $(jq -c '[..|objects|select(has("error"))|.error]|map(select(.!=null))|.[0:2]' "$W/exec-$E.json" 2>/dev/null | head -c 400)"
d=$(calldone "$E" ask); echo "$d" > "$W/calldone-ask.json"
echo "$d" | jq -e 'tostring | contains("hello from-model")' >/dev/null \
  && ok "the model's final answer carries the child's result (\"hello from-model\")" || bad "final answer: $(echo "$d" | head -c 400)"
echo "$d" | jq -e 'tostring | contains("d8_broken") or contains("FAILED") or contains("failed")' >/dev/null \
  && ok "the failed child came back to the model as a tool error, the step still completed" || bad "broken tool result missing: $(echo "$d" | head -c 400)"

events "$E" agent.turn > "$W/turns.json"; events "$E" agent.tool_call > "$W/calls.json"; events "$E" agent.final > "$W/final.json"
echo "  records: agent.turn=$(jq length "$W/turns.json") agent.tool_call=$(jq length "$W/calls.json") agent.final=$(jq length "$W/final.json")"
[ "$(jq length "$W/turns.json")" = 2 ] && ok "2 agent.turn records (tool_calls, final)" || bad "agent.turn: $(jq -c '[.[]|.result.context // .context // .result]' "$W/turns.json" | head -c 300)"
[ "$(jq length "$W/final.json")" = 1 ] && ok "1 agent.final record" || bad "agent.final: $(jq length "$W/final.json")"
ctxof() { jq -c --arg t "$1" '[.[] | (.result.context // .context // .result // {}) | select(.tool==$t)][0] // {}' "$W/calls.json"; }
G=$(ctxof greet); B=$(ctxof broken)
GC=$(echo "$G" | jq -r '.child_execution_id // empty'); BC=$(echo "$B" | jq -r '.child_execution_id // empty')
[ -n "$GC" ] && [ "$(echo "$G" | jq -r .is_error)" = false ] && ok "agent.tool_call greet → child execution $GC, is_error=false" || bad "greet record: $G"
[ -n "$BC" ] && [ "$(echo "$B" | jq -r .is_error)" = true ] && ok "agent.tool_call broken → child execution $BC, is_error=true" || bad "broken record: $B"

if [ -n "$GC" ]; then
  api "$S/api/executions/$GC" > "$W/child-greet.json"
  cst=$(jq -r '.status // empty' "$W/child-greet.json" | tr '[:lower:]' '[:upper:]')
  par=$(jq -r '.parent_execution_id // .execution.parent_execution_id // empty' "$W/child-greet.json")
  [ "$cst" = COMPLETED ] && ok "child $GC (tests/agents/echo) COMPLETED" || bad "child $GC status $cst"
  [ "$par" = "$E" ] && ok "child $GC has parent_execution_id = $E" || bad "child parent_execution_id '$par' (want $E)"
  wid=$(jq -r '[.. | objects | select(has("event_type")) | select(.event_type=="command.claimed" or .event_type=="command.started") | (.worker_id // .meta.worker_id // .context.worker_id // empty)][0] // empty' "$W/child-greet.json")
  [ -n "$wid" ] && ok "child step claimed by pool worker $wid" || echo "  (child events carry no worker_id field on this server)"
fi
if [ -n "$BC" ]; then
  bst=$(api "$S/api/executions/$BC/status" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]')
  [ "$bst" = FAILED ] && ok "child $BC (tests/agents/d8_broken) FAILED, as designed" || bad "broken child status $bst"
fi

api "$S/api/ehdb/executions/$E/events" > "$W/ehdb-events.json" || true
ne=$(jq '[.. | objects | select(has("event_type")) | select(.event_type|tostring|startswith("agent."))] | length' "$W/ehdb-events.json" 2>/dev/null || echo 0)
if [ "${ne:-0}" -ge 5 ]; then
  ok "EHDB view of execution $E (/api/ehdb/executions/$E/events) holds the $ne agent.* records"
else
  bad "EHDB view: $ne agent.* records ($(head -c 200 "$W/ehdb-events.json"))"
fi

[ ${#fails[@]} -eq 0 ]
