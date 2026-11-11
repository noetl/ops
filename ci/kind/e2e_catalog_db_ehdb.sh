#!/usr/bin/env bash
# Kind e2e: catalog sources db:// and ehdb:// (noetl/ai-meta#548, the two
# resolvers the catalog refused by name).
#
#   0  gates     load, kind API, server image, CLI (instance key)
#   1  arm       an external playbook library: database noetl_pblib, table
#                pb_lib.playbooks(path, version, content) with lib/hello v1 + v2,
#                a read-only role; its credential registered as e2e_pblib.
#                Server: registry + CAS + PINNING + DISCOVERY (own key, no peers),
#                NOETL_CATALOG_URI_FETCH, allowlist db://e2e_pblib/* + ehdb://catalog/*,
#                NOETL_CATALOG_LOG=shadow (registrations also go to the EHDB tier);
#                worker relay NOETL_EHDB_CATALOG_MIRROR_SOURCE=server (accepts them)
#   2  db://     @version=1 → imported as peer/source/lib/hello, digest = v1's;
#                no version → v2; the same URI again → same row (dedup by digest);
#                provenance recorded; execute by URI → COMPLETED, pinned;
#                wrong #sha256 refused; missing row 404; bad identifier 400;
#                an alias outside the allowlist refused before any connect
#   3  ehdb://   a playbook registered normally (so its record is in the EHDB
#                catalog tier) is located as ehdb://catalog/<its id>: imported with
#                the SAME digest as the original; an unknown id is not found
#   4  restore   server + worker as found; library database, role, credential, test paths removed
#
# Usage:
#   SERVER_IMAGE=localhost/noetl-server-rust:<tag> NOETL_CLI_BIN=/path/to/noetl \
#     ci/kind/e2e_catalog_db_ehdb.sh
set -euo pipefail
SERVER_IMAGE=${SERVER_IMAGE:?set SERVER_IMAGE}
CLI=${NOETL_CLI_BIN:?set NOETL_CLI_BIN to a noetl CLI with \`instance init\`}
MAX_LOAD=${MAX_LOAD:-6}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PG="kubectl --context $CTX -n postgres exec -i deploy/postgres -- psql -v ON_ERROR_STOP=1 -U demo -tA"
PORT=${PORT:-38093}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/cat-src.XXXXXX")}
ARMED=0; PF=; DB_MADE=0
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

restore() {
  if [ -n "$PF" ] && [ -n "${S:-}" ]; then
    api -X DELETE "$S/api/credentials/e2e_pblib" >/dev/null 2>&1 || true
    for p in peer/source/lib/hello peer/source/tests/catalog_src/ehdb_hello tests/catalog_src/ehdb_hello; do
      api -X POST "$S/api/catalog/delete" -d "$(jq -n --arg p "$p" '{path:$p}')" >/dev/null 2>&1 || true
    done
  fi
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring"
    for d in noetl-server-rust noetl-worker-rust; do
      [ -f "$W/snap/$d.json" ] || continue
      $K replace -f "$W/snap/$d.json" >/dev/null && echo "  restored $d" || echo "  !! could not restore $d (snapshot: $W/snap/$d.json)"
    done
    for d in noetl-server-rust noetl-worker-rust; do $K rollout status deploy/$d --timeout=300s >/dev/null || true; done
    $K delete secret catalog-src-key --ignore-not-found >/dev/null 2>&1 || true
  fi
  if [ "$DB_MADE" = 1 ]; then
    $PG -d postgres -c "DROP DATABASE IF EXISTS noetl_pblib WITH (FORCE)" >/dev/null 2>&1 || true
    $PG -d postgres -c "DROP ROLE IF EXISTS pblib_reader" >/dev/null 2>&1 || true
    echo "  dropped noetl_pblib and pblib_reader"
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
podman exec "$NODE" crictl inspecti "$SERVER_IMAGE" >/dev/null 2>&1 && ok "image in node: $SERVER_IMAGE" || { echo "REFUSED: $SERVER_IMAGE not loaded"; exit 5; }
"$CLI" instance --help >/dev/null 2>&1 || { echo "REFUSED: $CLI has no instance command"; exit 5; }

step "1. arm"
mkdir -p "$W/snap" "$W/keys"
lib_yaml() { # lib_yaml <version-label>
  cat <<YAML
apiVersion: noetl.io/v2
kind: Playbook
metadata: { name: lib_hello, path: lib/hello }
workflow:
  - step: start
    tool: { kind: noop, result: { hello: "from the db library, $1" } }
    next: [ { step: end } ]
  - step: end
    tool: { kind: noop, result: { hello: "from the db library, $1" } }
YAML
}
lib_yaml v1 > "$W/lib-v1.yaml"; lib_yaml v2 > "$W/lib-v2.yaml"
PW=$(openssl rand -hex 16)
DB_MADE=1
$PG -d postgres -c "DROP DATABASE IF EXISTS noetl_pblib WITH (FORCE)" >/dev/null
$PG -d postgres -c "DROP ROLE IF EXISTS pblib_reader" >/dev/null
$PG -d postgres -c "CREATE ROLE pblib_reader LOGIN PASSWORD '$PW'" >/dev/null
$PG -d postgres -c "CREATE DATABASE noetl_pblib" >/dev/null
{
  echo "CREATE SCHEMA pb_lib; CREATE TABLE pb_lib.playbooks (path text NOT NULL, version int NOT NULL, content text NOT NULL, PRIMARY KEY (path, version));"
  printf "INSERT INTO pb_lib.playbooks VALUES ('lib/hello', 1, %s), ('lib/hello', 2, %s);\n" \
    "\$pb\$$(cat "$W/lib-v1.yaml")\$pb\$" "\$pb\$$(cat "$W/lib-v2.yaml")\$pb\$"
  echo "GRANT CONNECT ON DATABASE noetl_pblib TO pblib_reader; GRANT USAGE ON SCHEMA pb_lib TO pblib_reader; GRANT SELECT ON pb_lib.playbooks TO pblib_reader;"
} | $PG -d noetl_pblib >/dev/null && ok "library database noetl_pblib: pb_lib.playbooks holds lib/hello v1, v2; read-only role pblib_reader" || { bad "library setup"; exit 1; }

for d in noetl-server-rust noetl-worker-rust; do
  $K get deploy "$d" -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap/$d.json"
done
ARMED=1
# The worker relay accepts catalog-tier appends only when the server is that
# tier's mirror source; kind's worker sets it for the event log only.
jq '.spec.template.spec.containers[0].env = ([.spec.template.spec.containers[0].env[] | select(.name != "NOETL_EHDB_CATALOG_MIRROR_SOURCE")]
    + [{"name":"NOETL_EHDB_CATALOG_MIRROR_SOURCE","value":"server"}])' "$W/snap/noetl-worker-rust.json" | $K replace -f - >/dev/null
$K rollout status deploy/noetl-worker-rust --timeout=600s >/dev/null && ok "worker relay: NOETL_EHDB_CATALOG_MIRROR_SOURCE=server (catalog-tier appends accepted)" || { bad "worker rollout"; exit 1; }
"$CLI" instance init --key "$W/keys/a.json" >/dev/null
ID_A=$(jq -r .instance_id "$W/keys/a.json")
$K create secret generic catalog-src-key --from-file=a.json="$W/keys/a.json" --dry-run=client -o yaml | $K apply -f - >/dev/null
SELF=http://noetl-server-rust.noetl.svc.cluster.local:8082
jq --arg img "$SERVER_IMAGE" --arg id "$ID_A" --arg self "$SELF" '
  .spec.template.spec.containers[0].image = $img
  | .spec.template.spec.containers[0].env += [
      {name:"NOETL_INSTANCE_REGISTRY",value:"true"},
      {name:"NOETL_INSTANCE_AUDIENCE",value:"e2e-catalog-src"},
      {name:"NOETL_INSTANCE_TRUSTED_IDS",value:$id},
      {name:"NOETL_CATALOG_CAS",value:"true"},
      {name:"NOETL_CATALOG_PINNING",value:"true"},
      {name:"NOETL_CATALOG_DISCOVERY",value:"true"},
      {name:"NOETL_CATALOG_PEER_KEY_FILE",value:"/etc/noetl/peer/a.json"},
      {name:"NOETL_CATALOG_SELF_URL",value:$self},
      {name:"NOETL_CATALOG_PEERS",value:""},
      {name:"NOETL_CATALOG_URI_FETCH",value:"true"},
      {name:"NOETL_CATALOG_URI_ALLOW",value:"db://e2e_pblib/*,ehdb://catalog/*"},
      {name:"NOETL_CATALOG_LOG",value:"shadow"}]
  | .spec.template.spec.volumes = ((.spec.template.spec.volumes // []) + [{"name":"catalog-src-key","secret":{"secretName":"catalog-src-key"}}])
  | .spec.template.spec.containers[0].volumeMounts = ((.spec.template.spec.containers[0].volumeMounts // []) + [{"name":"catalog-src-key","mountPath":"/etc/noetl/peer","readOnly":true}])
' "$W/snap/noetl-server-rust.json" | $K replace -f - >/dev/null
$K rollout status deploy/noetl-server-rust --timeout=600s >/dev/null && ok "server rolled out: CAS, pinning, discovery (no peers), URI fetch for db://e2e_pblib/* + ehdb://catalog/*, catalog log shadow" || { bad "rollout"; exit 1; }
$K port-forward svc/noetl-server-rust "$PORT:8082" >/dev/null 2>&1 & PF=$!
S=http://127.0.0.1:$PORT; i=0
until curl -fsS -m 2 "$S/api/health" >/dev/null 2>&1 || curl -fsS -m 2 "$S/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 90 ] || { bad "server unreachable"; exit 1; }; sleep 1; done
TOK_REF=$(jq -r '.spec.template.spec.containers[0].env[]|select(.name=="NOETL_INTERNAL_API_TOKEN")|.valueFrom.secretKeyRef|"\(.name) \(.key)"' "$W/snap/noetl-server-rust.json")
IT=$($K get secret "${TOK_REF% *}" -o json 2>/dev/null | jq -r --arg k "${TOK_REF#* }" '.data[$k] // empty' | base64 -d 2>/dev/null || true)
api() { curl -sS -m 60 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }
$K logs deploy/noetl-server-rust --since=10m > "$W/server.log" 2>/dev/null || true
grep -q "catalog discovery ON" "$W/server.log" && ok "server log: catalog discovery ON" || bad "discovery not on: $(grep -E 'catalog (discovery|CAS)' "$W/server.log" | tail -1 | cut -c1-160)"
api -X POST "$S/api/credentials" -d "$(jq -n --arg pw "$PW" '{name:"e2e_pblib",type:"postgres",data:{host:"postgres.postgres.svc.cluster.local",port:5432,user:"pblib_reader",password:$pw,database:"noetl_pblib"},description:"kind e2e: external playbook library (read-only)"}')" > "$W/cred.json"
jq -e '.name=="e2e_pblib" or .id!=null' "$W/cred.json" >/dev/null && ok "credential e2e_pblib (postgres, read-only role)" || bad "credential: $(head -c 300 "$W/cred.json")"
loc() { api -X POST "$S/api/catalog/locate" -d "$(jq -n --arg r "$1" '{ref:$r}')"; }

step "2. db://"
U="db://e2e_pblib/pb_lib.playbooks?path=lib/hello"
loc "$U&version=1" > "$W/loc-v1.json"
D1=$(jq -r '.digest // empty' "$W/loc-v1.json"); C1=$(jq -r '.catalog_id // empty' "$W/loc-v1.json")
jq -e '.found_at=="source" and .path=="peer/source/lib/hello"' "$W/loc-v1.json" >/dev/null \
  && ok "db:// @version=1: fetched with the e2e_pblib credential, imported as peer/source/lib/hello (${D1:0:19}…)" || bad "db v1: $(head -c 400 "$W/loc-v1.json")"
loc "$U" > "$W/loc-latest.json"
D2=$(jq -r '.digest // empty' "$W/loc-latest.json")
[ -n "$D2" ] && [ "$D2" != "$D1" ] && ok "db:// without version: the highest row (v2, a different digest ${D2:0:19}…)" || bad "db latest: $(head -c 300 "$W/loc-latest.json")"
loc "$U&version=1#$D1" > "$W/loc-v1-again.json"
if [ "$(jq -r .digest "$W/loc-v1-again.json")" = "$D1" ]; then
  ok "the same URI pinned to its digest resolves to the same body"
else
  bad "db v1 again: $(head -c 300 "$W/loc-v1-again.json")"
fi
n=$(kubectl --context $CTX -n postgres exec -i deploy/postgres -- psql -U noetl -d noetl -tA -c "select count(*) from noetl.catalog where path = 'peer/source/lib/hello' and archived_at is null" 2>/dev/null | tr -d ' ')
[ "$n" = 2 ] && ok "dedup by digest: 3 locates, 2 distinct bodies → 2 live catalog rows for peer/source/lib/hello" || bad "dedup: $n live rows for peer/source/lib/hello"
api -X POST "$S/api/catalog/resolve" -d "$(jq -n --arg r "$D1" '{ref:$r}')" > "$W/res-d1.json"
jq -e '.sources | map(.uri) | any(startswith("db://e2e_pblib/pb_lib.playbooks?path=lib/hello"))' "$W/res-d1.json" >/dev/null \
  && ok "provenance: v1's digest lists its db:// source" || bad "provenance: $(head -c 300 "$W/res-d1.json")"
EID=$(api -X POST "$S/api/execute" -d "$(jq -n --arg p "$U&version=1#$D1" '{path:$p,payload:{}}')" | tee "$W/exec-start.json" | jq -r '.execution_id // empty')
if [ -n "$EID" ]; then
  i=0; while :; do st=$(api "$S/api/executions/$EID/status" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]'); case "$st" in COMPLETED|FAILED|CANCELLED) break;; esac; i=$((i+1)); [ $i -lt 60 ] || break; sleep 2; done
  [ "$st" = COMPLETED ] && ok "execute by db:// URI: $EID COMPLETED" || bad "execute by db:// ended '$st'"
  api "$S/api/catalog/pin/$EID" > "$W/pin.json"
  jq -e --arg d "$D1" '.digest==$d' "$W/pin.json" >/dev/null && ok "execution pinned to the db row's digest (reason $(jq -r .reason "$W/pin.json"))" || bad "pin: $(head -c 300 "$W/pin.json")"
else
  bad "execute by db:// URI: $(head -c 300 "$W/exec-start.json")"
fi
ZERO="sha256:$(printf '0%.0s' $(seq 64))"
loc "$U&version=1#$ZERO" > "$W/loc-bad-dig.json"
jq -e '(.error // .message // "" | tostring | test("mismatch"))' "$W/loc-bad-dig.json" >/dev/null && ok "a wrong #sha256 pin is refused (digest mismatch)" || bad "wrong pin: $(head -c 300 "$W/loc-bad-dig.json")"
loc "$U&version=9" > "$W/loc-missing.json"
jq -e '(.error // .message // "" | tostring | test("no row"))' "$W/loc-missing.json" >/dev/null && ok "a version that is not in the table: not found by name" || bad "missing row: $(head -c 300 "$W/loc-missing.json")"
loc "db://e2e_pblib/pb_lib.playbooks;drop?path=lib/hello" > "$W/loc-ident.json"
jq -e '(.error // .message // "" | tostring | test("identifiers"))' "$W/loc-ident.json" >/dev/null && ok "a non-identifier table name is refused before any connect" || bad "identifier: $(head -c 300 "$W/loc-ident.json")"
loc "db://other_alias/pb_lib.playbooks?path=lib/hello" > "$W/loc-deny.json"
jq -e '(.error // .message // "" | tostring | test("NOETL_CATALOG_URI_ALLOW"))' "$W/loc-deny.json" >/dev/null && ok "an alias outside NOETL_CATALOG_URI_ALLOW is refused" || bad "allowlist: $(head -c 300 "$W/loc-deny.json")"

step "3. ehdb://"
sed 's/lib_hello/ehdb_hello/; s#path: lib/hello#path: tests/catalog_src/ehdb_hello#; s/the db library, v1/a normal registration/g' "$W/lib-v1.yaml" > "$W/ehdb.yaml"
api -X POST "$S/api/catalog/register" -d "$(jq -n --rawfile c "$W/ehdb.yaml" '{content:$c,resource_type:"Playbook"}')" > "$W/reg-ehdb.json"
EC=$(jq -r '.catalog_id // empty' "$W/reg-ehdb.json"); ED=$(jq -r '.digest // empty' "$W/reg-ehdb.json")
[ -n "$EC" ] && ok "registered tests/catalog_src/ehdb_hello normally: catalog_id $EC (${ED:0:19}…)" || bad "register: $(head -c 300 "$W/reg-ehdb.json")"
sleep 2
loc "ehdb://catalog/$EC" > "$W/loc-ehdb.json"
if jq -e --arg d "$ED" '.found_at=="source" and .digest==$d and .path=="peer/source/tests/catalog_src/ehdb_hello"' "$W/loc-ehdb.json" >/dev/null; then
  ok "ehdb://catalog/$EC: read from the EHDB catalog tier, content_sha256 checked, imported with the original's digest"
else
  bad "ehdb locate: $(head -c 400 "$W/loc-ehdb.json")"
fi
api -X POST "$S/api/catalog/resolve" -d "$(jq -n --arg r "$ED" '{ref:$r}')" > "$W/res-ed.json"
jq -e '.sources | map(.uri) | any(startswith("ehdb://catalog/"))' "$W/res-ed.json" >/dev/null \
  && ok "the digest now lists ehdb://catalog/$EC as a source next to the local registration" || bad "ehdb provenance: $(head -c 300 "$W/res-ed.json")"
loc "ehdb://catalog/999999999999" > "$W/loc-ehdb-miss.json"
jq -e '(.error // .message // "" | tostring | test("no catalog.registered record|not found"))' "$W/loc-ehdb-miss.json" >/dev/null \
  && ok "an unknown catalog id: not found by name" || bad "ehdb miss: $(head -c 300 "$W/loc-ehdb-miss.json")"

[ ${#fails[@]} -eq 0 ]
