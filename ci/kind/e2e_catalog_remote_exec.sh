#!/usr/bin/env bash
# Kind e2e: cross-instance execution — "run it on B" + sub-playbook import
# (noetl/ai-meta#548 follow-up; server catalog_remote, tools `remote:`).
#
# Two FULL NoETL runtimes in one kind cluster. A is the existing stack. B is a
# clone with its own database (noetl_b), its own cmdbus writer, its own shared
# and system-pool workers, its own instance key and trust list. Nothing of B's
# reaches A's buses or A's database.
#
#   0  gates            load, kind API, images, CLI for keys
#   1  arm              keys; noetl_b; A (+ REMOTE_CALLS) and the whole B stack (+ REMOTE_SERVE)
#   2  B is a runtime   a playbook registered and executed on B completes on B's workers
#   3  publish on B     xc/leaf v1, xc/target v1 (target calls leaf by bare name); advert reaches A
#   4  delegate         A's root calls noetl://<B>/xc/target twice, remote: delegate; v2 of
#                       target AND leaf registered on B between the calls → both calls run
#                       target v1 + leaf v1 on B's workers (one shared pin on B); a fresh
#                       root then runs v2
#   5  import           same, remote: import → runs on A's workers as peer/<B>/xc/target, its
#                       leaf resolved on its home instance (peer/<B>/xc/leaf); v3 registered
#                       mid-run → both calls v2; a fresh root then v3
#   6  negatives        outside B's allowlist → 403; bad mode → 400; delegate where
#                       NOETL_CATALOG_REMOTE_CALLS is off → 403 by name
#   7  restore          A as found (server, workers); the B stack, Secret, noetl_b dropped
#
# Usage:
#   SERVER_IMAGE=localhost/noetl-server-rust:<tag> WORKER_IMAGE=localhost/noetl-worker:<tag> \
#     NOETL_CLI_BIN=/path/to/noetl ci/kind/e2e_catalog_remote_exec.sh
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)/catalog/remote
SERVER_IMAGE=${SERVER_IMAGE:?set SERVER_IMAGE to a server image with catalog_remote (server >= 3.161.0)}
WORKER_IMAGE=${WORKER_IMAGE:?set WORKER_IMAGE to a worker whose noetl-tools forwards remote: (tools >= 4.6.0)}
CLI=${NOETL_CLI_BIN:?set NOETL_CLI_BIN to a noetl CLI with \`instance init\` (cli >= 6.0.0)}
MAX_LOAD=${MAX_LOAD:-6}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PSQL="kubectl --context $CTX -n postgres exec -i deploy/postgres -- psql -v ON_ERROR_STOP=1"
PG_ADMIN_USER=${PG_ADMIN_USER:-demo}
PGADM="$PSQL -U $PG_ADMIN_USER -d noetl"
PG="$PSQL -U noetl -Atq -d"
PORT_A=${PORT_A:-38096}; PORT_B=${PORT_B:-38097}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/remote-exec-e2e.XXXXXX")}
ARMED=0; PFS=(); NT=""; NL=""; EID1=""
A_DEPLOYS=(noetl-server-rust noetl-worker-rust noetl-worker-system-pool)
B_OBJECTS="deploy/noetl-server-b deploy/noetl-worker-b deploy/noetl-worker-system-b sts/noetl-cmdbus-writer-b svc/noetl-server-b svc/noetl-cmdbus-writer-b-0 svc/noetl-cmdbus-writer-b-headless secret/catalog-remote-keys"
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

restore() {
  if [ -n "${HOLD_FILE:-}" ]; then
    touch "$HOLD_FILE"; echo "holding (rm $HOLD_FILE to restore)"; i=0
    while [ -e "$HOLD_FILE" ] && [ $i -lt 720 ]; do i=$((i+1)); sleep 5; done
  fi
  for p in ${PFS[@]+"${PFS[@]}"}; do kill "$p" 2>/dev/null || true; done
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring"
    if [ -n "${ID_B:-}" ]; then
      $PG noetl -c "DELETE FROM noetl.execution_remote_pin WHERE instance_id = '$ID_B'; DELETE FROM noetl.catalog_remote_call WHERE instance_id = '$ID_B';" >/dev/null 2>&1 || true
      $PG noetl -c "UPDATE noetl.catalog SET archived_at = now() WHERE archived_at IS NULL AND (path LIKE 'xc/%' OR path LIKE 'peer/$ID_B/%')" >/dev/null 2>&1 \
        && echo "  archived A's xc/* and peer/<B>/* test rows" || echo "  !! test rows on A not archived"
    fi
    for d in "${A_DEPLOYS[@]}"; do
      $K replace -f "$W/snap/$d.json" >/dev/null && echo "  restored $d" || echo "  !! could not restore $d (snapshot: $W/snap/$d.json)"
    done
    # shellcheck disable=SC2086
    $K delete $B_OBJECTS --ignore-not-found >/dev/null 2>&1 || true
    for d in "${A_DEPLOYS[@]}"; do $K rollout status "deploy/$d" --timeout=300s >/dev/null || true; done
    $PGADM -c "DROP DATABASE IF EXISTS noetl_b WITH (FORCE)" >/dev/null 2>&1 && echo "  dropped noetl_b" || echo "  !! noetl_b not dropped"
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
for img in "$SERVER_IMAGE" "$WORKER_IMAGE"; do
  podman exec "$NODE" crictl inspecti "$img" >/dev/null 2>&1 && ok "image in node: $img" || { echo "REFUSED: $img not loaded"; exit 5; }
done
"$CLI" instance init --help >/dev/null 2>&1 && ok "cli: $("$CLI" --version | head -1)" || { echo "REFUSED: $CLI has no \`instance init\`"; exit 5; }

step "1. arm"
mkdir -p "$W/snap" "$W/keys"
clean='del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)'
for d in "${A_DEPLOYS[@]}"; do $K get deploy "$d" -o json | jq "$clean" > "$W/snap/$d.json"; done
$K get sts noetl-cmdbus-writer -o json | jq "$clean" > "$W/snap/writer.json"
for s in noetl-cmdbus-writer-0 noetl-cmdbus-writer-headless; do $K get svc "$s" -o json | jq "$clean | del(.spec.clusterIP,.spec.clusterIPs)" > "$W/snap/svc-$s.json"; done
for f in NOETL_CATALOG_REMOTE_CALLS NOETL_CATALOG_DISCOVERY; do
  jq -e --arg f "$f" '[.spec.template.spec.containers[0].env[]?|select(.name==$f)]|length==0' "$W/snap/noetl-server-rust.json" >/dev/null \
    && ok "as found, A does not set $f" || bad "A as found already sets $f"
done
ARMED=1
"$CLI" instance init --key "$W/keys/a.json" >/dev/null; "$CLI" instance init --key "$W/keys/b.json" >/dev/null
ID_A=$(jq -r .instance_id "$W/keys/a.json"); ID_B=$(jq -r .instance_id "$W/keys/b.json")
ok "keys minted: A=$ID_A B=$ID_B (mounted from a Secret, never logged)"
$K create secret generic catalog-remote-keys --from-file=a.json="$W/keys/a.json" --from-file=b.json="$W/keys/b.json" \
  --dry-run=client -o yaml | $K apply -f - >/dev/null

$PGADM -c "DROP DATABASE IF EXISTS noetl_b WITH (FORCE)" >/dev/null 2>&1 || true
$PGADM -c "CREATE DATABASE noetl_b OWNER noetl" >/dev/null
$PSQL -U noetl -d noetl_b -c "CREATE SCHEMA IF NOT EXISTS noetl" >/dev/null
DDL=${SERVER_DDL:-$OPS/../server/db/ddl/postgres/schema_ddl.sql}
[ -f "$DDL" ] || { bad "server DDL not found at $DDL (set SERVER_DDL)"; exit 1; }
$PSQL -U noetl -d noetl_b -q -f - < "$DDL" >"$W/ddl.log" 2>&1 && ok "database noetl_b created from schema_ddl.sql" || { bad "noetl_b DDL: $(tail -3 "$W/ddl.log")"; exit 1; }

SVC_A=http://noetl-server-rust.noetl.svc.cluster.local:8082
SVC_B=http://noetl-server-b.noetl.svc.cluster.local:8082
peer_env() {  # peer_env <self-key> <self-url> <audience> <trusted-id> <peer-url#audience>
  jq -n --arg k "$1" --arg u "$2" --arg a "$3" --arg t "$4" --arg p "$5" '[
    {name:"NOETL_INSTANCE_REGISTRY",value:"true"},
    {name:"NOETL_INSTANCE_AUDIENCE",value:$a},
    {name:"NOETL_INSTANCE_TRUSTED_IDS",value:$t},
    {name:"NOETL_CATALOG_CAS",value:"true"},
    {name:"NOETL_CATALOG_PINNING",value:"true"},
    {name:"NOETL_CATALOG_DISCOVERY",value:"true"},
    {name:"NOETL_CATALOG_PEER_KEY_FILE",value:("/etc/noetl/peer/" + $k)},
    {name:"NOETL_CATALOG_SELF_URL",value:$u},
    {name:"NOETL_CATALOG_PEERS",value:$p},
    {name:"NOETL_CATALOG_ADVERT_SECS",value:"5"}]'
}
mount_keys='.spec.template.spec.volumes = ((.spec.template.spec.volumes // []) + [{"name":"catalog-remote-keys","secret":{"secretName":"catalog-remote-keys","items":[{"key":"a.json","path":"a.json"},{"key":"b.json","path":"b.json"}]}}])
  | .spec.template.spec.containers[0].volumeMounts = ((.spec.template.spec.containers[0].volumeMounts // []) + [{"name":"catalog-remote-keys","mountPath":"/etc/noetl/peer","readOnly":true}])'
# Point a spec at B: B's writer, B's server. Applied to every env value.
to_b='walk(if type == "string" then
    gsub("noetl-cmdbus-writer-0\\.noetl"; "noetl-cmdbus-writer-b-0.noetl")
    | gsub("noetl-cmdbus-writer-headless"; "noetl-cmdbus-writer-b-headless")
    | gsub("http://noetl\\.noetl\\.svc"; "http://noetl-server-b.noetl.svc")
    | gsub("http://noetl-server-rust\\.noetl\\.svc"; "http://noetl-server-b.noetl.svc")
  else . end)'
rename() {  # rename <name>: a Deployment/StatefulSet as a new app, no inherited labels or PVCs
  echo ".metadata.name = \"$1\" | del(.metadata.labels) | del(.metadata.annotations) | .spec.replicas = 1
  | .spec.selector = {matchLabels:{app:\"$1\"}} | .spec.template.metadata = {labels:{app:\"$1\"}}
  | .spec.template.spec.volumes = [ (.spec.template.spec.volumes // [])[] | select(.persistentVolumeClaim == null) ]"
}

# --- A: the new server image + REMOTE_CALLS; the new worker image on both pools.
peer_env a.json "$SVC_A" cluster-a "$ID_B" "$SVC_B#cluster-b" \
  | jq '. + [{name:"NOETL_CATALOG_REMOTE_CALLS",value:"true"}]' > "$W/env-a.json"
jq --arg img "$SERVER_IMAGE" --slurpfile e "$W/env-a.json" ".spec.template.spec.containers[0].image = \$img
  | .spec.template.spec.containers[0].env += \$e[0] | $mount_keys" "$W/snap/noetl-server-rust.json" | $K replace -f - >/dev/null
for d in noetl-worker-rust noetl-worker-system-pool; do
  jq --arg img "$WORKER_IMAGE" '.spec.template.spec.containers[0].image = $img' "$W/snap/$d.json" | $K replace -f - >/dev/null
done

# --- B: writer, server, shared worker, system-pool worker.
jq "$(rename noetl-cmdbus-writer-b) | .spec.serviceName = \"noetl-cmdbus-writer-b-headless\" | del(.spec.volumeClaimTemplates) | $to_b" \
  "$W/snap/writer.json" > "$W/writer-b.json"
jq '.metadata.name = "noetl-cmdbus-writer-b-0" | del(.metadata.labels,.metadata.annotations) | .spec.selector = {app:"noetl-cmdbus-writer-b"}' "$W/snap/svc-noetl-cmdbus-writer-0.json" > "$W/svc-writer-b.json"
jq '.metadata.name = "noetl-cmdbus-writer-b-headless" | del(.metadata.labels,.metadata.annotations) | .spec.selector = {app:"noetl-cmdbus-writer-b"} | .spec.clusterIP = "None"' "$W/snap/svc-noetl-cmdbus-writer-headless.json" > "$W/svc-writer-b-headless.json"
peer_env b.json "$SVC_B" cluster-b "$ID_A" "$SVC_A#cluster-a" \
  | jq '. + [{name:"NOETL_CATALOG_REMOTE_SERVE",value:"true"},{name:"NOETL_CATALOG_REMOTE_SERVE_ALLOW",value:"xc/*"}]' > "$W/env-b.json"
jq --arg img "$SERVER_IMAGE" --slurpfile e "$W/env-b.json" "$(rename noetl-server-b) | $to_b
  | .spec.template.spec.containers[0].volumeMounts = [ (.spec.template.spec.containers[0].volumeMounts // [])[] | select(.mountPath | startswith(\"/data\") | not) ]
  | .spec.template.spec.containers[0].image = \$img
  | .spec.template.spec.containers[0].env = ([ .spec.template.spec.containers[0].env[]
        | select(.name | test(\"^NOETL_(CHAIN_|EHDB_WORKER_QUERY_URL)\") | not)
        | if .name == \"POSTGRES_DATABASE\" then .value = \"noetl_b\"
          elif .name == \"NOETL_SERVER_MACHINE_ID\" then .value = \"2\"
          elif .name == \"NOETL_PUBLIC_SERVER_URL\" then .value = \"$SVC_B\" else . end ] + \$e[0])
  | $mount_keys" "$W/snap/noetl-server-rust.json" > "$W/server-b.json"
for pair in noetl-worker-rust:noetl-worker-b noetl-worker-system-pool:noetl-worker-system-b; do
  jq --arg img "$WORKER_IMAGE" "$(rename "${pair#*:}") | .spec.template.spec.containers[0].image = \$img | $to_b" "$W/snap/${pair%%:*}.json" > "$W/${pair#*:}.json"
done
for f in svc-writer-b svc-writer-b-headless writer-b server-b noetl-worker-b noetl-worker-system-b; do $K apply -f "$W/$f.json" >/dev/null; done
$K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: { name: noetl-server-b }
spec: { selector: { app: noetl-server-b }, ports: [ { name: http, port: 8082, targetPort: 8082 } ] }
YAML
jq -e --arg a "$SVC_A#cluster-a" '.spec.template.spec.containers[0].env[] | select(.name=="NOETL_CATALOG_PEERS") | .value == $a' "$W/server-b.json" >/dev/null \
  && ok "B advertises to A ($SVC_A)" || bad "B's NOETL_CATALOG_PEERS is not A: $(jq -r '.spec.template.spec.containers[0].env[] | select(.name=="NOETL_CATALOG_PEERS") | .value' "$W/server-b.json")"
# No A address may survive in B's specs (except the peer list, which must name A).
if jq '.spec.template.spec.containers[0].env |= map(select(.name != "NOETL_CATALOG_PEERS"))' "$W/server-b.json" | cat - "$W/noetl-worker-b.json" "$W/noetl-worker-system-b.json" "$W/writer-b.json" | grep -qE 'noetl-cmdbus-writer-0\.noetl|noetl-server-rust\.noetl|http://noetl\.noetl\.svc'; then
  bad "an A address survived in B's specs: $(grep -lE 'noetl-cmdbus-writer-0\.noetl|noetl-server-rust\.noetl|http://noetl\.noetl\.svc' "$W"/*-b.json | xargs -n1 basename | tr '\n' ' ')"
else
  ok "B's specs name only B's writer and B's server"
fi
$K rollout status sts/noetl-cmdbus-writer-b --timeout=600s >/dev/null && ok "noetl-cmdbus-writer-b rolled out" || { bad "writer-b rollout"; exit 1; }
for d in noetl-server-rust noetl-server-b noetl-worker-rust noetl-worker-system-pool noetl-worker-b noetl-worker-system-b; do
  $K rollout status "deploy/$d" --timeout=600s >/dev/null && ok "$d rolled out" || { bad "$d rollout"; $K logs "deploy/$d" --tail=30 2>/dev/null; exit 1; }
done

pf() { $K port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 & PFS+=($!); }
pf noetl-server-rust "$PORT_A" 8082; pf noetl-server-b "$PORT_B" 8082
A=http://127.0.0.1:$PORT_A; B=http://127.0.0.1:$PORT_B
for u in "$A" "$B"; do i=0; until curl -fsS -m 2 "$u/health" >/dev/null 2>&1 || curl -fsS -m 2 "$u/api/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 90 ] || { bad "$u unreachable"; exit 1; }; sleep 1; done; done
TOK_REF=$(jq -r '.spec.template.spec.containers[0].env[]|select(.name=="NOETL_INTERNAL_API_TOKEN")|.valueFrom.secretKeyRef|"\(.name) \(.key)"' "$W/snap/noetl-server-rust.json")
IT=$($K get secret "${TOK_REF% *}" -o json 2>/dev/null | jq -r --arg k "${TOK_REF#* }" '.data[$k] // empty' | base64 -d 2>/dev/null || true)
[ -n "$IT" ] && ok "internal token read from secret ${TOK_REF% *}" || bad "internal token not found (ref: $TOK_REF)"
api() { curl -sS -m 60 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }
podlogs() { $K logs -l "app=$1" --tail=-1 --since="${2:-20m}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }
podlogs noetl-server-rust > "$W/a.log"; podlogs noetl-server-b > "$W/b.log"
grep -q "catalog remote execution ON" "$W/a.log" && grep "catalog remote execution ON" "$W/a.log" | grep -q "calls=true" \
  && ok "A: catalog remote execution ON (calls)" || bad "A: no 'catalog remote execution ON calls=true' ($(grep -E 'catalog (remote|discovery)' "$W/a.log" | tail -1 | cut -c1-200))"
grep "catalog remote execution ON" "$W/b.log" | grep -q "serve=true" \
  && ok "B: catalog remote execution ON (serve, allow xc/*)" || bad "B: no 'catalog remote execution ON serve=true' ($(grep -E 'catalog (remote|discovery)' "$W/b.log" | tail -1 | cut -c1-200))"

reg() {  # reg <base> <file>
  api -X POST "$1/api/catalog/register" -d "$(jq -n --rawfile c "$2" '{content:$c,resource_type:"Playbook"}')"
}
wait_done() {  # wait_done <base> <eid> → final status on stdout
  local st="" i=0
  while :; do
    st=$(api "$1/api/executions/$2/status" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]')
    case "$st" in COMPLETED|FAILED|CANCELLED) break;; esac
    i=$((i+1)); [ $i -lt 150 ] || { st="TIMEOUT($st)"; break; }; sleep 2
  done
  echo "$st"
}
step_result() {  # step_result <base> <eid> <step> → the step's call.done result as compact JSON
  api "$1/api/executions/$2" | jq -c --arg s "$3" '[.events[]? | select(.node_name == $s and .event_type == "call.done")] | last | .result // null'
}
has_leaf() { grep -q "\"leaf\":\"$1\""; }
ver_file() { sed "s/VER/$2/g" "$HERE/$1.yaml.tmpl" > "$W/$1-$2.yaml"; echo "$W/$1-$2.yaml"; }

step "2. B is a full runtime"
reg "$B" "$HERE/local_b.yaml" >/dev/null
EB=$(api -X POST "$B/api/execute" -d '{"path":"xc/local_b","payload":{}}' | jq -r '.execution_id // empty')
if [ -n "$EB" ]; then
  st=$(wait_done "$B" "$EB")
  [ "$st" = COMPLETED ] && ok "execution $EB on B: COMPLETED on B's own bus and workers" || bad "local run on B ended $st"
  step_result "$B" "$EB" start | grep -q '"ran_on":"B"' && ok "its result came back from B's worker" || bad "B local result: $(step_result "$B" "$EB" start | head -c 200)"
  n=$($PG noetl -c "SELECT count(*) FROM noetl.event WHERE execution_id = $EB")
  [ "$n" = 0 ] && ok "A's database holds no event of B's execution" || bad "A holds $n events of B's execution"
else
  bad "execute on B refused"; exit 1
fi

step "3. publish on B"
r=$(reg "$B" "$(ver_file leaf v1)"); DL1=$(jq -r .digest <<<"$r")
r=$(reg "$B" "$(ver_file target t1)"); DT1=$(jq -r .digest <<<"$r")
[ -n "$DL1" ] && [ -n "$DT1" ] && [ "$DL1" != null ] && ok "B holds xc/leaf v1 (${DL1:0:15}…) and xc/target v1 (${DT1:0:15}…)" || bad "register on B: $r"
for m in delegate import; do
  for t in caller once; do sed "s/MODE/$m/g; s/B_ID/$ID_B/g" "$HERE/$t.yaml.tmpl" > "$W/$t-$m.yaml"; reg "$A" "$W/$t-$m.yaml" >/dev/null; done
done
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$A/api/catalog/resolve" -H 'Content-Type: application/json' -d '{"ref":"xc/target"}')
[ "$code" = 404 ] && ok "A does not hold xc/target (resolve → 404)" || bad "A local resolve xc/target: http $code"
i=0; until api "$A/api/runtime/instances" | jq -e --arg b "$ID_B" '.instances[] | select(.instance_id==$b) | .catalog.entries >= 3' >/dev/null 2>&1; do
  i=$((i+1)); [ $i -lt 30 ] || { bad "B's advert never reached A with its xc/* entries"; break; }; sleep 2; done
[ $i -lt 30 ] && ok "B is registered with A, its advert covers xc/*"

run_tree() {  # run_tree <mode> <next-leaf> <next-target> → sets EID, RES1, RES2
  local mode=$1 nl=$2 nt=$3 i=0
  EID=$(api -X POST "$A/api/execute" -d "$(jq -n --arg p "xc/caller_$mode" '{path:$p,payload:{}}')" | tee "$W/start-$mode.json" | jq -r '.execution_id // empty')
  [ -n "$EID" ] || { bad "$mode: root did not start: $(head -c 300 "$W/start-$mode.json")"; return 1; }
  until [ "$(step_result "$A" "$EID" first)" != null ]; do
    i=$((i+1)); [ $i -lt 120 ] || { bad "$mode: first call never finished"; return 1; }; sleep 2
    case "$(api "$A/api/executions/$EID/status" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]')" in FAILED|CANCELLED) bad "$mode: root failed before the first call finished"; return 1;; esac
  done
  # Mid-run: B moves BOTH playbooks on. The second call must not see it.
  NL=$(reg "$B" "$(ver_file leaf "$nl")" | jq -r .digest); NT=$(reg "$B" "$(ver_file target "$nt")" | jq -r .digest)
  ok "$mode: first call done; B now holds leaf $nl (${NL:0:15}…) and target $nt (${NT:0:15}…)"
  local st; st=$(wait_done "$A" "$EID")
  [ "$st" = COMPLETED ] && ok "$mode: root $EID on A: COMPLETED" || { bad "$mode: root ended $st"; return 1; }
  RES1=$(step_result "$A" "$EID" first); RES2=$(step_result "$A" "$EID" second)
}
run_once() {  # run_once <mode> → sets EID1, RES0
  EID1=$(api -X POST "$A/api/execute" -d "$(jq -n --arg p "xc/once_$1" '{path:$p,payload:{}}')" | jq -r '.execution_id // empty')
  local st; st=$(wait_done "$A" "$EID1")
  [ "$st" = COMPLETED ] && ok "$1: fresh root $EID1: COMPLETED" || bad "$1: fresh root ended $st"
  RES0=$(step_result "$A" "$EID1" start)
}

step "4. delegate: run it on B"
if run_tree delegate v2 t2; then
  has_leaf v1 <<<"$RES1" && has_leaf v1 <<<"$RES2" \
    && ok "delegate: both calls returned leaf v1 — the pin held across B's mid-run v2" \
    || bad "delegate: results first=$(head -c 160 <<<"$RES1") second=$(head -c 160 <<<"$RES2")"
  $PG noetl -c "SELECT digest, remote_execution_id FROM noetl.catalog_remote_call WHERE root_execution_id = $EID ORDER BY created_at" > "$W/calls.txt"
  RIDS=$(cut -d'|' -f2 "$W/calls.txt" | paste -sd, -)
  [ "$(wc -l < "$W/calls.txt" | tr -d ' ')" = 2 ] && [ "$(cut -d'|' -f1 "$W/calls.txt" | sort -u)" = "$DT1" ] \
    && ok "A recorded 2 delegated calls, both pinned to target v1 (${DT1:0:15}…), run on B as $RIDS" \
    || bad "A's call rows: $(tr '\n' ' ' < "$W/calls.txt")"
  if [ -n "$RIDS" ]; then
    n=$($PG noetl -c "SELECT count(*) FROM noetl.event WHERE execution_id IN ($RIDS)")
    [ "$n" = 0 ] && ok "the delegated executions are not in A's event log (they ran on B)" || bad "A holds $n events of the delegated runs"
    $PG noetl_b -c "SELECT digest, root_execution_id FROM noetl.execution_catalog_pin WHERE execution_id IN ($RIDS)" > "$W/bpins.txt"
    [ "$(cut -d'|' -f1 "$W/bpins.txt" | sort -u)" = "$DT1" ] && [ "$(cut -d'|' -f2 "$W/bpins.txt" | sort -u | wc -l | tr -d ' ')" = 1 ] \
      && ok "B ran target v1 both times, under ONE pin (root $(cut -d'|' -f2 "$W/bpins.txt" | head -1))" || bad "B's pins: $(tr '\n' ' ' < "$W/bpins.txt")"
    $PG noetl_b -c "SELECT version, digest FROM noetl.execution_catalog_pin WHERE parent_execution_id IN ($RIDS) AND path = 'xc/leaf'" > "$W/bleaf.txt"
    [ "$(wc -l < "$W/bleaf.txt" | tr -d ' ')" = 2 ] && [ "$(cut -d'|' -f2 "$W/bleaf.txt" | sort -u)" = "$DL1" ] \
      && ok "B's own sub-playbook xc/leaf resolved to v$(cut -d'|' -f1 "$W/bleaf.txt" | sort -u) (${DL1:0:15}…) in both runs, though v2 was registered between them" \
      || bad "B's leaf pins: $(tr '\n' ' ' < "$W/bleaf.txt")"
    $PG noetl_b -c "SELECT count(*) FROM noetl.catalog_remote_exec WHERE execution_id IN ($RIDS) AND origin_instance = '$ID_A'" | grep -qx 2 \
      && ok "B recorded both runs as started by A (only A may read them)" || bad "B's catalog_remote_exec rows missing"
  fi
  podlogs noetl-server-b > "$W/b.log"
  grep -c "catalog remote execute served" "$W/b.log" | grep -qv '^0$' && ok "B logged 'catalog remote execute served'" || bad "no serve line in B's log"
fi
run_once delegate
has_leaf v2 <<<"$RES0" && ok "delegate: a fresh root sees leaf v2" || bad "delegate fresh root result: $(head -c 200 <<<"$RES0")"
FR=$($PG noetl -c "SELECT digest FROM noetl.catalog_remote_call WHERE root_execution_id = ${EID1:-0}")
[ -n "$NT" ] && [ "$FR" = "$NT" ] && ok "delegate: … and target v2 (${NT:0:15}…)" || bad "delegate fresh root target digest: $FR (want $NT)"

step "5. import: pull it into A"
DT2=$NT; DL2=$NL
if run_tree import v3 t3; then
  has_leaf v2 <<<"$RES1" && has_leaf v2 <<<"$RES2" \
    && ok "import: both calls returned leaf v2 — the pin held across B's mid-run v3" \
    || bad "import: results first=$(head -c 160 <<<"$RES1") second=$(head -c 160 <<<"$RES2")"
  $PG noetl -c "SELECT reference || '|' || digest || '|' || path FROM noetl.execution_remote_pin WHERE root_execution_id = $EID ORDER BY reference" > "$W/rpins.txt"
  grep -qx "noetl://$ID_B/xc/leaf|$DL2|peer/$ID_B/xc/leaf" "$W/rpins.txt" && grep -qx "noetl://$ID_B/xc/target|$DT2|peer/$ID_B/xc/target" "$W/rpins.txt" \
    && ok "A's root pinned noetl://<B>/xc/target → v2 and, by home-instance resolution, noetl://<B>/xc/leaf → v2" \
    || bad "A's remote pins: $(tr '\n' ' ' < "$W/rpins.txt")"
  n=$($PG noetl -c "SELECT count(*) FROM noetl.execution_catalog_pin WHERE root_execution_id = $EID AND path = 'peer/$ID_B/xc/target'")
  [ "$n" = 2 ] && ok "both imported calls ran on A as peer/<B>/xc/target" || bad "A's pins for peer/<B>/xc/target: $n"
  n=$($PG noetl -c "SELECT count(*) FROM noetl.execution_catalog_pin WHERE root_execution_id = $EID AND path = 'peer/$ID_B/xc/leaf' AND digest = '$DL2'")
  [ "$n" = 2 ] && ok "… and their leaf ran on A as peer/<B>/xc/leaf v2" || bad "A's pins for peer/<B>/xc/leaf at v2: $n"
  n=$($PG noetl_b -c "SELECT count(*) FROM noetl.catalog_remote_exec WHERE origin_root = $EID")
  [ "$n" = 0 ] && ok "import ran nothing on B" || bad "B ran $n executions for an import-mode root"
fi
run_once import
has_leaf v3 <<<"$RES0" && ok "import: a fresh root sees leaf v3" || bad "import fresh root result: $(head -c 200 <<<"$RES0")"

step "6. negatives"
cat > "$W/other.yaml" <<'YAML'
apiVersion: noetl.io/v2
kind: Playbook
metadata: { name: xc_other, path: other/x }
workflow:
  - step: start
    tool: { kind: noop }
YAML
reg "$B" "$W/other.yaml" >/dev/null; sleep 8
r=$(api -X POST "$A/api/execute" -d "$(jq -n --arg p "noetl://$ID_B/other/x" '{path:$p,remote:"delegate",payload:{}}')")
grep -q "NOETL_CATALOG_REMOTE_SERVE_ALLOW" <<<"$r" && ok "a path outside B's allowlist is refused by B ($(jq -r '.error // .message // .detail' <<<"$r" | cut -c1-110))" || bad "allowlist: $(head -c 300 <<<"$r")"
code=$(api -o "$W/bogus.json" -w '%{http_code}' -X POST "$A/api/execute" -d "$(jq -n --arg p "noetl://$ID_B/xc/target" '{path:$p,remote:"teleport",payload:{}}')")
case "$code" in 400|422) true;; *) false;; esac && ok "remote: teleport → $code ($(jq -r '.error // .message // .detail' "$W/bogus.json" | cut -c1-80))" || bad "bad mode: http $code $(head -c 200 "$W/bogus.json")"
code=$(api -o "$W/off.json" -w '%{http_code}' -X POST "$B/api/execute" -d "$(jq -n --arg p "noetl://$ID_A/xc/caller_import" '{path:$p,remote:"delegate",payload:{}}')")
[ "$code" = 403 ] && grep -q NOETL_CATALOG_REMOTE_CALLS "$W/off.json" && ok "B (REMOTE_CALLS off) refuses remote: delegate by name (403)" || bad "flag-off delegate: http $code $(head -c 200 "$W/off.json")"

[ ${#fails[@]} -eq 0 ]
