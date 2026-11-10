#!/usr/bin/env bash
# Kind e2e for the item 9 slices (ai-meta docs/rfc/interop-missing-tools-build-plan.md):
# durable inbox (noetl/server#567), enrollment tokens (#568), push delivery (#569), driven by
# the real `noetl instance` CLI (noetl/cli#106) against a server image built from the top of
# that stack, with the kind Postgres as the store. Local kind only.
#
#   0  gates             kind API, server image in the node, CLI with `instance enroll`
#   1  arm               NOETL_INSTANCE_REGISTRY, _STORE=postgres, _TRUST=enroll (allowlist empty),
#                        _PUSH=true + an in-cluster push receiver as the only allowed origin
#   2  enrollment        an unenrolled instance is refused; mint (operator route) → enroll A, B;
#                        a spent token does not enroll a third key; the rows are in Postgres
#   3  push              B registers reach:push at the receiver: the push arrives with B's bearer;
#                        a refused push (503) goes back to the inbox, B pulls and runs it
#   4  durable inbox     a task queued for an offline B survives a server restart; the enrolled
#                        ids survive it too (A and B register without enrolling again); B runs
#                        the task after the restart; Postgres holds it completed
#   5  restore           server deployment as found; receiver removed; rows of this run deleted
#
#   SERVER_IMAGE=localhost/noetl-server-rust:item9-stack NOETL_CLI_BIN=/path/to/noetl \
#     ci/kind/e2e_instance_slices.sh
set -euo pipefail
SERVER_IMAGE=${SERVER_IMAGE:?set SERVER_IMAGE to a server built from noetl/server#569 or later}
CLI=${NOETL_CLI_BIN:?set NOETL_CLI_BIN to a noetl CLI from noetl/cli#106 or later}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
case "$CTX" in kind-*) ;; *) echo "refusing: not a kind context"; exit 2 ;; esac
K="kubectl --context $CTX -n $NS"
PSQL="kubectl --context $CTX -n postgres exec deploy/postgres -- psql -U noetl -d noetl -tAc"
PORT=${PORT:-38085}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/instance-slices.XXXXXX")}; mkdir -p "$W"
RX=interop-push.$NS.svc.cluster.local:8080
ARMED=0; PF=; SERVE=
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

restore() {
  [ -n "$SERVE" ] && kill "$SERVE" 2>/dev/null || true
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring noetl-server-rust from $W/snap.json"
    $K replace -f "$W/snap.json" >/dev/null && echo "  restored" || echo "  !! restore failed ($W/snap.json)"
    $K rollout status deploy/noetl-server-rust --timeout=300s >/dev/null || true
    $K delete pod,svc interop-push --ignore-not-found >/dev/null || true
    for id in ${A:-} ${B:-} ${C:-}; do
      $PSQL "DELETE FROM noetl.instance_enrolled WHERE instance_id='$id'; DELETE FROM noetl.instance_tasks WHERE target='$id' OR record->>'from'='$id';" >/dev/null 2>&1 || true
    done
  fi
}
trap restore EXIT

forward() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  $K port-forward svc/noetl-server-rust "$PORT:8082" >/dev/null 2>&1 & PF=$!
  local i=0; until curl -fsS -m 2 "$S/api/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 60 ] || return 1; sleep 1; done
}
S=http://127.0.0.1:$PORT

step "0. gates"
kubectl --context $CTX get --raw /readyz >/dev/null && ok "kind API ready" || { echo "kind not ready"; exit 4; }
podman exec "$NODE" crictl inspecti "$SERVER_IMAGE" >/dev/null 2>&1 && ok "image in node: $SERVER_IMAGE" || { echo "REFUSED: $SERVER_IMAGE not loaded"; exit 5; }
"$CLI" instance enroll --help >/dev/null 2>&1 && ok "cli has \`instance enroll\`" || { echo "REFUSED: CLI too old"; exit 5; }

step "1. arm"
$K get deploy noetl-server-rust -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap.json"
for f in NOETL_INSTANCE_REGISTRY NOETL_INSTANCE_STORE NOETL_INSTANCE_TRUST NOETL_INSTANCE_PUSH; do
  jq -e --arg f "$f" '[.spec.template.spec.containers[0].env[]?|select(.name==$f)]|length==0' "$W/snap.json" >/dev/null \
    && ok "as found: $f unset" || bad "as found: $f already set"
done
ARMED=1
$K delete pod,svc interop-push --ignore-not-found >/dev/null 2>&1 || true
# Push receiver: 200 for the first push, 503 after; records auth + body.
$K run interop-push --image=docker.io/library/python:3.12-alpine --image-pull-policy=IfNotPresent --port=8080 \
  --command -- python3 -u -c '
import http.server, json
n = {"c": 0}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0)).decode()
        n["c"] += 1
        with open("/tmp/hits.jsonl", "a") as f:
            f.write(json.dumps({"n": n["c"], "auth": self.headers.get("authorization"), "body": body}) + "\n")
        self.send_response(200 if n["c"] == 1 else 503); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
' >/dev/null
$K expose pod interop-push --port=8080 >/dev/null
$K wait --for=condition=Ready pod/interop-push --timeout=120s >/dev/null && ok "push receiver up ($RX)" || bad "push receiver not ready"
jq --arg img "$SERVER_IMAGE" --arg rx "http://$RX" '
  .spec.template.spec.containers[0].image = $img
  | .spec.template.spec.containers[0].env += [
      {"name":"NOETL_INSTANCE_REGISTRY","value":"true"},
      {"name":"NOETL_INSTANCE_STORE","value":"postgres"},
      {"name":"NOETL_INSTANCE_TRUST","value":"enroll"},
      {"name":"NOETL_INSTANCE_PUSH","value":"true"},
      {"name":"NOETL_INSTANCE_PUSH_ORIGINS","value":$rx},
      {"name":"NOETL_RUNTIME_TTL_SECS","value":"60"}]
' "$W/snap.json" | $K replace -f - >/dev/null
$K rollout status deploy/noetl-server-rust --timeout=600s >/dev/null && ok "server on $SERVER_IMAGE" || { bad "rollout"; exit 1; }
forward || { bad "server not reachable"; exit 1; }
IT=$($K get secret -o json | jq -r '[.items[]|select(.data["NOETL_INTERNAL_API_TOKEN"]!=null)][0].data["NOETL_INTERNAL_API_TOKEN"] // empty' | base64 -d 2>/dev/null || true)
admin() { curl -sS -m 20 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }
for t in instance_tasks instance_enroll_tokens instance_enrolled; do
  [ "$($PSQL "SELECT to_regclass('noetl.$t') IS NOT NULL" | tr -d '[:space:]')" = t ] && ok "noetl.$t created at start-up" || bad "noetl.$t missing"
done

mkdir -p "$W/books/edge"
printf '%s\n' 'apiVersion: noetl.io/v2' 'kind: Playbook' 'metadata: { name: hello }' 'workload: { who: nobody }' 'workflow:' \
  '  - step: start' '    next: [ { step: greet } ]' '  - step: greet' "    tool: { kind: shell, cmds: [ 'echo \"hello {{ workload.who }}\"' ] }" > "$W/books/edge/hello.yaml"
A=$("$CLI" instance init --key "$W/a/key.json" 2>/dev/null); B=$("$CLI" instance init --key "$W/b/key.json" 2>/dev/null); C=$("$CLI" instance init --key "$W/c/key.json" 2>/dev/null)
reg_a() { "$CLI" instance register --once --server "$S" --key "$W/a/key.json" --runtime-kind cli --site kind-slices "$@"; }
reg_b() { "$CLI" instance register --once --server "$S" --key "$W/b/key.json" --runtime-kind daemon --site kind-slices --offer 'edge/*' --accept-tasks "$@"; }

step "2. enrollment tokens"
reg_a >/dev/null 2>"$W/e0" && bad "an unenrolled instance registered" || { grep -q 403 "$W/e0" && ok "unenrolled A → 403" || bad "A: $(head -c 200 "$W/e0")"; }
admin -X POST "$S/api/runtime/instances/enrollments" -d '{"label":"kind-slices","uses":2,"ttl_secs":600}' > "$W/mint.json"
jq -e '.token|startswith("nie-")' "$W/mint.json" >/dev/null && ok "operator minted a 2-use token" || bad "mint: $(head -c 300 "$W/mint.json")"
jq -r .token "$W/mint.json" > "$W/token"; chmod 600 "$W/token"
for who in a b; do
  "$CLI" instance enroll --server "$S" --key "$W/$who/key.json" --token-file "$W/token" > "$W/enroll-$who.json" 2>&1 \
    && ok "$who enrolled ($(jq -r .instance_id "$W/enroll-$who.json"))" || bad "enroll $who: $(head -c 300 "$W/enroll-$who.json")"
done
"$CLI" instance enroll --server "$S" --key "$W/c/key.json" --token-file "$W/token" > "$W/enroll-c.json" 2>&1 \
  && bad "a spent token enrolled a third key" || ok "spent token → refused for C"
[ "$($PSQL "SELECT count(*) FROM noetl.instance_enrolled WHERE instance_id IN ('$A','$B')" | tr -d '[:space:]')" = 2 ] && ok "A and B are in noetl.instance_enrolled" || bad "enrolled rows missing"
[ "$($PSQL "SELECT count(*) FROM noetl.instance_enroll_tokens WHERE label='kind-slices'" | tr -d '[:space:]')" = 0 ] && ok "the spent token is gone from Postgres" || bad "spent token row still there"
reg_a > "$W/reg-a.json" 2>&1 && ok "A registers after enrolling" || bad "register A: $(head -c 300 "$W/reg-a.json")"

step "3. push delivery"
reg_b --reach push --endpoint "http://$RX/push" > "$W/reg-b.json" 2>&1 || bad "register B: $(head -c 300 "$W/reg-b.json")"
PT=$(jq -r '.push_token // empty' "$W/reg-b.json")
[ -n "$PT" ] && ok "B (reach: push) got a push token" || bad "no push token: $(head -c 300 "$W/reg-b.json")"
"$CLI" instance discover --server "$S" --key "$W/a/key.json" --runs edge/hello > "$W/disc.json" 2>&1 || true
grep -q "$PT" "$W/disc.json" && bad "discovery shows the push token" || ok "discovery does not show the push token"
handoff() { "$CLI" instance handoff --server "$S" --key "$W/a/key.json" --to "$B" --playbook edge/hello --payload "{\"who\":\"$1\"}" "${@:2}"; }
handoff push1 > "$W/h1.json" 2>&1 || bad "handoff 1: $(head -c 300 "$W/h1.json")"
T1=$(jq -r .task_id "$W/h1.json")
hits() { $K exec interop-push -- cat /tmp/hits.jsonl 2>/dev/null || true; }
i=0; until hits | grep -q "$T1"; do i=$((i+1)); [ $i -lt 30 ] || break; sleep 1; done
h=$(hits | grep "$T1" | head -1)
[ "$(echo "$h" | jq -r .auth)" = "Bearer $PT" ] && ok "push 1 delivered to the receiver with B's bearer" || bad "push 1: $(echo "$h" | head -c 300)"
echo "$h" | jq -r .body | jq -e --arg t "$T1" '.tasks[0].task_id==$t and .tasks[0].payload.who=="push1" and (.tasks[0].claim_id|startswith("claim-"))' >/dev/null \
  && ok "push body is the claim (task, payload, claim id)" || bad "push body: $(echo "$h" | jq -r .body | head -c 300)"
# Push 2: the receiver answers 503, so the task must come back to the inbox. B is registered
# for push but NOT polling yet, so the push is the only thing that can claim it first.
handoff push2 > "$W/h2.json" 2>&1 || bad "handoff 2: $(head -c 300 "$W/h2.json")"
T2=$(jq -r .task_id "$W/h2.json")
i=0; until hits | grep "$T2" | grep -q '"n": 2'; do i=$((i+1)); [ $i -lt 30 ] || break; sleep 1; done
[ $i -lt 30 ] && ok "push 2 reached the receiver (which refused it with 503)" || bad "no second push seen for $T2"
st=$($PSQL "SELECT state FROM noetl.instance_tasks WHERE task_id='$T2'" | tr -d '[:space:]')
[ "$st" = queued ] && ok "after the refused push the task is queued again (released at once)" || bad "task $T2 is $st after the refused push"
"$CLI" instance serve --server "$S" --key "$W/b/key.json" --runtime-kind daemon --site kind-slices --offer 'edge/*' \
  --playbook-dir "$W/books" --max-tasks 1 >"$W/serve1.out" 2>"$W/serve1.err" & SERVE=$!
i=0; until [ "$($PSQL "SELECT state FROM noetl.instance_tasks WHERE task_id='$T2'" | tr -d '[:space:]')" = completed ]; do i=$((i+1)); [ $i -lt 45 ] || break; sleep 2; done
[ $i -lt 45 ] && $PSQL "SELECT record->>'result' FROM noetl.instance_tasks WHERE task_id='$T2'" | grep -q "hello push2" \
  && ok "B pulled the released task and ran it ('hello push2')" || bad "task $T2 not completed by pull: $(tail -3 "$W/serve1.err")"
wait "$SERVE" 2>/dev/null || true; SERVE=

step "4. durable inbox across a server restart"
reg_b > /dev/null 2>&1   # pull-only again; then go quiet
handoff durable > "$W/h3.json" 2>&1 || bad "handoff 3: $(head -c 300 "$W/h3.json")"
T3=$(jq -r .task_id "$W/h3.json")
[ "$($PSQL "SELECT state FROM noetl.instance_tasks WHERE task_id='$T3'" | tr -d '[:space:]')" = queued ] && ok "task $T3 queued in Postgres" || bad "row for $T3 not queued"
$K rollout restart deploy/noetl-server-rust >/dev/null && $K rollout status deploy/noetl-server-rust --timeout=600s >/dev/null && ok "server restarted (new pod, empty memory)" || bad "restart"
forward || bad "server not reachable after restart"
reg_a > /dev/null 2>"$W/ra" && ok "A registers after the restart without enrolling again" || bad "A after restart: $(head -c 200 "$W/ra")"
"$CLI" instance serve --server "$S" --key "$W/b/key.json" --runtime-kind daemon --site kind-slices --offer 'edge/*' \
  --playbook-dir "$W/books" --max-tasks 1 >"$W/serve2.out" 2>"$W/serve2.err" & SERVE=$!
i=0; until [ "$($PSQL "SELECT state FROM noetl.instance_tasks WHERE task_id='$T3'" | tr -d '[:space:]')" = completed ]; do i=$((i+1)); [ $i -lt 60 ] || break; sleep 2; done
[ $i -lt 60 ] && ok "B (re-registered, still enrolled) pulled the pre-restart task and completed it" || bad "task $T3 not completed: $(tail -3 "$W/serve2.err")"
$PSQL "SELECT record->>'result' FROM noetl.instance_tasks WHERE task_id='$T3'" | grep -q "hello durable" \
  && ok "Postgres holds the result ('hello durable')" || bad "result not in Postgres"
wait "$SERVE" 2>/dev/null || true; SERVE=

step "summary"
echo "  passed: $pass   failed: ${#fails[@]}   (work dir: $W)"
[ ${#fails[@]} -eq 0 ] || { printf '  - %s\n' "${fails[@]}"; exit 1; }
