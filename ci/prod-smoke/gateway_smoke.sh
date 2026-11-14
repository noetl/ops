#!/usr/bin/env bash
# Gateway-path smoke on the public prod gateway, the way mountshastaranch.com's chat runs:
# guest session → GraphQL executePlaybook(shastaranch/concierge/turn) → poll /noetl/executions/{id}.
# Also checks /health and that /noetl/mcp is not mounted (GATEWAY_MCP_PROXY off).
set -uo pipefail
G=${G:-https://gateway.mestumre.dev}
LABEL=${1:-gw}
OUT=${OUT:-${TMPDIR:-/tmp}/noetl-gwsmoke-$LABEL}; mkdir -p "$OUT"
fail=0; say() { printf '  %-5s %s\n' "$1" "$2"; }
code=$(curl -sS -o "$OUT/health" -w '%{http_code}' -m 10 "$G/health")
[ "$code" = 200 ] && say ok "gateway /health 200 $(head -c 120 "$OUT/health")" || { say FAIL "gateway /health $code"; fail=1; }
code=$(curl -sS -o /dev/null -w '%{http_code}' -m 10 -X POST "$G/noetl/mcp" -H 'content-type: application/json' -d '{}')
say info "POST /noetl/mcp → $code (expected 404 while GATEWAY_MCP_PROXY is off)"
TOK=$(curl -sS -m 15 -X POST "$G/api/auth/guest" -H 'Origin: https://mountshastaranch.com' | jq -r '.session_token // empty')
[ -n "$TOK" ] && say ok "guest session minted" || { say FAIL "guest session"; exit 1; }
Q='mutation ExecutePlaybook($name: String!, $vars: JSON, $clientId: String) { executePlaybook(name: $name, variables: $vars, clientId: $clientId) { executionId requestId status } }'
body=$(jq -n --arg q "$Q" --arg d "$(date -u +%F)" '{query:$q,variables:{name:"shastaranch/concierge/turn",vars:{message:"What rooms do you have for two people?",client_today:$d,thread_id:"smoke-gw-rooms"},clientId:null}}')
EID=$(curl -sS -m 30 -X POST "$G/graphql" -H 'content-type: application/json' -H 'Origin: https://mountshastaranch.com' -H "Authorization: Bearer $TOK" -d "$body" | tee "$OUT/exec.json" | jq -r '.data.executePlaybook.executionId // empty')
[ -n "$EID" ] || { say FAIL "executePlaybook: $(head -c 300 "$OUT/exec.json")"; exit 1; }
t0=$(date +%s); i=0
while :; do
  st=$(curl -sS -m 15 "$G/noetl/executions/$EID?page_size=300" -H 'Origin: https://mountshastaranch.com' -H "Authorization: Bearer $TOK" | tee "$OUT/status.json" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]')
  case "$st" in COMPLETED|FAILED|CANCELLED) break ;; esac
  i=$((i+1)); [ $i -lt 60 ] || { st=TIMEOUT; break; }; sleep 2
done
# The reply is an LLM's: it shows rooms as room_cards or describes them in bot_text. Either is
# a real answer; a COMPLETED turn with neither is a failure.
w=$(grep -o -E '"(room_cards|bot_text)"' "$OUT/status.json" | sort -u | tr -d '"' | tr '\n' ' ')
[ "$st" = COMPLETED ] && [ -n "$w" ] && say ok "guest concierge turn via gateway $EID COMPLETED in $(( $(date +%s)-t0 ))s (reply: $w)" \
  || { say FAIL "gateway turn $EID ended $st (reply widgets: ${w:-none})"; fail=1; }
exit $fail
