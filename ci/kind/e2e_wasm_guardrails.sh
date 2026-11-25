#!/usr/bin/env bash
# Kind e2e: the worker's WASM host guardrails (noetl/ai-meta#548 follow-up).
#
#   0  gates      load, kind API, worker image, the misbehaving modules
#   1  arm        snapshot both worker deployments; roll them to WORKER_IMAGE with
#                 plug-in debug logs (fuel spent per invocation)
#   2  defaults   no NOETL_WASM_* env: a spinning module is stopped by the default
#                 fuel budget, the step FAILS naming the limit, the pod does not
#                 restart, and a well-behaved module (compiled/sum) still answers 50
#   3  tuned      NOETL_WASM_FUEL=0, NOETL_WASM_TIMEOUT_MS=2000, NOETL_WASM_MAX_MEMORY_MB=64:
#                 the spinner is stopped by the wall clock (~2 s), the balloon by the
#                 memory cap, the good module still answers 50
#   4  baseline   the system pool's own drive plug-in (system/orchestrate) ran
#                 under the default budget during the runs above: report its peak
#                 fuel next to the budget
#   5  restore    deployments as found; test paths deleted
#
# Usage:
#   WORKER_IMAGE=localhost/noetl-worker:<tag> PBC_V1=sum_v1.wasm ci/kind/e2e_wasm_guardrails.sh
# PBC_V1 is the compiled sum playbook (server/plugins/playbook-wasm/ci/hot_reload.sh).
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
WORKER_IMAGE=${WORKER_IMAGE:?set WORKER_IMAGE}
PBC_V1=${PBC_V1:?set PBC_V1 to the compiled sum v1 module}
MAX_LOAD=${MAX_LOAD:-6}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PORT=${PORT:-38089}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wasm-guard.XXXXXX")}
DEPS="noetl-worker-rust noetl-worker-system-pool"
ARMED=0; PF=
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

restore() {
  if [ -n "$PF" ] && [ -n "${S:-}" ]; then
    for p in tests/wasm_guard/spin tests/wasm_guard/balloon tests/wasm_guard/good; do
      api -X POST "$S/api/catalog/delete" -d "$(jq -n --arg p "$p" '{path:$p}')" >/dev/null 2>&1 || true
    done
  fi
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring worker deployments"
    for d in $DEPS; do
      $K replace -f "$W/snap/$d.json" >/dev/null && echo "  restored $d" || echo "  !! could not restore $d (snapshot: $W/snap/$d.json)"
    done
    for d in $DEPS; do $K rollout status deploy/$d --timeout=300s >/dev/null || true; done
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
podman exec "$NODE" crictl inspecti "$WORKER_IMAGE" >/dev/null 2>&1 && ok "image in node: $WORKER_IMAGE" || { echo "REFUSED: $WORKER_IMAGE not loaded"; exit 5; }
[ -s "$PBC_V1" ] || { echo "REFUSED: $PBC_V1 missing"; exit 5; }
python3 "$OPS/ci/kind/wasm/make_modules.py" "$W/mods" >/dev/null
ok "modules: spin $(wc -c < "$W/mods/spin.wasm" | tr -d ' ') B, balloon $(wc -c < "$W/mods/balloon.wasm" | tr -d ' ') B, sum $(wc -c < "$PBC_V1" | tr -d ' ') B"

# Roll both worker deployments to WORKER_IMAGE with `extra` env (a jq array).
roll() {
  local extra=$1 d
  for d in $DEPS; do
    jq --arg img "$WORKER_IMAGE" --argjson extra "$extra" '
      .spec.template.spec.containers[0].image = $img
      | .spec.template.spec.containers[0].env = ([.spec.template.spec.containers[0].env[]
          | select(.name != "RUST_LOG" and (.name | startswith("NOETL_WASM_") | not))]
        + [{"name":"RUST_LOG","value":"info,noetl_worker=debug,noetl_executor=debug,noetl_worker::plugin=debug"}]
        + $extra)
    ' "$W/snap/$d.json" | $K replace -f - >/dev/null
  done
  for d in $DEPS; do $K rollout status deploy/$d --timeout=600s >/dev/null || return 1; done
}
# Logs of every current pod of deployment $1 (not just one of them), colour codes stripped.
podlogs() {
  local sel; sel=$($K get deploy "$1" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
  $K logs -l "$sel" --since="${2:-30m}" --tail=-1 --max-log-requests=10 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g'
}
restarts() { $K get pods -l app=noetl-worker-rust -o json | jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0'; }

step "1. arm"
mkdir -p "$W/snap"
for d in $DEPS; do
  $K get deploy "$d" -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap/$d.json"
done
ARMED=1
roll '[]' && ok "workers rolled out on $WORKER_IMAGE (no NOETL_WASM_* env: defaults)" || { bad "rollout"; exit 1; }
SVC=$($K get svc -o name | grep -m1 'noetl-server-rust' | cut -d/ -f2)
$K port-forward "svc/$SVC" "$PORT:8082" >/dev/null 2>&1 & PF=$!
S=http://127.0.0.1:$PORT; i=0
until curl -fsS -m 2 "$S/api/health" >/dev/null 2>&1 || curl -fsS -m 2 "$S/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 90 ] || { bad "server unreachable"; exit 1; }; sleep 1; done
IT=$($K get secret noetl-internal-api-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
api() { curl -sS -m 60 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }
plug() { curl -sS -m 60 ${IT:+-H "Authorization: Bearer $IT"} -H 'Content-Type: application/wasm' --data-binary @"$2" "$S/api/internal/plugins/$1?version=1"; }
reg_runner() { # name plugin-path
  cat > "$W/$1.yaml" <<YAML
apiVersion: noetl.io/v2
kind: Playbook
metadata: { name: $1, path: tests/wasm_guard/$1 }
workflow:
  - step: start
    tool:
      kind: wasm
      plugin: { path: $2, version: 1, entry: run }
      args: { workload: { a: 2, b: 3 } }
    next: [ { step: end } ]
  - step: end
    tool: { kind: noop }
YAML
  api -X POST "$S/api/catalog/register" -d "$(jq -n --rawfile c "$W/$1.yaml" '{content:$c,resource_type:"Playbook"}')" >/dev/null
}
start() { api -X POST "$S/api/execute" -d "$(jq -n --arg p "$1" '{path:$p,payload:{}}')" | jq -r '.execution_id // empty'; }
wait_done() {
  local st i=0
  while :; do st=$(api "$S/api/executions/$1/status" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]'); case "$st" in COMPLETED|FAILED|CANCELLED) break;; esac
    i=$((i+1)); [ $i -lt 120 ] || { st=TIMEOUT; break; }; sleep 1; done
  api "$S/api/executions/$1" > "$W/exec-$1.json"; echo "$st"
}
answer() { jq -r '[.. | objects | select(has("output_b64")) | .output_b64][0] // empty | @base64d | fromjson | .result.answer' "$W/exec-$1.json" 2>/dev/null; }
# Run tests/wasm_guard/$1; echo "STATUS SECONDS".
timed() { local t0 e st; t0=$(date +%s); e=$(start "tests/wasm_guard/$1"); st=$(wait_done "$e"); echo "$st $(( $(date +%s) - t0 )) $e"; }

plug guard/spin "$W/mods/spin.wasm" > "$W/plug-spin.json"
plug guard/balloon "$W/mods/balloon.wasm" > "$W/plug-balloon.json"
plug guard/sum "$PBC_V1" > "$W/plug-sum.json"
for f in spin balloon sum; do jq -e '.digest' "$W/plug-$f.json" >/dev/null || { bad "plug-in $f not registered: $(cat "$W/plug-$f.json")"; exit 1; }; done
reg_runner spin guard/spin; reg_runner balloon guard/balloon; reg_runner good guard/sum
ok "plug-ins guard/{spin,balloon,sum}@1 + three runner playbooks registered"

step "2. defaults (fuel 10e9, 30 s, 1 GiB)"
R0=$(restarts)
read -r ST SEC E <<< "$(timed spin)"
if [ "$ST" = FAILED ] && grep -q "fuel exhausted" "$W/exec-$E.json"; then
  ok "spinning module stopped by the default fuel budget in ~${SEC}s; execution FAILED naming the limit"
else
  bad "spin under defaults: $ST after ${SEC}s; fuel message: $(grep -c 'fuel exhausted' "$W/exec-$E.json")"
fi
read -r ST SEC E <<< "$(timed good)"; A=$(answer "$E")
[ "$ST" = COMPLETED ] && [ "$A" = 50 ] && ok "same workers, next invocation: compiled/sum answered $A" || bad "good module after the trip: $ST answer='$A'"
[ "$(restarts)" = "$R0" ] && ok "no worker restarts (restartCount sum $R0)" || bad "worker restarts: $R0 → $(restarts)"
# The system pool's own drive plug-in ran under the default budget meanwhile.
for d in $DEPS; do podlogs "$d"; done > "$W/log-defaults.txt"
grep 'WASM plug-in invocation' "$W/log-defaults.txt" | grep 'system/orchestrate' \
  | sed -n 's/.*fuel_spent=Some(\([0-9][0-9]*\)).*/\1/p' | sort -n > "$W/orch-fuel.txt" || true

step "3. tuned (fuel off, 2 s wall clock, 64 MiB)"
roll '[{"name":"NOETL_WASM_FUEL","value":"0"},{"name":"NOETL_WASM_TIMEOUT_MS","value":"2000"},{"name":"NOETL_WASM_MAX_MEMORY_MB","value":"64"}]' \
  && ok "workers rolled with NOETL_WASM_FUEL=0 NOETL_WASM_TIMEOUT_MS=2000 NOETL_WASM_MAX_MEMORY_MB=64" || { bad "tuned rollout"; exit 1; }
podlogs noetl-worker-rust 5m > "$W/log-tuned.txt" || true
grep 'WASM plug-in host guardrails' "$W/log-tuned.txt" | grep -q 'fuel=None timeout_ms=Some(2000) max_memory_bytes=Some(67108864)' \
  && ok "worker logged its guardrails at boot: $(grep 'WASM plug-in host guardrails' "$W/log-tuned.txt" | tail -1 | sed 's/.*guardrails//' | tr -s ' ' | cut -c1-90)" \
  || bad "boot guardrail log line missing or wrong"
R0=$(restarts)
read -r ST SEC E <<< "$(timed spin)"
if [ "$ST" = FAILED ] && grep -q "wall-clock limit of 2000 ms" "$W/exec-$E.json"; then
  ok "spinning module stopped by the 2 s wall clock (execution ended in ${SEC}s, FAILED naming the limit)"
else
  bad "spin under tuned: $ST after ${SEC}s; timeout message: $(grep -c 'wall-clock limit' "$W/exec-$E.json")"
fi
read -r ST SEC E <<< "$(timed balloon)"
if [ "$ST" = FAILED ] && grep -q "linear memory would exceed 67108864 bytes" "$W/exec-$E.json"; then
  ok "ballooning module stopped at the 64 MiB memory cap (FAILED naming the limit)"
else
  bad "balloon: $ST; memory message: $(grep -c 'linear memory would exceed' "$W/exec-$E.json")"
fi
read -r ST SEC E <<< "$(timed good)"; A=$(answer "$E")
[ "$ST" = COMPLETED ] && [ "$A" = 50 ] && ok "compiled/sum still answers $A under the tuned limits" || bad "good module tuned: $ST answer='$A'"
[ "$(restarts)" = "$R0" ] && ok "no worker restarts" || bad "worker restarts: $R0 → $(restarts)"
podlogs noetl-worker-rust 10m > "$W/log-worker.txt" || true
n=$(grep -c 'stopped by a host guardrail' "$W/log-worker.txt" || true)
[ "${n:-0}" -ge 2 ] && ok "worker logged $n guardrail trips (limit=timeout / memory)" || bad "guardrail trip logs: ${n:-0}"

step "4. drive plug-in baseline (captured during the defaults phase)"
if [ -s "$W/orch-fuel.txt" ]; then
  echo "  system/orchestrate invocations: $(wc -l < "$W/orch-fuel.txt" | tr -d ' '), fuel min $(head -1 "$W/orch-fuel.txt") / max $(tail -1 "$W/orch-fuel.txt") vs budget 10000000000"
  awk 'END{exit !($1 < 1000000000)}' "$W/orch-fuel.txt" && ok "peak drive fuel $(tail -1 "$W/orch-fuel.txt") is under 10% of the default budget" || bad "drive fuel close to the budget: $(tail -1 "$W/orch-fuel.txt")"
else
  echo "  (no system/orchestrate invocations in this window: the drive plug-in did not run here)"
fi

[ ${#fails[@]} -eq 0 ]
