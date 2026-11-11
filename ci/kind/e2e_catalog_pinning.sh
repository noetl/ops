#!/usr/bin/env bash
# Kind e2e: content-addressed catalog + execution pinning (noetl/ai-meta#548, Phase 1).
#
# A parent playbook sleeps, then calls a child by path. While the parent sleeps,
# the test registers a NEW version of the child. The question: which child ran?
#
#   0  gates            host load, kind API, server image present in the node
#   1  arm              snapshot the server deployment, set the image + NOETL_CATALOG_CAS=true
#   2  control          pinning OFF: the child registered mid-flight IS what runs (today's behaviour)
#   3  pinned           NOETL_CATALOG_PINNING=true: the child the root saw at start runs
#   4  routes           /api/catalog/{resolve,blob,pin}: digest, sources, the pin rows
#   5  dedup            re-registering identical content makes no version
#   6  restore          server deployment as found; test paths deleted
#
# Usage:
#   SERVER_IMAGE=localhost/noetl-server-rust:<tag> ci/kind/e2e_catalog_pinning.sh
# Optional: HOLD_FILE=/tmp/hold (pause before restore), MAX_LOAD, PORT, WORK.
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$OPS/ci/kind/catalog"
SERVER_IMAGE=${SERVER_IMAGE:?set SERVER_IMAGE to a server image with noetl/ai-meta#548 Phase 1}
MAX_LOAD=${MAX_LOAD:-6}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PORT=${PORT:-38085}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/catalog-e2e.XXXXXX")}
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
    for p in tests/catalog_pin/parent tests/catalog_pin/child; do
      api -X POST "$S/api/catalog/delete" -d "$(jq -n --arg p "$p" '{path:$p}')" >/dev/null 2>&1 || true
    done
  fi
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring noetl-server-rust from $W/snap"
    $K replace -f "$W/snap/noetl-server-rust.json" >/dev/null && echo "  restored" || echo "  !! could not restore (snapshot: $W/snap/noetl-server-rust.json)"
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
kubectl --context $CTX get --raw /readyz >/dev/null 2>&1 || { echo "REFUSED: kind API not ready ($CTX)"; exit 4; }
ok "kind API ready ($CTX)"
podman exec "$NODE" crictl inspecti "$SERVER_IMAGE" >/dev/null 2>&1 && ok "image in node: $SERVER_IMAGE" || { echo "REFUSED: $SERVER_IMAGE not loaded in $NODE"; exit 5; }

step "1. arm (snapshot first)"
mkdir -p "$W/snap"
$K get deploy noetl-server-rust -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap/noetl-server-rust.json"
for f in NOETL_CATALOG_CAS NOETL_CATALOG_PINNING NOETL_CATALOG_HOT_RELOAD; do
  jq -e --arg f "$f" '[.spec.template.spec.containers[0].env[]?|select(.name==$f)]|length==0' "$W/snap/noetl-server-rust.json" >/dev/null \
    && ok "as found, the server does not set $f" || bad "the server as found already sets $f"
done
ARMED=1

arm() {  # arm <pinning true|false>
  jq --arg img "$SERVER_IMAGE" --arg pin "$1" '
    .spec.template.spec.containers[0].image = $img
    | .spec.template.spec.containers[0].env += [{"name":"NOETL_CATALOG_CAS","value":"true"}]
    | if $pin == "true" then .spec.template.spec.containers[0].env += [{"name":"NOETL_CATALOG_PINNING","value":"true"}] else . end
  ' "$W/snap/noetl-server-rust.json" | $K replace -f - >/dev/null
  $K rollout status deploy/noetl-server-rust --timeout=600s >/dev/null || { bad "server rollout (pinning=$1)"; exit 1; }
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  sleep 2
  $K port-forward svc/noetl-server-rust "$PORT:8082" >/dev/null 2>&1 & PF=$!
  S=http://127.0.0.1:$PORT; local i=0
  until curl -fsS -m 2 "$S/health" >/dev/null 2>&1 || curl -fsS -m 2 "$S/api/health" >/dev/null 2>&1; do
    i=$((i+1)); [ $i -lt 90 ] || { bad "server not reachable on $S"; exit 1; }; sleep 1
  done
  # Captured to a file first: `kubectl logs | grep -q` under pipefail fails on SIGPIPE.
  $K logs deploy/noetl-server-rust --since=15m > "$W/server-$1.log" 2>/dev/null || true
  grep -q "catalog CAS tables present" "$W/server-$1.log" \
    && ok "server up, pinning=$1, CAS tables detected" || bad "server log does not report the CAS tables (pinning=$1)"
}
IT=$($K get secret -o json | jq -r '[.items[]|select(.data["NOETL_INTERNAL_API_TOKEN"]!=null)][0].data["NOETL_INTERNAL_API_TOKEN"] // empty' | base64 -d 2>/dev/null || true)
api() { curl -sS -m 60 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }

register_child() {  # register_child <says> → prints the version
  sed "s/SAYS/$1/g" "$FIX/child.yaml.tmpl" > "$W/child-$1.yaml"
  api -X POST "$S/api/catalog/register" -d "$(jq -n --rawfile c "$W/child-$1.yaml" '{content:$c,resource_type:"Playbook"}')" > "$W/reg-child-$1.json"
  jq -r '.version // empty' "$W/reg-child-$1.json"
}
start() { api -X POST "$S/api/execute" -d "$(jq -n --arg p "$1" '{path:$p,payload:{}}')" | jq -r '.execution_id // empty'; }
wait_done() {  # wait_done <eid> → status
  local st i=0
  while :; do
    st=$(api "$S/api/executions/$1/status" | jq -r '.status // .state // empty' | tr '[:lower:]' '[:upper:]')
    case "$st" in COMPLETED|FAILED|CANCELLED) break ;; esac
    i=$((i+1)); [ $i -lt 90 ] || { st="TIMEOUT"; break; }; sleep 2
  done
  api "$S/api/executions/$1" > "$W/exec-$1.json"
  echo "$st"
}
says() { jq -r '[.. | objects | select(has("says")) | .says | strings] | unique | join(",")' "$W/exec-$1.json"; }

scenario() {  # scenario <label> <before> <during> → the parent's eid
  local vb vd eid st
  vb=$(register_child "$2")
  api -X POST "$S/api/catalog/register" -d "$(jq -n --rawfile c "$FIX/parent.yaml" '{content:$c,resource_type:"Playbook"}')" > "$W/reg-parent.json"
  eid=$(start tests/catalog_pin/parent)
  [ -n "$eid" ] || { bad "$1: execute returned no id"; echo ""; return; }
  sleep 6
  vd=$(register_child "$3")
  echo "  $1: parent $eid started with child v$vb ($2); v$vd ($3) registered mid-flight" >&2
  st=$(wait_done "$eid")
  [ "$st" = COMPLETED ] || bad "$1: parent ended $st"
  echo "$eid"
}

step "2. control: CAS on, pinning OFF (today's resolution)"
arm false
E1=$(scenario control one-a two-a)
[ -n "$E1" ] && { S1=$(says "$E1"); [ "$S1" = "two-a" ] && ok "control: the child registered mid-flight ran (says=$S1) — the defect pinning fixes is reproduced" || bad "control: expected two-a, child said '$S1'"; }

step "3. pinned: NOETL_CATALOG_PINNING=true"
arm true
E2=$(scenario pinned one-b two-b)
if [ -n "$E2" ]; then
  S2=$(says "$E2"); [ "$S2" = "one-b" ] && ok "pinned: the child the root saw at start ran (says=$S2)" || bad "pinned: expected one-b, child said '$S2'"
  api "$S/api/catalog/pin/$E2" > "$W/pin-root.json"
  jq -e --arg e "$E2" '.execution_id==$e and .root_execution_id==$e and .reason=="latest" and (.digest|startswith("sha256:"))' "$W/pin-root.json" >/dev/null \
    && ok "root pin: reason=latest, root=itself, digest $(jq -r .digest "$W/pin-root.json" | cut -c1-19)…" || bad "root pin: $(head -c 300 "$W/pin-root.json")"
  jq -e '.. | objects | select(.event_type=="playbook_started") | .context.catalog_pin // empty' "$W/exec-$E2.json" >/dev/null 2>&1 \
    && ok "playbook_started carries catalog_pin" || echo "  note: catalog_pin not visible in /api/executions/{id} (event context not projected there)"
fi
E3=$(start tests/catalog_pin/parent); st=$(wait_done "$E3")
S3=$(says "$E3"); [ "$S3" = "two-b" ] && ok "a new root started afterwards gets the newer child (says=$S3)" || bad "new root: expected two-b, got '$S3' ($st)"

step "4. routes"
api -X POST "$S/api/catalog/resolve" -d '{"ref":"tests/catalog_pin/child"}' > "$W/resolve.json"
D=$(jq -r '.digest // empty' "$W/resolve.json")
jq -e '.reason=="latest" and (.sources|map(.uri)|any(startswith("noetl://local/tests/catalog_pin/child@")))' "$W/resolve.json" >/dev/null \
  && ok "resolve: latest child, digest ${D:0:19}…, local source listed" || bad "resolve: $(head -c 300 "$W/resolve.json")"
api -X POST "$S/api/catalog/resolve" -d "$(jq -n --arg e "$E2" '{ref:"tests/catalog_pin/child", execution_id:($e|tonumber)}')" > "$W/resolve-pinned.json"
jq -e '.reason=="pinned"' "$W/resolve-pinned.json" >/dev/null && ok "resolve inside execution $E2's pin: reason=pinned, v$(jq -r .version "$W/resolve-pinned.json")" || bad "resolve in pin: $(head -c 300 "$W/resolve-pinned.json")"
code=$(curl -s -o "$W/blob.yaml" -w '%{http_code}' "$S/api/catalog/blob/$D")
[ "$code" = 200 ] && grep -q "two-b" "$W/blob.yaml" && ok "blob/{digest}: 200, body is the v-two-b child" || bad "blob: http $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "If-None-Match: \"$D\"" "$S/api/catalog/blob/$D")
[ "$code" = 304 ] && ok "blob: If-None-Match → 304" || bad "blob conditional: http $code"
api -X POST "$S/api/catalog/resolve" -d '{"ref":"tests/catalog_pin/child@latest","execution_id":'"$E2"'}' > "$W/resolve-latest.json"
jq -e '(.error // .message // .detail // "" | tostring | test("hot reload"))' "$W/resolve-latest.json" >/dev/null \
  && ok "@latest inside a pinned tree without the policy/flag: refused by name" || bad "@latest in pin: $(head -c 300 "$W/resolve-latest.json")"

step "5. dedup"
V=$(register_child two-b)
jq -e '.deduplicated==true' "$W/reg-child-two-b.json" >/dev/null && ok "re-registering identical content: deduplicated, version stays $V" || bad "dedup: $(head -c 300 "$W/reg-child-two-b.json")"

[ ${#fails[@]} -eq 0 ]
