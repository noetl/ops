#!/usr/bin/env bash
# Kind e2e: the hot-reload override and compiled playbooks (noetl/ai-meta#548, Phase 3).
#
#   0  gates            load, kind API, server image, the two compiled modules
#   1  arm              snapshot the server; NOETL_CATALOG_CAS + PINNING + HOT_RELOAD
#   2  hot reload       a 6-iteration loop calls child@latest; v2 is registered mid-loop:
#                         root WITH metadata.catalog.hot_reload → early iterations v1, later v2
#                         control root (plain path)            → every iteration v1 (pinned)
#                         root WITHOUT the policy, @latest     → refused by name, FAILED
#   3  compiled wasm    compiled/sum@1 registered as a plug-in; a `kind: wasm` step runs it on
#                       the worker → answer 50; the SAME version re-registered with v2's bytes
#                       → the worker reloads by digest → answer 500
#   4  restore          server as found; test paths deleted
#
# Usage:
#   SERVER_IMAGE=localhost/noetl-server-rust:<tag> PBC_V1=sum_v1.wasm PBC_V2=sum_v2.wasm \
#     ci/kind/e2e_catalog_hot_reload.sh
# Build the modules with server/plugins/playbook-wasm/ci/hot_reload.sh.
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$OPS/ci/kind/catalog/hot"
SERVER_IMAGE=${SERVER_IMAGE:?set SERVER_IMAGE}
PBC_V1=${PBC_V1:?set PBC_V1 to the compiled sum v1 module}
PBC_V2=${PBC_V2:?set PBC_V2 to the compiled sum v2 module}
MAX_LOAD=${MAX_LOAD:-6}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PSQL="kubectl --context $CTX -n postgres exec -i deploy/postgres -- psql -U noetl -d noetl -tA"
PORT=${PORT:-38088}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/hot-e2e.XXXXXX")}
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
    for p in tests/catalog_hot/child tests/catalog_hot/root tests/catalog_hot/pinned tests/catalog_hot/refused tests/compiled/run_sum; do
      api -X POST "$S/api/catalog/delete" -d "$(jq -n --arg p "$p" '{path:$p}')" >/dev/null 2>&1 || true
    done
  fi
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring noetl-server-rust"
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
kubectl --context $CTX get --raw /readyz >/dev/null 2>&1 || { echo "REFUSED: kind API not ready"; exit 4; }
podman exec "$NODE" crictl inspecti "$SERVER_IMAGE" >/dev/null 2>&1 && ok "image in node: $SERVER_IMAGE" || { echo "REFUSED: $SERVER_IMAGE not loaded"; exit 5; }
for f in "$PBC_V1" "$PBC_V2"; do [ -s "$f" ] || { echo "REFUSED: $f missing"; exit 5; }; done
ok "modules: v1 $(shasum -a 256 "$PBC_V1" | cut -c1-12)…, v2 $(shasum -a 256 "$PBC_V2" | cut -c1-12)…"

step "1. arm"
mkdir -p "$W/snap"
$K get deploy noetl-server-rust -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap/noetl-server-rust.json"
ARMED=1
jq --arg img "$SERVER_IMAGE" '
  .spec.template.spec.containers[0].image = $img
  | .spec.template.spec.containers[0].env += [
      {"name":"NOETL_CATALOG_CAS","value":"true"},
      {"name":"NOETL_CATALOG_PINNING","value":"true"},
      {"name":"NOETL_CATALOG_HOT_RELOAD","value":"true"}]
' "$W/snap/noetl-server-rust.json" | $K replace -f - >/dev/null
$K rollout status deploy/noetl-server-rust --timeout=600s >/dev/null && ok "server rolled out with CAS + PINNING + HOT_RELOAD" || { bad "rollout"; exit 1; }
$K port-forward svc/noetl-server-rust "$PORT:8082" >/dev/null 2>&1 & PF=$!
S=http://127.0.0.1:$PORT; i=0
until curl -fsS -m 2 "$S/health" >/dev/null 2>&1 || curl -fsS -m 2 "$S/api/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 90 ] || { bad "server unreachable"; exit 1; }; sleep 1; done
IT=$($K get secret -o json | jq -r '[.items[]|select(.data["NOETL_INTERNAL_API_TOKEN"]!=null)][0].data["NOETL_INTERNAL_API_TOKEN"] // empty' | base64 -d 2>/dev/null || true)
api() { curl -sS -m 60 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }
reg() { api -X POST "$S/api/catalog/register" -d "$(jq -n --rawfile c "$1" '{content:$c,resource_type:"Playbook"}')"; }
start() { api -X POST "$S/api/execute" -d "$(jq -n --arg p "$1" '{path:$p,payload:{}}')" | jq -r '.execution_id // empty'; }
wait_done() {
  local st i=0
  while :; do st=$(api "$S/api/executions/$1/status" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]'); case "$st" in COMPLETED|FAILED|CANCELLED) break;; esac
    i=$((i+1)); [ $i -lt 120 ] || { st=TIMEOUT; break; }; sleep 2; done
  api "$S/api/executions/$1" > "$W/exec-$1.json"; echo "$st"
}
# Child executions of a root, in start order: "version reason" per line.
children() { $PSQL -c "select version || ' ' || reason from noetl.execution_catalog_pin where root_execution_id = $1 and execution_id <> $1 order by created_at"; }

step "2. hot reload"
sed 's/SAYS/h1/' "$FIX/child.yaml.tmpl" > "$W/child-h1.yaml"; sed 's/SAYS/h2/' "$FIX/child.yaml.tmpl" > "$W/child-h2.yaml"
V1=$(reg "$W/child-h1.yaml" | jq -r .version)
for pb in root pinned refused; do reg "$FIX/$pb.yaml" > "$W/reg-$pb.json"; done
R=$(start tests/catalog_hot/root); P=$(start tests/catalog_hot/pinned); X=$(start tests/catalog_hot/refused)
echo "  root=$R pinned=$P refused=$X; child v$V1 (h1) at start"
sleep 11
V2=$(reg "$W/child-h2.yaml" | jq -r .version)
echo "  child v$V2 (h2) registered mid-loop"
SR=$(wait_done "$R"); SP=$(wait_done "$P"); SX=$(wait_done "$X")
children "$R" > "$W/children-root.txt"; children "$P" > "$W/children-pinned.txt"
echo "  root children:   $(tr '\n' ';' < "$W/children-root.txt")"
echo "  pinned children: $(tr '\n' ';' < "$W/children-pinned.txt")"
[ "$SR" = COMPLETED ] && ok "hot root COMPLETED" || bad "hot root ended $SR"
n=$(wc -l < "$W/children-root.txt" | tr -d ' ')
first=$(head -1 "$W/children-root.txt"); last=$(tail -1 "$W/children-root.txt")
if [ "$n" -ge 4 ] && [ "$first" = "$V1 hot_reload" ] && [ "$last" = "$V2 hot_reload" ] && ! grep -qv "hot_reload$" "$W/children-root.txt"; then
  ok "with the policy + flag + @latest: iterations moved from v$V1 to v$V2 mid-loop ($n iterations, every pin reason=hot_reload)"
else
  bad "hot reload: expected first '$V1 hot_reload', last '$V2 hot_reload', got: $(tr '\n' ';' < "$W/children-root.txt")"
fi
[ "$SP" = COMPLETED ] && ok "control root COMPLETED" || bad "control root ended $SP"
if [ "$(sort -u "$W/children-pinned.txt")" = "$V1 pinned" ] && [ "$(wc -l < "$W/children-pinned.txt" | tr -d ' ')" -ge 4 ]; then
  ok "control (plain path, no policy): every iteration stayed on v$V1 (reason=pinned) while v$V2 existed"
else
  bad "control: $(tr '\n' ';' < "$W/children-pinned.txt")"
fi
if [ "$SX" = FAILED ] && grep -q "hot reload" "$W/exec-$X.json"; then
  ok "@latest without the root's policy: refused by name, root FAILED"
else
  bad "refused root ended $SX; hot-reload message present: $(grep -c 'hot reload' "$W/exec-$X.json")"
fi

step "3. compiled playbook on the worker"
plug() { curl -sS -m 60 ${IT:+-H "Authorization: Bearer $IT"} -H 'Content-Type: application/wasm' --data-binary @"$1" "$S/api/internal/plugins/compiled/sum?version=1"; }
answer() { jq -r '[.. | objects | select(has("output_b64")) | .output_b64][0] // empty | @base64d | fromjson | .result.answer' "$W/exec-$1.json" 2>/dev/null; }
D1=$(plug "$PBC_V1" | jq -r .digest)
reg "$FIX/run_sum.yaml" > "$W/reg-run_sum.json"
E1=$(start tests/compiled/run_sum); S1=$(wait_done "$E1"); A1=$(answer "$E1")
[ "$S1" = COMPLETED ] && [ "$A1" = 50 ] && ok "compiled/sum@1 (module ${D1:0:12}…) ran in the worker: answer=$A1" || bad "v1 module run: $S1 answer='$A1'"
D2=$(plug "$PBC_V2" | jq -r .digest)
[ "$D1" != "$D2" ] && ok "re-registered compiled/sum@1 with v2 bytes: digest ${D1:0:12}… → ${D2:0:12}…" || bad "re-register did not change the digest"
E2=$(start tests/compiled/run_sum); S2=$(wait_done "$E2"); A2=$(answer "$E2")
[ "$S2" = COMPLETED ] && [ "$A2" = 500 ] && ok "same plug-in version, new digest: the worker hot-reloaded, answer=$A2" || bad "v2 module run: $S2 answer='$A2'"

[ ${#fails[@]} -eq 0 ]
