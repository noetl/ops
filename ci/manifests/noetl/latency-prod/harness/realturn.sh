#!/usr/bin/env bash
# realturn.sh N OUT : N real travel turns (muno/playbooks/itinerary-planner, thread _smoke-lat-<ts>-<i>), serial.
set -euo pipefail
N=${1:?}; OUT=${2:?}; BASE=${LAT_BASE:-http://127.0.0.1:38190}; mkdir -p "$OUT"
api() { curl -sS -m 60 -H 'Content-Type: application/json' "$@"; }
: > "$OUT/client.txt"
for i in $(seq 1 "$N"); do
  th="_smoke-lat-$(date +%s)-$i"
  t0=$(python3 -c 'import time;print(time.time())')
  e=$(api -X POST "$BASE/api/execute" -d "$(jq -n --arg th "$th" '{path:"muno/playbooks/itinerary-planner",payload:{thread_id:$th,event_type:"user_message",event_payload:{text:"Plan a trip to Miami next month for 2 adults"},ai_provider:"openai"}}')" | jq -r '.execution_id // empty')
  [ -n "$e" ] || { echo "refused"; exit 1; }
  while :; do st=$(api "$BASE/api/executions/$e/status" | jq -r '.status // empty' | tr a-z A-Z); case $st in COMPLETED|FAILED|CANCELLED) break;; esac; sleep 0.2; done
  t1=$(python3 -c 'import time;print(time.time())')
  for _ in $(seq 1 50); do api "$BASE/api/executions/$e" > "$OUT/$e.json"; jq -e '[.events[]?|select(.event_type=="playbook.completed" or .event_type=="playbook.failed")]|length>0' "$OUT/$e.json" >/dev/null && break; sleep 0.2; done
  echo "$e $st $th $(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.3f",b-a}')" | tee -a "$OUT/client.txt"
done
jq -n --arg n "$N" '{playbook:"muno/playbooks/itinerary-planner",n:($n|tonumber),concurrency:1,label:"real turn"}' > "$OUT/run.json"
python3 "$(dirname "$0")/report.py" "$OUT" | sed -n '1,25p'
