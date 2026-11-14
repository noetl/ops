#!/usr/bin/env bash
# Latency bench driver (noetl/ai-meta#557).
#
#   ci/kind/latency/bench.sh register                     # register playbooks/ on the lat stack
#   ci/kind/latency/bench.sh run PLAYBOOK N [C] OUT_DIR   # N executions, C at a time
#   ci/kind/latency/bench.sh auth N OUT_DIR               # the auth/login arm (see auth.sh)
#
# `run` writes OUT_DIR/<execution_id>.json (GET /api/executions/{id}),
# OUT_DIR/children/<id>.json for awaited children, metric scrapes of the server
# and every lat worker pod before and after, and OUT_DIR/run.json. One warm-up
# execution is run first and discarded. Then: report.py OUT_DIR [OTHER_DIR].
#
# Env: LAT_BASE (default: a port-forward to svc/noetl-server-lat on 38090),
#      KIND_CONTEXT (kind-noetl), LABEL / FLAGS (free text recorded in run.json).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CTX=${KIND_CONTEXT:-kind-noetl}; NS=noetl
K="kubectl --context $CTX -n $NS"
PORT=${LAT_PORT:-38090}
BASE=${LAT_BASE:-http://127.0.0.1:$PORT}
PF=""
cleanup() { [ -n "$PF" ] && kill "$PF" 2>/dev/null || true; }
trap cleanup EXIT

ensure_api() {
  if curl -fsS -m 2 "$BASE/api/health" >/dev/null 2>&1; then return; fi
  [ -n "${LAT_BASE:-}" ] && { echo "LAT_BASE $BASE unreachable" >&2; exit 1; }
  $K port-forward svc/noetl-server-lat "$PORT:8082" >/dev/null 2>&1 & PF=$!
  for _ in $(seq 1 60); do curl -fsS -m 2 "$BASE/api/health" >/dev/null 2>&1 && return; sleep 1; done
  echo "lat server unreachable at $BASE" >&2; exit 1
}
hostload() { sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || cut -d' ' -f1 /proc/loadavg; }
api() { curl -sS -m 60 -H 'Content-Type: application/json' "$@"; }

register() {
  ensure_api
  for f in "$HERE"/playbooks/*.yaml; do
    api -X POST "$BASE/api/catalog/register" -d "$(jq -n --rawfile c "$f" '{content:$c,resource_type:"Playbook"}')" \
      | jq -c '{path, version}'
  done
}

scrape() {  # scrape OUT before|after
  local out=$1 when=$2 p
  curl -fsS -m 10 "$BASE/metrics" > "$out/metrics-$when-server.txt" 2>/dev/null || true
  for p in $($K get pods -l noetl-lat=true -o name | grep worker); do
    $K get --raw "/api/v1/namespaces/$NS/pods/${p#pod/}:9090/proxy/metrics" > "$out/metrics-$when-${p#pod/}.txt" 2>/dev/null || true
  done
}

start_exec() { api -X POST "$BASE/api/execute" -d "$(jq -n --arg p "$1" '{path:$p,payload:{}}')" | jq -r '.execution_id // empty'; }

wait_terminal() {  # wait_terminal EID [timeout_s]
  local eid=$1 t=${2:-300} i=0 st
  while :; do
    st=$(api "$BASE/api/executions/$eid/status" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]')
    case "$st" in COMPLETED|FAILED|CANCELLED) echo "$st"; return;; esac
    i=$((i+1)); [ $i -lt $((t*5)) ] || { echo "TIMEOUT"; return; }; sleep 0.2
  done
}

collect() {  # collect EID OUT
  local eid=$1 out=$2 cid
  # The terminal status can land before the materializer has written the last
  # events; re-read until playbook.completed/failed is in the event list.
  for _ in $(seq 1 50); do
    api "$BASE/api/executions/$eid" > "$out/$eid.json"
    jq -e '[.events[]? | select(.event_type == "playbook.completed" or .event_type == "playbook.failed")] | length > 0' "$out/$eid.json" >/dev/null && break
    sleep 0.2
  done
  for cid in $(jq -r '.events[]? | select(.event_type=="call.done") | (.result, .meta) | tostring' "$out/$eid.json" \
               | grep -oE '"child_execution_id":"?[0-9]{12,}' | grep -oE '[0-9]{12,}' | sort -u); do
    mkdir -p "$out/children"
    api "$BASE/api/executions/$cid" > "$out/children/$cid.json"
  done
}

run() {
  local pb=$1 n=$2 c=${3:-1} out=$4
  [ $# -ge 4 ] || { echo "usage: bench.sh run PLAYBOOK N [C] OUT_DIR"; exit 2; }
  ensure_api
  mkdir -p "$out"
  local simg wimg
  simg=$($K get deploy noetl-server-lat -o jsonpath='{.spec.template.spec.containers[0].image}')
  wimg=$($K get deploy noetl-worker-lat -o jsonpath='{.spec.template.spec.containers[0].image}')
  local senv wenv
  senv=$($K get deploy noetl-server-lat -o json | jq -c '[.spec.template.spec.containers[0].env[] | select(.name | test("^NOETL_(WORKER_LOCAL_DRIVE|SERVER_ADVANCE_API|EXECUTION_WAIT|PLAYBOOK_AWAIT_PARK|CATALOG_REMOTE_PUSH|ORCH|STATE_BUILDER$)")) | "\(.name)=\(.value)"]')
  wenv=$($K get deploy noetl-worker-lat -o json | jq -c '[.spec.template.spec.containers[0].env[] | select(.name | test("^NOETL_(WORKER_LOCAL_DRIVE|EXECUTION_WAIT|PLAYBOOK_AWAIT_PARK|STATE_BUILDER$)")) | "\(.name)=\(.value)"]')
  echo "warm-up: $pb"
  local w; w=$(start_exec "$pb"); [ -n "$w" ] && wait_terminal "$w" >/dev/null
  LOAD0=$(hostload)
  scrape "$out" before
  local t0 done=0 eids=() batch=() st e
  t0=$(date +%s)
  while [ $done -lt "$n" ]; do
    batch=()
    for _ in $(seq 1 "$c"); do
      [ $done -lt "$n" ] || break
      e=$(start_exec "$pb"); [ -n "$e" ] || { echo "execute refused"; exit 1; }
      batch+=("$e"); eids+=("$e"); done=$((done+1))
    done
    for e in "${batch[@]}"; do
      st=$(wait_terminal "$e")
      printf '  %s %s\n' "$e" "$st"
    done
  done
  scrape "$out" after
  for e in "${eids[@]}"; do collect "$e" "$out"; done
  jq -n --arg pb "$pb" --argjson n "$n" --argjson c "$c" --arg s "$simg" --arg w "$wimg" \
        --argjson se "$senv" --argjson we "$wenv" --arg label "${LABEL:-}" --arg flags "${FLAGS:-}" \
        --arg at "$(date -u +%FT%TZ)" --argjson secs "$(( $(date +%s) - t0 ))" \
        --arg load0 "$LOAD0" --arg load1 "$(hostload)" \
    '{playbook:$pb, n:$n, concurrency:$c, server_image:$s, worker_image:$w, server_env:$se, worker_env:$we,
      host_load_1m:{start:$load0, end:$load1}, label:$label, flags:(if $flags == "" then ($se + $we | join(" ")) else $flags end), at:$at, seconds:$secs}' > "$out/run.json"
  python3 "$HERE/report.py" "$out"
}

case "${1:-}" in
  register) register;;
  run) shift; run "$@";;
  auth) shift; exec "$HERE/auth.sh" "$@";;
  *) sed -n '2,16p' "$0"; exit 2;;
esac
