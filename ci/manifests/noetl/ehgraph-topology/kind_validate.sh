#!/usr/bin/env bash
# Validate the topology-writer standup on local kind with the SAME apply.sh / rollback.sh /
# smoke.sh that prod uses, the same config template, the same mount paths
# (/var/secrets/sm/ehgraph-config.toml, /var/secrets/sm/ehgraph-topology-token) and the
# prod server version. Kind has no Secret Store CSI driver, so a plain Secret is mounted at
# /var/secrets/sm instead of the SecretProviderClass (that one step is prod-only).
#
#   SERVER_IMAGE=ghcr.io/noetl/server:3.156.0-arm64 NOETL_CLI_BIN=/path/to/noetl \
#     ci/manifests/noetl/ehgraph-topology/kind_validate.sh
#
# Sequence: phase a → phase b → a trusted instance registers and its node is read back from
# the graph (exercises NOETL_INSTANCE_TRUSTED_IDS too) → rollback b → rollback a (PURGE) →
# deployment restored exactly as found.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export CTX=kind-noetl NS=noetl STS=noetl-server-rust KIND=deployment SVC=noetl-server-rust SPC="" APP_SMOKE=0 PORT=${PORT:-38084}
case "$CTX" in kind-*) ;; *) echo "refusing: not a kind context"; exit 2 ;; esac
SERVER_IMAGE=${SERVER_IMAGE:?set SERVER_IMAGE (the prod server version, arm64)}
CLI=${NOETL_CLI_BIN:?set NOETL_CLI_BIN to a noetl CLI with \`noetl instance\`}
K() { kubectl --context "$CTX" -n "$NS" "$@"; }
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/topology-kind.XXXXXX")}; mkdir -p "$W"; umask 077
pass=0; fails=(); ok() { pass=$((pass+1)); echo "  ok   $*"; }; bad() { fails+=("$*"); echo "  FAIL $*"; }
step() { printf '\n== %s\n' "$*"; }
K get deploy "$STS" -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap.json"
restore() {
  echo; echo "restoring $STS from $W/snap.json"
  pkill -f "port-forward svc/$SVC $PORT:8082" 2>/dev/null || true
  K replace -f "$W/snap.json" >/dev/null && K rollout status "deploy/$STS" --timeout=300s >/dev/null && echo "  restored"
  K delete secret noetl-topology-sm --ignore-not-found >/dev/null
}
trap restore EXIT

step "0. prod-shaped secrets (kind Secret at the CSI mount path) + prod server version"
openssl rand -hex 32 | tr -d '\n' > "$W/token"
TOPOLOGY_TOKEN=$(cat "$W/token") envsubst '${TOPOLOGY_TOKEN}' < "$HERE/config.template.toml" > "$W/ehgraph-config.toml"
cp "$W/token" "$W/ehgraph-topology-token"
K create secret generic noetl-topology-sm --from-file="$W/ehgraph-config.toml" --from-file="$W/ehgraph-topology-token" \
  --dry-run=client -o yaml | K apply -f - >/dev/null
jq --arg img "$SERVER_IMAGE" '
  .spec.template.spec.containers[0].image = $img
  | .spec.template.spec.volumes += [{"name":"sm","secret":{"secretName":"noetl-topology-sm"}}]
  | .spec.template.spec.containers[0].volumeMounts += [{"name":"sm","mountPath":"/var/secrets/sm","readOnly":true}]
' "$W/snap.json" | K replace -f - >/dev/null
K rollout status "deploy/$STS" --timeout=600s >/dev/null && ok "server on $SERVER_IMAGE with /var/secrets/sm mounted" || { bad "baseline roll"; exit 1; }
export TOKEN_CMD="cat $W/token"

step "1. apply.sh a (embedded ehgraph)"
CONFIRM=yes SNAP="$W/snap-a" "$HERE/apply.sh" a && ok "phase a applied + smoked" || bad "phase a"
step "2. apply.sh b (topology writer)"
CONFIRM=yes SNAP="$W/snap-b" "$HERE/apply.sh" b && ok "phase b applied + smoked" || bad "phase b"

step "3. a trusted instance lands in the graph (registry + allowlist, kind only)"
"$CLI" instance init --key "$W/inst/key.json" > "$W/id" 2>/dev/null; ID=$(tr -d '\n' < "$W/id")
K set env "deploy/$STS" NOETL_INSTANCE_REGISTRY=true NOETL_INSTANCE_TRUSTED_IDS="$ID" >/dev/null
K rollout status "deploy/$STS" --timeout=600s >/dev/null
pkill -f "port-forward svc/$SVC $PORT:8082" 2>/dev/null || true
K port-forward "svc/$SVC" "$PORT:8082" >/dev/null 2>&1 & PF=$!
S=http://127.0.0.1:$PORT; for i in $(seq 1 40); do curl -fsS -m 3 "$S/api/health" >/dev/null 2>&1 && break; sleep 1; done
"$CLI" instance register --once --server "$S" --key "$W/inst/key.json" --runtime-kind daemon --site kind-topology > "$W/reg.json" 2>"$W/reg.err" \
  && ok "allowlisted $ID registered" || bad "register: $(head -c 300 "$W/reg.err")"
"$CLI" instance init --key "$W/stranger/key.json" >/dev/null 2>&1
"$CLI" instance register --once --server "$S" --key "$W/stranger/key.json" >/dev/null 2>"$W/stranger.err" \
  && bad "an identity NOT on the allowlist was admitted" || { grep -q 403 "$W/stranger.err" && ok "identity not on the allowlist → 403" || bad "stranger: $(head -c 200 "$W/stranger.err")"; }
node=$(curl -sS -m 10 -H 'Content-Type: application/json' -H "Authorization: Bearer $(cat "$W/token")" "$S/ehgraph/noetl-cluster/mcp" \
  -d "$(jq -n --arg id "instance:$ID" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"graph.node",arguments:{namespace:"topology",id:$id}}}')")
echo "$node" | jq -r '.result.content[0].text // empty' | jq -e --arg id "instance:$ID" '.ok==true and ((.data.node.id // .data.id)==$id)' >/dev/null 2>&1 \
  && ok "topology graph holds instance:$ID" || bad "graph.node: $(echo "$node" | head -c 300)"
kill $PF 2>/dev/null || true
K set env "deploy/$STS" NOETL_INSTANCE_REGISTRY- NOETL_INSTANCE_TRUSTED_IDS- >/dev/null
K rollout status "deploy/$STS" --timeout=600s >/dev/null

step "4. rollback.sh b, then rollback.sh a (PURGE)"
CONFIRM=yes "$HERE/rollback.sh" b > "$W/rb-b.log" 2>&1 && ok "rollback b (writer off) smoked" || bad "rollback b: $(tail -5 "$W/rb-b.log")"
pkill -f "port-forward svc/$SVC $PORT:8082" 2>/dev/null || true
K port-forward "svc/$SVC" "$PORT:8082" >/dev/null 2>&1 & PF=$!
for i in $(seq 1 40); do curl -fsS -m 3 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 1; done
curl -sS -m 5 "http://127.0.0.1:$PORT/ehgraph/noetl-cluster/healthz" | jq -e '.state=="serving"' >/dev/null 2>&1 \
  && ok "after rollback b the graph still serves (writer off only)" || bad "graph down after rollback b"
kill $PF 2>/dev/null || true
K get deploy "$STS" -o json | jq -e '[.spec.template.spec.containers[0].env[]?|select(.name|startswith("NOETL_EHGRAPH_TOPOLOGY"))]|length==0' >/dev/null \
  && ok "writer env removed" || bad "writer env still set"
CONFIRM=yes PURGE=yes "$HERE/rollback.sh" a > "$W/rb-a.log" 2>&1 && ok "rollback a: graph unmounted, /data/ehgraph purged, app healthy" || bad "rollback a: $(tail -5 "$W/rb-a.log")"
tail -4 "$W/rb-a.log"
K get deploy "$STS" -o json | jq -e '[.spec.template.spec.containers[0].env[]?|select(.name|startswith("NOETL_EHGRAPH"))]|length==0' >/dev/null \
  && ok "all NOETL_EHGRAPH_* env removed" || bad "ehgraph env still set"

step "summary"
echo "  passed: $pass   failed: ${#fails[@]}   (work dir: $W)"
[ ${#fails[@]} -eq 0 ] || { printf '  - %s\n' "${fails[@]}"; exit 1; }
