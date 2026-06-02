#!/usr/bin/env bash
# Kind validation harness for /api/internal/* endpoints (Phase 1.a of #46 / Phase C of #49).
# Runs all 5 endpoints against a live server, exits non-zero on first failure.

set -euo pipefail

TOKEN="$(cat /tmp/internal_api_token.txt)"
BASE_URL="${1:-http://localhost:8082}"
SERVER_LABEL="${2:-Python}"

pass() { printf '\033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '\033[31mFAIL\033[0m  %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3"; exit 1; }

echo "================================================"
echo " /api/internal/* validation — $SERVER_LABEL @ $BASE_URL"
echo "================================================"

# ---------------------------------------------------------------------------
# Auth tests
# ---------------------------------------------------------------------------

echo ""
echo "--- AUTH GATE ---"

# Use GET on the pending-count endpoint — FastAPI rejects method mismatches
# (405) BEFORE running deps, so the auth gate only fires on GET here.
CODE="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/internal/outbox/pending-count")"
[ "$CODE" = "403" ] && pass "no Authorization → 403" || fail "no Authorization" 403 "$CODE"

CODE="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer WRONG" "$BASE_URL/api/internal/outbox/pending-count")"
[ "$CODE" = "403" ] && pass "wrong token → 403" || fail "wrong token" 403 "$CODE"

CODE="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Basic $TOKEN" "$BASE_URL/api/internal/outbox/pending-count")"
[ "$CODE" = "403" ] && pass "Basic scheme → 403" || fail "Basic scheme" 403 "$CODE"

# ---------------------------------------------------------------------------
# pending-count
# ---------------------------------------------------------------------------

echo ""
echo "--- pending-count ---"

RESP="$(curl -sS -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/internal/outbox/pending-count")"
PENDING="$(echo "$RESP" | jq -r .pending)"
if [[ "$PENDING" =~ ^[0-9]+$ ]]; then
  pass "pending-count returned $PENDING"
else
  fail "pending-count shape" "{pending: N}" "$RESP"
fi
INITIAL_PENDING=$PENDING

# ---------------------------------------------------------------------------
# claim → mark-published cycle
# ---------------------------------------------------------------------------

echo ""
echo "--- claim → mark-published ---"

CLAIM="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"limit": 2}' "$BASE_URL/api/internal/outbox/claim")"
CLAIMED="$(echo "$CLAIM" | jq -r .claimed)"
ROWS="$(echo "$CLAIM" | jq -r '.rows | length')"
if [ "$CLAIMED" = "$ROWS" ] && [ "$ROWS" -gt 0 ]; then
  pass "claim(limit=2) → claimed=$CLAIMED rows=$ROWS"
else
  fail "claim shape" "claimed > 0 with matching rows" "$CLAIM"
fi

# Capture the outbox_ids for mark-published
IDS="$(echo "$CLAIM" | jq -c '[.rows[].outbox_id]')"
echo "      claimed ids: $IDS"

PUBLISH="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"outbox_ids\": $IDS}" "$BASE_URL/api/internal/outbox/mark-published")"
MARKED="$(echo "$PUBLISH" | jq -r .marked)"
if [ "$MARKED" = "$CLAIMED" ]; then
  pass "mark-published $MARKED rows"
else
  fail "mark-published count" "$CLAIMED" "$MARKED"
fi

# ---------------------------------------------------------------------------
# claim → mark-failed cycle
# ---------------------------------------------------------------------------

echo ""
echo "--- claim → mark-failed (with backoff) ---"

CLAIM2="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"limit": 1}' "$BASE_URL/api/internal/outbox/claim")"
CLAIMED2="$(echo "$CLAIM2" | jq -r .claimed)"

if [ "$CLAIMED2" -gt 0 ]; then
  FAIL_ID="$(echo "$CLAIM2" | jq -r '.rows[0].outbox_id')"
  ATTEMPTS="$(echo "$CLAIM2" | jq -r '.rows[0].attempts')"

  FAIL_RESP="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"outbox_id\": $FAIL_ID, \"error\": \"validation test failure\", \"attempts\": $ATTEMPTS}" \
    "$BASE_URL/api/internal/outbox/mark-failed")"
  MARKED_FAIL="$(echo "$FAIL_RESP" | jq -r .marked)"
  AVAIL_IN="$(echo "$FAIL_RESP" | jq -r .available_at_in)"
  if [ "$MARKED_FAIL" = "true" ] && [ "$AVAIL_IN" -ge 1 ]; then
    pass "mark-failed outbox_id=$FAIL_ID attempts=$ATTEMPTS → backoff=${AVAIL_IN}s"
  else
    fail "mark-failed shape" "{marked: true, available_at_in: N}" "$FAIL_RESP"
  fi
else
  echo "(skipping mark-failed test: no more PENDING rows)"
fi

# ---------------------------------------------------------------------------
# events/project
# ---------------------------------------------------------------------------

echo ""
echo "--- events/project ---"

TS=$(date +%s)
EID="9999${TS}"

# Real events from the worker carry a catalog_id of the playbook
# they're executing.  Use an existing catalog row for the test so the
# FK constraint passes.
CATALOG_ID="${VALIDATE_CATALOG_ID:-609143516974809090}"

PROJECT_RESP="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"events\": [
    {\"event_id\": ${EID}1, \"execution_id\": ${EID}, \"catalog_id\": $CATALOG_ID, \"event_type\": \"validation.test\", \"status\": \"COMPLETED\"},
    {\"event_id\": ${EID}2, \"execution_id\": ${EID}, \"catalog_id\": $CATALOG_ID, \"event_type\": \"validation.test\", \"status\": \"COMPLETED\"}
  ]}" \
  "$BASE_URL/api/internal/events/project")"
PROJECTED="$(echo "$PROJECT_RESP" | jq -r .projected)"
DUPES="$(echo "$PROJECT_RESP" | jq -r .duplicates)"

if [ "$PROJECTED" = "2" ] && [ "$DUPES" = "0" ]; then
  pass "events/project 2 fresh events → projected=2 duplicates=0"
else
  fail "events/project first attempt" "projected=2 duplicates=0" "$PROJECT_RESP"
fi

# Idempotency: re-project same events
PROJECT2="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"events\": [
    {\"event_id\": ${EID}1, \"execution_id\": ${EID}, \"catalog_id\": $CATALOG_ID, \"event_type\": \"validation.test\", \"status\": \"COMPLETED\"}
  ]}" \
  "$BASE_URL/api/internal/events/project")"
PROJECTED2="$(echo "$PROJECT2" | jq -r .projected)"
DUPES2="$(echo "$PROJECT2" | jq -r .duplicates)"

if [ "$PROJECTED2" = "0" ] && [ "$DUPES2" = "1" ]; then
  pass "events/project idempotency → projected=0 duplicates=1"
else
  fail "events/project idempotency" "projected=0 duplicates=1" "$PROJECT2"
fi

# ---------------------------------------------------------------------------

echo ""
echo "================================================"
printf '\033[32mALL TESTS PASS\033[0m — %s server endpoints validated\n' "$SERVER_LABEL"
echo "================================================"
