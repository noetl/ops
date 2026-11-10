#!/usr/bin/env bash
# Prod smoke via the port-forwarded server (S, default 127.0.0.1:18082).
#   ranch:  shastaranch/concierge/turn (live path), rooms question; must complete with a room_cards widget
#           (shastaranch/tests/concierge_smoke is not registered in prod)
#   travel: muno/playbooks/itinerary-planner, thread _smoke-<ts>, openai
# Prints one line per check and exits non-zero if any check fails.
set -uo pipefail
S=${S:-http://127.0.0.1:18082}
LABEL=${1:-smoke}
OUT=${OUT:-${TMPDIR:-/tmp}/noetl-smoke-$LABEL}
mkdir -p "$OUT"
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }

h=$(curl -sS -m 10 "$S/api/health"); echo "$h" > "$OUT/health.json"
echo "$h" | jq -e '.status=="ok" and .database=="connected"' >/dev/null && say ok "health: $(echo "$h" | jq -c '{status,database,version}')" || { say FAIL "health: $h"; fail=1; }

run() {  # run <name> <path> <payload-json>
  local name=$1 path=$2 payload=$3 eid st i=0 t0=$(date +%s)
  eid=$(curl -sS -m 30 -X POST "$S/api/execute" -H 'content-type: application/json' \
        -d "$(jq -n --arg p "$path" --argjson w "$payload" '{path:$p,payload:$w}')" | tee "$OUT/$name-start.json" | jq -r '.execution_id // .id // empty')
  [ -n "$eid" ] || { say FAIL "$name: did not start: $(head -c 300 "$OUT/$name-start.json")"; fail=1; return; }
  while :; do
    st=$(curl -sS -m 10 "$S/api/executions/$eid/status" | jq -r '.status // .state // empty' | tr '[:lower:]' '[:upper:]')
    case "$st" in COMPLETED|FAILED|CANCELLED|ERROR) break ;; esac
    i=$((i+1)); [ $i -lt 90 ] || { st=TIMEOUT; break; }; sleep 2
  done
  curl -sS -m 20 "$S/api/executions/$eid" > "$OUT/$name-exec.json" 2>/dev/null || true
  local dt=$(( $(date +%s) - t0 ))
  [ "$st" = COMPLETED ] && say ok "$name: $path $eid COMPLETED in ${dt}s" || { say FAIL "$name: $path $eid ended $st after ${dt}s"; fail=1; }
}

run ranch shastaranch/concierge/turn \
  "$(jq -n --arg d "$(date -u +%F)" '{message:"What rooms do you have for two people?",client_today:$d,thread_id:"smoke-rooms"}')"
w=$(grep -o -E '"(room_cards|bot_text)"' "$OUT/ranch-exec.json" 2>/dev/null | sort -u | tr -d '"' | tr '\n' ' ')
[ -n "$w" ] && say ok "ranch: reply widgets: $w" || { say FAIL "ranch: no reply widget (room_cards or bot_text)"; fail=1; }
run travel muno/playbooks/itinerary-planner \
  "$(jq -n --arg t "_smoke-$(date +%s)" '{thread_id:$t,event_type:"user_message",event_payload:{text:"Plan a trip to Miami next month for 2 adults"},ai_provider:"openai"}')"
exit $fail
