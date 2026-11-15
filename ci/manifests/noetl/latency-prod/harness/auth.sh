#!/usr/bin/env bash
# Prod auth arm: (1) the gateway's real path (NOETL_AUTH_SYNC): POST /api/auth/session/validate
# and /api/auth/check-playbook-access with a non-existent session (read-only lookups, denied);
# (2) the playbook FALLBACK api_integration/auth0/check_playbook_access with that session and
# request_id "" (no callback) — the path a dispatch change can break. Budget 15 s.
set -euo pipefail
N=${1:?N}; OUT=${2:?OUT}; BASE=${LAT_BASE:-http://127.0.0.1:38190}; mkdir -p "$OUT"
api() { curl -sS -m 60 -H 'Content-Type: application/json' "$@"; }
TOK=latbench-nonexistent-session-$(date +%s)
: > "$OUT/sync.txt"
for i in $(seq 1 "$N"); do
  for ep in session/validate check-playbook-access; do
    t=$(curl -sS -m 20 -o /dev/null -w '%{http_code} %{time_total}' -H 'Content-Type: application/json' -X POST "$BASE/api/auth/$ep" \
        -d "$(jq -n --arg t "$TOK" '{session_token:$t, playbook_path:"bench/seq10_noop", action:"execute"}')")
    echo "$ep $t" >> "$OUT/sync.txt"
  done
done
payload=$(jq -n --arg t "$TOK" '{session_token:$t, playbook_path:"bench/seq10_noop", action:"execute", request_id:""}')
run_one() {
  local e st t0 t1
  t0=$(python3 -c 'import time;print(time.time())')
  e=$(api -X POST "$BASE/api/execute" -d "$(jq -n --argjson p "$payload" '{path:"api_integration/auth0/check_playbook_access",payload:$p}')" | jq -r '.execution_id // empty')
  [ -n "$e" ] || { echo "execute refused"; return 1; }
  while :; do
    st=$(api "$BASE/api/executions/$e/status" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]')
    case "$st" in COMPLETED|FAILED|CANCELLED) break;; esac
    t1=$(python3 -c 'import time;print(time.time())')
    awk -v a="$t0" -v b="$t1" 'BEGIN{exit !(b-a > 60)}' && { st=TIMEOUT; break; }
    sleep 0.1
  done
  t1=$(python3 -c 'import time;print(time.time())')
  echo "$e $st $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
}
run_one >/dev/null || true
: > "$OUT/auth-client.txt"
for _ in $(seq 1 "$N"); do run_one | tee -a "$OUT/auth-client.txt"; done
python3 - "$OUT" <<'PY'
import sys,statistics
d=sys.argv[1]
def p(xs,q):
    xs=sorted(xs); k=(len(xs)-1)*q; f=int(k); c=min(f+1,len(xs)-1); return xs[f]+(xs[c]-xs[f])*(k-f)
rows=[l.split() for l in open(d+"/sync.txt") if l.strip()]
for ep in ("session/validate","check-playbook-access"):
    xs=[float(r[2]) for r in rows if r[0]==ep]; codes=sorted(set(r[1] for r in rows if r[0]==ep))
    print(f"== auth sync {ep}: n={len(xs)} codes={codes} p50 {p(xs,.5)*1000:.0f}ms p95 {p(xs,.95)*1000:.0f}ms max {max(xs)*1000:.0f}ms")
rows=[l.split() for l in open(d+"/auth-client.txt") if l.strip()]
xs=[float(r[2]) for r in rows]; sts=sorted(set(r[1] for r in rows))
print(f"== auth playbook fallback: n={len(xs)} status={sts} p50 {p(xs,.5):.3f}s p95 {p(xs,.95):.3f}s max {max(xs):.3f}s budget 15s -> {'PASS' if max(xs)<15 and sts==['COMPLETED'] else 'CHECK'}")
PY
