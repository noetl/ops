#!/usr/bin/env bash
# Auth arm of the latency bench (noetl/ai-meta#557): the REAL authorization
# playbook, driven end to end on the lat stack, against its 15 s gateway budget.
#
# Why this arm exists: the 2026-06-29 login outage (#156) came from a
# dispatch-path change that was validated only against the planner. Every stage
# that touches dispatch must show the auth path still clears 15 s.
#
# Prod runs login / validate / authz on the server's sync fast-paths
# (gateway NOETL_AUTH_SYNC=true, NOETL_AUTHZ_SYNC=true), which never dispatch a
# playbook. The playbook path is the FALLBACK when those flags are off, and it is
# the one a dispatch change can break, so it is what this arm drives:
# api_integration/auth0/check_playbook_access (vendored from noetl/e2e), 8 steps:
# python → postgres → python → postgres → python → http callback → end.
#
#   auth.sh N OUT_DIR
#
# Setup (idempotent): auth schema in the lat database (provision_auth_schema.sql,
# extracted verbatim from the e2e fixture), one user + admin role + wildcard
# execute grant + a live session; credential `pg_auth` on the lat server; a
# callback sink pod standing in for the gateway's /api/internal/callback.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
N=${1:?usage: auth.sh N OUT_DIR}; OUT=${2:?usage: auth.sh N OUT_DIR}
CTX=${KIND_CONTEXT:-kind-noetl}; NS=noetl
K="kubectl --context $CTX -n $NS"
DB=${LAT_DB:-noetl_lat}
PSQL="kubectl --context $CTX -n postgres exec -i deploy/postgres -- psql -v ON_ERROR_STOP=1 -U noetl -d $DB"
PORT=${LAT_PORT:-38090}; BASE=${LAT_BASE:-http://127.0.0.1:$PORT}
BUDGET_S=${AUTH_BUDGET_S:-15}
TOKEN=lat-bench-session-0001
SINK=http://lat-callback-sink.noetl.svc.cluster.local:8080
PF=""; trap '[ -n "$PF" ] && kill "$PF" 2>/dev/null || true' EXIT
api() { curl -sS -m 60 -H 'Content-Type: application/json' "$@"; }
if ! curl -fsS -m 2 "$BASE/api/health" >/dev/null 2>&1; then
  $K port-forward svc/noetl-server-lat "$PORT:8082" >/dev/null 2>&1 & PF=$!
  for _ in $(seq 1 60); do curl -fsS -m 2 "$BASE/api/health" >/dev/null 2>&1 && break; sleep 1; done
fi
mkdir -p "$OUT"

# 1. schema + seed
$PSQL -q -f - < "$HERE/auth/provision_auth_schema.sql" >/dev/null
$PSQL -q <<SQL >/dev/null
INSERT INTO auth.users (auth0_id, email, display_name) VALUES ('lat|bench', 'bench@lat.invalid', 'lat bench')
  ON CONFLICT (auth0_id) DO NOTHING;
INSERT INTO auth.user_roles (user_id, role_id)
  SELECT u.user_id, r.role_id FROM auth.users u, auth.roles r WHERE u.auth0_id = 'lat|bench' AND r.role_name = 'admin'
  ON CONFLICT DO NOTHING;
INSERT INTO auth.playbook_permissions (role_id, allow_pattern, can_execute, can_view)
  SELECT r.role_id, 'bench/%', true, true FROM auth.roles r WHERE r.role_name = 'admin'
    AND NOT EXISTS (SELECT 1 FROM auth.playbook_permissions WHERE allow_pattern = 'bench/%');
INSERT INTO auth.sessions (user_id, session_token, expires_at)
  SELECT user_id, '$TOKEN', now() + interval '30 days' FROM auth.users WHERE auth0_id = 'lat|bench'
  ON CONFLICT (session_token) DO UPDATE SET expires_at = EXCLUDED.expires_at, is_active = true;
SQL

# 2. credential (the kind postgres password, read from the lat server's own spec; never printed)
PW=$($K get deploy noetl-server-lat -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="POSTGRES_PASSWORD") | .value // empty')
[ -n "$PW" ] || { echo "POSTGRES_PASSWORD not found as a literal on the lat server (kind manifests set one)"; exit 1; }
api -X POST "$BASE/api/credentials" -d "$(jq -n --arg pw "$PW" --arg db "$DB" \
  '{name:"pg_auth",type:"postgres",data:{host:"postgres.postgres.svc.cluster.local",port:5432,user:"noetl",password:$pw,database:$db},description:"lat bench: auth arm"}')" >/dev/null
unset PW

# 3. callback sink (answers 200 to any POST, like the gateway's /api/internal/callback)
WIMG=$($K get deploy noetl-worker-lat -o jsonpath='{.spec.template.spec.containers[0].image}')
$K apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: { name: lat-callback-sink }
spec:
  replicas: 1
  selector: { matchLabels: { app: lat-callback-sink } }
  template:
    metadata: { labels: { app: lat-callback-sink } }
    spec:
      containers:
        - name: sink
          image: $WIMG
          command: ["python3", "-c"]
          args:
            - |
              from http.server import BaseHTTPRequestHandler, HTTPServer
              class H(BaseHTTPRequestHandler):
                  def do_POST(self):
                      self.rfile.read(int(self.headers.get("Content-Length") or 0))
                      self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
                      self.wfile.write(b'{"status":"ok"}')
                  def log_message(self, *a): pass
              HTTPServer(("0.0.0.0", 8080), H).serve_forever()
          resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { memory: 64Mi } }
---
apiVersion: v1
kind: Service
metadata: { name: lat-callback-sink }
spec: { selector: { app: lat-callback-sink }, ports: [ { port: 8080, targetPort: 8080 } ] }
YAML
$K rollout status deploy/lat-callback-sink --timeout=180s >/dev/null

# 4. register + run
api -X POST "$BASE/api/catalog/register" -d "$(jq -n --rawfile c "$HERE/auth/check_playbook_access.yaml" '{content:$c,resource_type:"Playbook"}')" >/dev/null
payload=$(jq -n --arg t "$TOKEN" --arg g "$SINK" '{session_token:$t, playbook_path:"bench/seq10_noop", action:"execute", gateway_url:$g, request_id:"lat-bench"}')
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
run_one >/dev/null || true   # warm-up
: > "$OUT/auth-client.txt"
for _ in $(seq 1 "$N"); do run_one | tee -a "$OUT/auth-client.txt"; done
for e in $(awk '{print $1}' "$OUT/auth-client.txt"); do
  for _ in $(seq 1 50); do
    api "$BASE/api/executions/$e" > "$OUT/$e.json"
    jq -e '[.events[]? | select(.event_type == "playbook.completed" or .event_type == "playbook.failed")] | length > 0' "$OUT/$e.json" >/dev/null && break
    sleep 0.2
  done
done
granted=$(for e in $(awk '{print $1}' "$OUT/auth-client.txt"); do jq -r '[.events[] | select(.event_type=="command.completed") | .node_name] | index("access_granted") != null' "$OUT/$e.json"; done | grep -c true || true)
jq -n --arg n "$N" '{playbook:"api_integration/auth0/check_playbook_access", n:($n|tonumber), concurrency:1, label:"auth arm"}' > "$OUT/run.json"
python3 - "$OUT/auth-client.txt" "$BUDGET_S" "$granted" "$N" <<'PY'
import sys, statistics
rows=[l.split() for l in open(sys.argv[1]) if l.strip()]
budget=float(sys.argv[2]); granted=int(sys.argv[3]); n=int(sys.argv[4])
xs=sorted(float(r[2]) for r in rows)
ok=[r for r in rows if r[1]=="COMPLETED"]
def p(q):
    k=(len(xs)-1)*q; f=int(k); c=min(f+1,len(xs)-1); return xs[f]+(xs[c]-xs[f])*(k-f)
print(f"== auth arm (client-observed, execute -> terminal status): n={len(xs)} completed={len(ok)} granted={granted}/{n}")
print(f"   p50 {p(.5):.3f}s  p95 {p(.95):.3f}s  max {xs[-1]:.3f}s  budget {budget:.0f}s  -> {'PASS' if xs[-1] < budget and len(ok)==n and granted==n else 'FAIL'}")
PY
python3 "$HERE/report.py" "$OUT" | sed -n '1,20p'
