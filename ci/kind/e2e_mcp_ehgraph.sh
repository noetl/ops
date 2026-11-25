#!/usr/bin/env bash
# End-to-end: `kind: mcp` against the server's embedded ehgraph MCP endpoint, in the local
# kind cluster (RFC ai-meta docs/rfc/interop-topology-and-ai-mcp-playbooks.md, Phase 2).
# Local kind only. Nothing here touches a cloud project.
#
#   0  gates                load, kind API, images present in the node
#   1  arm (kind only)      server: NOETL_TOOL_KIND_MCP=true + embedded ehgraph (bearer grants
#                           from a throwaway Secret); workers: the image under test
#   2  register             keychain credential, `kind: Mcp` mcp/noetl-cluster, two playbooks
#   3  roundtrip            auth alias upsert + header-template read → COMPLETED, the node read
#                           back, and both call.done results recorded on the event log
#   4  refused              no credential + on_provider_error: fail → FAILED, not COMPLETED
#   5  gate closed          the flag's absence is checked on the snapshot: the deployment as
#                           found does not set NOETL_TOOL_KIND_MCP
#   6  restore              server + worker deployments put back exactly as found
#
# Isolation: the deployments are snapshotted before anything changes and restored on exit
# (also on failure). The graph lives under /data/ehgraph-e2e on the server's PVC and is
# removed at the end. A podman machine / kind node that was stopped is started and stopped
# again, so the cluster is left as it was found.
#
#   SERVER_IMAGE=localhost/noetl-server-rust:<tag>  WORKER_IMAGE=localhost/noetl-worker:<tag> \
#     ci/kind/e2e_mcp_ehgraph.sh
#
# Load gate: 1-min load below MAX_LOAD (default 5). On a host whose load average is still
# decaying after a build, MAX_LOAD=<n> overrides it, the same escape the log-analytics e2e has.
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$OPS/ci/kind/mcp"
SERVER_IMAGE=${SERVER_IMAGE:?set SERVER_IMAGE to a server image with ToolKind::Mcp (server >= 026212a)}
WORKER_IMAGE=${WORKER_IMAGE:?set WORKER_IMAGE to a worker image with the mcp auth/catalog/policy change}
MAX_LOAD=${MAX_LOAD:-5}
MACHINE=${PODMAN_MACHINE:-noetl-dev}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PORT=${PORT:-38082}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/mcp-e2e.XXXXXX")}
STARTED=0; NODE_STARTED=0; ARMED=0; PF=
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

restore() {
  if [ -n "${HOLD_FILE:-}" ]; then  # debugging: keep the cluster armed until the file is removed (≤ 30 min)
    touch "$HOLD_FILE"; echo "holding (rm $HOLD_FILE to restore)"; i=0
    while [ -e "$HOLD_FILE" ] && [ $i -lt 360 ]; do i=$((i+1)); sleep 5; done
  fi
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring server + worker deployments from $W/snap"
    for d in noetl-server-rust noetl-worker-rust noetl-worker-system-pool; do
      $K replace -f "$W/snap/$d.json" >/dev/null && echo "  restored $d" || echo "  !! could not restore $d (snapshot: $W/snap/$d.json)"
    done
    $K rollout status deploy/noetl-server-rust --timeout=300s >/dev/null || true
    $K exec deploy/noetl-server-rust -- rm -rf /data/ehgraph-e2e 2>/dev/null || true
    $K delete secret noetl-ehgraph-e2e --ignore-not-found >/dev/null || true
  fi
  if [ "$NODE_STARTED" = 1 ]; then echo "stopping kind node $NODE (it was stopped before this run)"; podman stop "$NODE" >/dev/null || true; fi
  if [ "$STARTED" = 1 ]; then echo "stopping podman machine $MACHINE (it was stopped before this run)"; podman machine stop "$MACHINE" >/dev/null || true; fi
}
trap restore EXIT

step "0. gates"
L=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || cut -d' ' -f1 /proc/loadavg)
awk -v l="$L" -v m="$MAX_LOAD" 'BEGIN{exit !(l<m)}' || { echo "REFUSED: 1-min load $L >= $MAX_LOAD; rerun when the host is quiet"; exit 3; }
ok "host load $L (< $MAX_LOAD)"
if ! kubectl --context $CTX get --raw /readyz >/dev/null 2>&1; then
  if podman machine inspect "$MACHINE" --format '{{.State}}' 2>/dev/null | grep -qv running; then
    echo "  starting podman machine $MACHINE"; podman machine start "$MACHINE" >/dev/null; STARTED=1
  fi
  if [ "$(podman inspect "$NODE" --format '{{.State.Running}}' 2>/dev/null)" = false ]; then
    echo "  starting kind node $NODE"; podman start "$NODE" >/dev/null; NODE_STARTED=1
  fi
  i=0; until kubectl --context $CTX get --raw /readyz >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 150 ] || { echo "FAILED: kind API not ready"; exit 4; }; sleep 2; done
  kubectl --context $CTX wait --for=condition=Ready node --all --timeout=300s >/dev/null
fi
ok "kind API ready ($CTX)"
for img in "$SERVER_IMAGE" "$WORKER_IMAGE"; do
  podman exec "$NODE" crictl inspecti "$img" >/dev/null 2>&1 && ok "image in node: $img" \
    || { echo "REFUSED: $img is not loaded into $NODE (kind load image-archive ...)"; exit 5; }
done

step "1. arm mcp in kind (snapshot first)"
mkdir -p "$W/snap"
for d in noetl-server-rust noetl-worker-rust noetl-worker-system-pool; do
  $K get deploy "$d" -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap/$d.json"
done
ok "snapshot: $(ls "$W/snap" | tr '\n' ' ')"
jq -e '[.spec.template.spec.containers[0].env[]?|select(.name=="NOETL_TOOL_KIND_MCP")]|length==0' "$W/snap/noetl-server-rust.json" >/dev/null \
  && ok "as found, the server does not set NOETL_TOOL_KIND_MCP (gate closed)" || bad "the server as found already sets NOETL_TOOL_KIND_MCP"
TOKEN=$(openssl rand -hex 24)
cat > "$W/ehgraph.toml" <<EOF
instance_id = "ehgraph-noetl-cluster-kind-e2e"
domain = "noetl-cluster"
data_dir = "/data/ehgraph-e2e/data"
backup_prefix = "/data/ehgraph-e2e/backup"

[[auth.grants]]
token = "$TOKEN"
principal = "noetl-e2e"
namespace = "e2e"
read = true
write = true
EOF
$K create secret generic noetl-ehgraph-e2e --from-file=config.toml="$W/ehgraph.toml" --dry-run=client -o yaml | $K apply -f - >/dev/null
ARMED=1
jq --arg img "$SERVER_IMAGE" '
  .spec.template.spec.containers[0].image = $img
  | .spec.template.spec.containers[0].env += [
      {"name":"NOETL_TOOL_KIND_MCP","value":"true"},
      {"name":"NOETL_EHGRAPH_EMBEDDED","value":"true"},
      {"name":"NOETL_EHGRAPH_CONFIG","value":"/etc/noetl-ehgraph/config.toml"},
      {"name":"NOETL_EHGRAPH_HOST_REPLICAS","value":"1"},
      {"name":"NOETL_EHGRAPH_HOST_ORDINAL","value":"0"}]
  | .spec.template.spec.volumes += [{"name":"ehgraph-e2e","secret":{"secretName":"noetl-ehgraph-e2e"}}]
  | .spec.template.spec.containers[0].volumeMounts += [{"name":"ehgraph-e2e","mountPath":"/etc/noetl-ehgraph","readOnly":true}]
' "$W/snap/noetl-server-rust.json" | $K replace -f - >/dev/null
for d in noetl-worker-rust noetl-worker-system-pool; do
  jq --arg img "$WORKER_IMAGE" '.spec.template.spec.containers[0].image = $img' "$W/snap/$d.json" | $K replace -f - >/dev/null
done
for d in noetl-server-rust noetl-worker-rust noetl-worker-system-pool; do
  $K rollout status "deploy/$d" --timeout=400s >/dev/null && ok "$d rolled out" || { bad "$d rollout"; exit 1; }
done

$K port-forward svc/noetl-server-rust "$PORT:8082" >/dev/null 2>&1 & PF=$!
S=http://127.0.0.1:$PORT; i=0
until curl -fsS -m 2 "$S/health" >/dev/null 2>&1 || curl -fsS -m 2 "$S/api/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 60 ] || { bad "server not reachable on $S"; exit 1; }; sleep 1; done
health=$(curl -sS -m 5 "$S/ehgraph/noetl-cluster/healthz")
echo "$health" | jq -e '.domain=="noetl-cluster" and .state=="serving"' >/dev/null \
  && ok "embedded ehgraph serving: $(echo "$health" | jq -c '{instance_id,mode,state}')" || { bad "embedded ehgraph not serving: $health"; exit 1; }

IT=$($K get secret -o json | jq -r '[.items[]|select(.data["NOETL_INTERNAL_API_TOKEN"]!=null)][0].data["NOETL_INTERNAL_API_TOKEN"] // empty' | base64 -d 2>/dev/null || true)
api() { curl -sS -m 30 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }

step "2. register (keychain credential, kind: Mcp, playbooks)"
api -X POST "$S/api/credentials" -d "$(jq -n --arg t "$TOKEN" '{name:"e2e_ehgraph_mcp",type:"bearer",data:{token:$t},description:"kind e2e: embedded ehgraph grant (namespace e2e)"}')" > "$W/cred.json"
jq -e '.name=="e2e_ehgraph_mcp" or .id!=null' "$W/cred.json" >/dev/null && ok "credential e2e_ehgraph_mcp (bearer)" || bad "credential: $(head -c 300 "$W/cred.json")"
reg() { api -X POST "$S/api/catalog/register" -d "$(jq -n --rawfile c "$1" --arg t "$2" '{content:$c,resource_type:$t}')"; }
reg "$FIX/mcp_noetl_cluster.yaml" Mcp > "$W/reg-mcp.json"
jq -e '.path=="mcp/noetl-cluster" or .status=="success"' "$W/reg-mcp.json" >/dev/null && ok "catalog kind: Mcp mcp/noetl-cluster" || bad "register Mcp: $(head -c 300 "$W/reg-mcp.json")"
for pb in ehgraph_roundtrip ehgraph_unauthenticated; do
  reg "$FIX/$pb.yaml" Playbook > "$W/reg-$pb.json"
  jq -e '.status=="success" or .path!=null' "$W/reg-$pb.json" >/dev/null && ok "playbook tests/mcp/$pb registered (kind: mcp accepted)" \
    || bad "register $pb: $(head -c 400 "$W/reg-$pb.json")"
done

run() {  # run <path> → prints execution_id; waits for a terminal status
  local eid st i=0
  eid=$(api -X POST "$S/api/execute" -d "$(jq -n --arg p "$1" '{path:$p,payload:{}}')" | jq -r '.execution_id // .id // empty')
  [ -n "$eid" ] || { echo ""; return; }
  while :; do
    st=$(api "$S/api/executions/$eid/status" | jq -r '.status // .state // empty' | tr '[:lower:]' '[:upper:]')
    case "$st" in COMPLETED|FAILED|CANCELLED) break ;; esac
    i=$((i+1)); [ $i -lt 90 ] || { api -X POST "$S/api/executions/$eid/cancel" -d '{}' >/dev/null || true; break; }; sleep 2
  done
  api "$S/api/executions/$eid" > "$W/exec-$eid.json"
  echo "$eid $st"
}
events() { jq -c '[.. | objects | select(has("event_type"))]' "$W/exec-$1.json"; }

step "3. roundtrip: auth alias upsert + header-template read"
read -r E1 S1 <<<"$(run tests/mcp/ehgraph_roundtrip)"
[ "$S1" = COMPLETED ] && ok "execution $E1 COMPLETED" || bad "execution ${E1:-<none>} ended ${S1:-<no status>}"
if [ -n "${E1:-}" ]; then
  ev=$(events "$E1")
  for s in upsert read; do
    d=$(echo "$ev" | jq -c --arg s "$s" '[.[]|select(.event_type=="call.done" and (.node_name==$s or .step==$s))][0] // empty')
    [ -n "$d" ] || { bad "no call.done for $s on the event log"; continue; }
    echo "$d" > "$W/calldone-$s.json"
    r=$(echo "$d" | jq -c '[.. | objects | select(has("sent_headers"))][0] // empty')
    [ -n "$r" ] || { bad "$s: call.done carries no mcp result: $(echo "$d" | head -c 300)"; continue; }
    echo "$r" | jq -e '.status=="ok" and .result.isError==false and (.endpoint|endswith("/ehgraph/noetl-cluster/mcp")) and .sent_headers==["authorization"]' >/dev/null \
      && ok "$s: call.done on the event log — status ok, isError false, endpoint from catalog, authorization sent" \
      || bad "$s: unexpected result $(echo "$r" | jq -c '{status,endpoint,sent_headers,isError:.result.isError,text:(.text|tostring|.[0:200])}')"
    grep -q "$TOKEN" "$W/calldone-$s.json" && bad "$s: the bearer token appears on the event log" || ok "$s: the bearer token is not on the event log"
  done
  t=$(jq -r '[.. | objects | select(has("sent_headers") and .tool=="graph.node")][0].text // empty' "$W/exec-$E1.json")
  echo "$t" | jq -e '.ok==true and (.data.node.id // .data.id // "")=="e2e:mcp-phase2"' >/dev/null 2>&1 \
    && ok "graph.node read back the node the upsert wrote" || bad "graph.node text: $(echo "$t" | head -c 300)"
fi

step "4. refused: no credential + on_provider_error: fail"
read -r E2 S2 <<<"$(run tests/mcp/ehgraph_unauthenticated)"
[ "$S2" = FAILED ] && ok "execution $E2 FAILED (provider error terminated the step)" || bad "execution ${E2:-<none>} ended ${S2:-<no status>}, expected FAILED"
if [ -n "${E2:-}" ]; then
  events "$E2" | jq -e '[.[]|select(.event_type=="command.failed")]|length>=1' >/dev/null \
    && ok "command.failed recorded for the refused call" || bad "no command.failed on the event log"
  grep -qiE 'unauthori|bearer' "$W/exec-$E2.json" && ok "the failure names the missing credential" || bad "failure text does not mention authorization"
fi

step "summary"
echo "  passed: $pass   failed: ${#fails[@]}   (work dir: $W)"
[ ${#fails[@]} -eq 0 ] || { printf '  - %s\n' "${fails[@]}"; exit 1; }
