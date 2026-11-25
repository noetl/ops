#!/usr/bin/env bash
# Kind e2e: cross-cluster playbook discovery (noetl/ai-meta#548, Phase 2).
#
# Two control planes in one kind cluster, each with its OWN database, its own
# instance key, and its own trust list: "A" is the existing noetl-server-rust
# (database noetl), "B" is a second server, noetl-server-b (database noetl_b).
# A playbook registered only on B must be findable from A and run on A's workers.
#
#   0  gates            load, kind API, images, CLI for keys
#   1  arm              keys → Secret; database noetl_b; A and B with registry + CAS + discovery
#   2  advert           B registers with A as a distributed instance carrying a Mixed bloom
#   3  locate           by name, by version, by digest, by noetl://<B>/…: verified + imported under peer/<B>/
#   4  execute          POST /api/execute {path} that only B holds → runs on A, COMPLETED
#   5  negatives        unknown name: bloom says no → 0 peers queried; A untrusted on B → 403
#   6  object store     an S3-API server in kind: minio+http:// fetch with #sha256, allowlist fail-closed
#   7  restore          A as found; B, MinIO, Secret, noetl_b dropped; test rows removed
#
# Usage:
#   SERVER_IMAGE=localhost/noetl-server-rust:<tag> NOETL_CLI_BIN=/path/to/noetl \
#     ci/kind/e2e_catalog_discovery.sh
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
SERVER_IMAGE=${SERVER_IMAGE:?set SERVER_IMAGE to a server image with noetl/ai-meta#548 Phase 2}
CLI=${NOETL_CLI_BIN:?set NOETL_CLI_BIN to a noetl CLI with \`instance init\` (cli >= 6.0.0)}
# Any S3-API server. MinIO no longer publishes public images, so the default is
# Adobe's S3Mock (accepts any credentials). `minio+http://` = "S3 API at this endpoint".
S3_IMAGE=${S3_IMAGE:-docker.io/adobe/s3mock:3.12.0}
MAX_LOAD=${MAX_LOAD:-6}
NODE=${KIND_NODE:-noetl-control-plane}
CTX=kind-noetl; NS=noetl
K="kubectl --context $CTX -n $NS"
PSQL="kubectl --context $CTX -n postgres exec -i deploy/postgres -- psql -v ON_ERROR_STOP=1"
PG_ADMIN_USER=${PG_ADMIN_USER:-demo}   # kind's superuser; creates and drops noetl_b only
PGADM="$PSQL -U $PG_ADMIN_USER -d noetl"
PG="$PSQL -U noetl -d"
PORT_A=${PORT_A:-38086}; PORT_B=${PORT_B:-38087}; PORT_M=${PORT_M:-39000}
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/discovery-e2e.XXXXXX")}
ARMED=0; PFS=()
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

restore() {
  if [ -n "${HOLD_FILE:-}" ]; then
    touch "$HOLD_FILE"; echo "holding (rm $HOLD_FILE to restore)"; i=0
    while [ -e "$HOLD_FILE" ] && [ $i -lt 360 ]; do i=$((i+1)); sleep 5; done
  fi
  if [ -n "${A:-}" ]; then
    for p in "peer/${ID_B:-x}/shared/hello" "peer/source/shared/from_bucket"; do
      apiA -X POST "$A/api/catalog/delete" -d "$(jq -n --arg p "$p" '{path:$p}')" >/dev/null 2>&1 || true
    done
  fi
  for p in ${PFS[@]+"${PFS[@]}"}; do kill "$p" 2>/dev/null || true; done
  if [ "$ARMED" = 1 ]; then
    echo; echo "restoring"
    $K replace -f "$W/snap/noetl-server-rust.json" >/dev/null && echo "  restored noetl-server-rust" || echo "  !! could not restore A (snapshot: $W/snap/noetl-server-rust.json)"
    $K delete deploy/noetl-server-b svc/noetl-server-b pod/catalog-minio svc/catalog-minio secret/catalog-peer-keys --ignore-not-found >/dev/null 2>&1 || true
    $K rollout status deploy/noetl-server-rust --timeout=300s >/dev/null || true
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
podman exec "$NODE" crictl inspecti "$SERVER_IMAGE" >/dev/null 2>&1 && ok "image in node: $SERVER_IMAGE" || { echo "REFUSED: $SERVER_IMAGE not loaded"; exit 5; }
"$CLI" instance init --help >/dev/null 2>&1 && ok "cli: $("$CLI" --version | head -1)" || { echo "REFUSED: $CLI has no \`instance init\`"; exit 5; }

step "1. arm"
mkdir -p "$W/snap" "$W/keys"
$K get deploy noetl-server-rust -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)' > "$W/snap/noetl-server-rust.json"
for f in NOETL_INSTANCE_REGISTRY NOETL_CATALOG_CAS NOETL_CATALOG_DISCOVERY; do
  jq -e --arg f "$f" '[.spec.template.spec.containers[0].env[]?|select(.name==$f)]|length==0' "$W/snap/noetl-server-rust.json" >/dev/null \
    && ok "as found, A does not set $f" || bad "A as found already sets $f"
done
ARMED=1
"$CLI" instance init --key "$W/keys/a.json" >/dev/null; "$CLI" instance init --key "$W/keys/b.json" >/dev/null
ID_A=$(jq -r .instance_id "$W/keys/a.json"); ID_B=$(jq -r .instance_id "$W/keys/b.json")
ok "keys minted: A=$ID_A B=$ID_B (kept in $W/keys, mounted from a Secret, never logged)"
$K create secret generic catalog-peer-keys --from-file=a.json="$W/keys/a.json" --from-file=b.json="$W/keys/b.json" \
  --from-literal=AWS_ACCESS_KEY_ID=catalog-e2e --from-literal=AWS_SECRET_ACCESS_KEY="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | $K apply -f - >/dev/null
MINIO_SECRET=$($K get secret catalog-peer-keys -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

$PGADM -c "DROP DATABASE IF EXISTS noetl_b WITH (FORCE)" >/dev/null 2>&1 || true
$PGADM -c "CREATE DATABASE noetl_b OWNER noetl" >/dev/null
$PG noetl_b -c "CREATE SCHEMA IF NOT EXISTS noetl" >/dev/null
DDL=${SERVER_DDL:-$OPS/../server/db/ddl/postgres/schema_ddl.sql}
[ -f "$DDL" ] || { bad "server DDL not found at $DDL (set SERVER_DDL)"; exit 1; }
$PG noetl_b -q -f - < "$DDL" >"$W/ddl.log" 2>&1 && ok "database noetl_b created from schema_ddl.sql" || { bad "noetl_b DDL: $(tail -3 "$W/ddl.log")"; exit 1; }

# An S3-API server: one pod, bucket `playbooks` created at start.
$K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: catalog-minio, labels: { app: catalog-minio } }
spec:
  containers:
    - name: s3
      image: $S3_IMAGE
      imagePullPolicy: IfNotPresent
      env: [ { name: initialBuckets, value: playbooks } ]
      ports: [ { containerPort: 9090 } ]
---
apiVersion: v1
kind: Service
metadata: { name: catalog-minio }
spec: { selector: { app: catalog-minio }, ports: [ { port: 9000, targetPort: 9090 } ] }
YAML

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
    {name:"NOETL_CATALOG_ADVERT_SECS",value:"5"},
    {name:"NOETL_CATALOG_URI_FETCH",value:"true"},
    {name:"NOETL_CATALOG_URI_ALLOW",value:"minio+http://catalog-minio.noetl.svc.cluster.local:9000/playbooks/*"},
    {name:"AWS_ACCESS_KEY_ID",valueFrom:{secretKeyRef:{name:"catalog-peer-keys",key:"AWS_ACCESS_KEY_ID"}}},
    {name:"AWS_SECRET_ACCESS_KEY",valueFrom:{secretKeyRef:{name:"catalog-peer-keys",key:"AWS_SECRET_ACCESS_KEY"}}}]'
}
mount_keys='.spec.template.spec.volumes = ((.spec.template.spec.volumes // []) + [{"name":"catalog-peer-keys","secret":{"secretName":"catalog-peer-keys","items":[{"key":"a.json","path":"a.json"},{"key":"b.json","path":"b.json"}]}}])
  | .spec.template.spec.containers[0].volumeMounts = ((.spec.template.spec.containers[0].volumeMounts // []) + [{"name":"catalog-peer-keys","mountPath":"/etc/noetl/peer","readOnly":true}])'

peer_env a.json "$SVC_A" cluster-a "$ID_B" "$SVC_B#cluster-b" > "$W/env-a.json"
jq --arg img "$SERVER_IMAGE" --slurpfile e "$W/env-a.json" ".spec.template.spec.containers[0].image = \$img
  | .spec.template.spec.containers[0].env += \$e[0] | $mount_keys" "$W/snap/noetl-server-rust.json" | $K replace -f - >/dev/null

# B: A's spec, renamed, its own database and machine id. Every EHDB, chain and bus-writer
# variable is dropped so B can never publish to, or consume from, A's command/event
# buses: B is a catalog-only control plane, which is all this test needs of it.
peer_env b.json "$SVC_B" cluster-b "$ID_A" "$SVC_A#cluster-a" > "$W/env-b.json"
jq --arg img "$SERVER_IMAGE" --slurpfile e "$W/env-b.json" "
  .metadata.name = \"noetl-server-b\" | del(.metadata.labels) | del(.metadata.annotations)
  | .spec.replicas = 1
  | .spec.selector = {matchLabels:{app:\"noetl-server-b\"}}
  | .spec.template.metadata = {labels:{app:\"noetl-server-b\"}}
  | .spec.template.spec.volumes = [ (.spec.template.spec.volumes // [])[] | select(.persistentVolumeClaim == null) ]
  | .spec.template.spec.containers[0].volumeMounts = [ (.spec.template.spec.containers[0].volumeMounts // [])[] | select(.mountPath | startswith(\"/data\") | not) ]
  | .spec.template.spec.containers[0].image = \$img
  | .spec.template.spec.containers[0].env = ([ .spec.template.spec.containers[0].env[]
        | select(.name | test(\"^NOETL_(EHDB_|CHAIN_|COMMAND_BUS_WRITER_ADDRS|EVENT_BUS_WRITER_ADDRS|EVENT_INGEST_PUBLISH_ONLY|PERMANENT_LOG_LEAN)\") | not)
        | if .name == \"POSTGRES_DATABASE\" then .value = \"noetl_b\"
          elif .name == \"NOETL_SERVER_MACHINE_ID\" then .value = \"2\"
          elif .name == \"NOETL_PUBLIC_SERVER_URL\" then .value = \"$SVC_B\" else . end ] + \$e[0])
  | $mount_keys" "$W/snap/noetl-server-rust.json" > "$W/deploy-b.json"
$K apply -f "$W/deploy-b.json" >/dev/null
$K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: { name: noetl-server-b }
spec: { selector: { app: noetl-server-b }, ports: [ { name: http, port: 8082, targetPort: 8082 } ] }
YAML
for d in noetl-server-rust noetl-server-b; do
  $K rollout status "deploy/$d" --timeout=600s >/dev/null && ok "$d rolled out" || { bad "$d rollout"; $K logs "deploy/$d" --tail=30 2>/dev/null; exit 1; }
done
$K wait --for=condition=Ready pod/catalog-minio --timeout=180s >/dev/null && ok "S3-API server up ($S3_IMAGE)" || bad "S3-API server not ready (image pull?)"

pf() { $K port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 & PFS+=($!); }
pf noetl-server-rust "$PORT_A" 8082; pf noetl-server-b "$PORT_B" 8082; pf catalog-minio "$PORT_M" 9000
A=http://127.0.0.1:$PORT_A; B=http://127.0.0.1:$PORT_B; M=http://127.0.0.1:$PORT_M
for u in "$A" "$B"; do i=0; until curl -fsS -m 2 "$u/health" >/dev/null 2>&1 || curl -fsS -m 2 "$u/api/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 90 ] || { bad "$u unreachable"; exit 1; }; sleep 1; done; done
# The internal token, from whatever Secret the server's env references.
TOK_REF=$(jq -r '.spec.template.spec.containers[0].env[]|select(.name=="NOETL_INTERNAL_API_TOKEN")|.valueFrom.secretKeyRef|"\(.name) \(.key)"' "$W/snap/noetl-server-rust.json")
IT=$($K get secret "${TOK_REF% *}" -o json 2>/dev/null | jq -r --arg k "${TOK_REF#* }" '.data[$k] // empty' | base64 -d 2>/dev/null || true)
[ -n "$IT" ] && ok "internal token read from secret ${TOK_REF% *}" || bad "internal token not found (ref: $TOK_REF)"
apiA() { curl -sS -m 60 -H 'Content-Type: application/json' ${IT:+-H "Authorization: Bearer $IT"} "$@"; }
for d in noetl-server-rust noetl-server-b; do
  $K logs "deploy/$d" --since=15m > "$W/$d.log" 2>/dev/null || true
  grep -q "catalog discovery ON" "$W/$d.log" && ok "$d: catalog discovery ON" || bad "$d: no 'catalog discovery ON' in the log ($(grep -E 'catalog (discovery|CAS)' "$W/$d.log" | tail -1 | cut -c1-160))"
done

step "2. advert"
HELLO="$W/hello.yaml"
cat > "$HELLO" <<'YAML'
apiVersion: noetl.io/v2
kind: Playbook
metadata: { name: shared_hello, path: shared/hello }
workflow:
  - step: start
    tool: { kind: noop, result: { hello: "from cluster B" } }
    next: [ { step: end } ]
  - step: end
    tool: { kind: noop, result: { hello: "from cluster B" } }
YAML
apiA -X POST "$B/api/catalog/register" -d "$(jq -n --rawfile c "$HELLO" '{content:$c,resource_type:"Playbook"}')" > "$W/reg-b.json"
DIG=$(jq -r '.digest // empty' "$W/reg-b.json")
[ -n "$DIG" ] && ok "registered shared/hello on B only: v$(jq -r .version "$W/reg-b.json"), ${DIG:0:19}…" || bad "register on B: $(head -c 300 "$W/reg-b.json")"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$A/api/catalog/resolve" -H 'Content-Type: application/json' -d '{"ref":"shared/hello"}')
[ "$code" = 404 ] && ok "A does not hold shared/hello locally (resolve → 404)" || bad "A local resolve: http $code"
sleep 12  # two advert periods: B's bloom now includes shared/hello
apiA "$A/api/runtime/instances" > "$W/instances-a.json"
jq -e --arg b "$ID_B" '.instances[] | select(.instance_id == $b) | .runtime_kind=="distributed" and .catalog.bloom.scheme == 2 and .catalog.entries >= 1' "$W/instances-a.json" >/dev/null \
  && ok "B is registered with A as distributed, with a Mixed bloom ($(jq -r --arg b "$ID_B" '.instances[] | select(.instance_id == $b) | .catalog | "\(.entries) entries, \(.bloom.m_bits) bits, families \(.families|join(","))"' "$W/instances-a.json"))" \
  || bad "B not in A's registry with an advert: $(head -c 400 "$W/instances-a.json")"

step "3. locate"
loc() { apiA -X POST "$A/api/catalog/locate" -d "$(jq -n --arg r "$1" '{ref:$r}')"; }
loc shared/hello > "$W/loc-name.json"
jq -e --arg b "$ID_B" --arg d "$DIG" '.found_at=="peer" and .instance_id==$b and .digest==$d and .path==("peer/"+$b+"/shared/hello") and .peers_queried==1' "$W/loc-name.json" >/dev/null \
  && ok "by name: found on B, verified ${DIG:0:19}…, imported as $(jq -r .path "$W/loc-name.json") (considered $(jq -r .peers_considered "$W/loc-name.json"), maybe $(jq -r .peers_maybe "$W/loc-name.json"), queried 1)" \
  || bad "locate by name: $(head -c 400 "$W/loc-name.json")"
CID=$(jq -r .catalog_id "$W/loc-name.json")
loc "shared/hello@1" > "$W/loc-ver.json"
jq -e '.found_at=="peer" and .version==1' "$W/loc-ver.json" >/dev/null && ok "by name@version: found on B" || bad "locate by version: $(head -c 300 "$W/loc-ver.json")"
loc "$DIG" > "$W/loc-dig.json"
jq -e --arg c "$CID" '.found_at=="local" and .catalog_id==$c' "$W/loc-dig.json" >/dev/null \
  && ok "by digest: now LOCAL (the import is indexed by digest; no second body)" || bad "locate by digest: $(head -c 300 "$W/loc-dig.json")"
loc "noetl://$ID_B/shared/hello@1#$DIG" > "$W/loc-uri.json"
jq -e --arg c "$CID" '.found_at=="peer" and .catalog_id==$c' "$W/loc-uri.json" >/dev/null \
  && ok "by noetl://<B>/shared/hello@1#sha256: same imported row (dedup by digest)" || bad "locate by uri: $(head -c 300 "$W/loc-uri.json")"
apiA -X POST "$A/api/catalog/resolve" -d "$(jq -n --arg r "$DIG" '{ref:$r}')" > "$W/res-dig.json"
jq -e --arg b "$ID_B" '.sources | map(.uri) | any(startswith("noetl://" + $b + "/shared/hello@1"))' "$W/res-dig.json" >/dev/null \
  && ok "A records the provenance: source noetl://<B>/shared/hello@1, verified" || bad "provenance: $(head -c 300 "$W/res-dig.json")"

step "4. execute on A what only B registered"
EID=$(apiA -X POST "$A/api/execute" -d '{"path":"shared/hello","payload":{}}' | tee "$W/exec-start.json" | jq -r '.execution_id // empty')
if [ -n "$EID" ]; then
  i=0; while :; do st=$(apiA "$A/api/executions/$EID/status" | jq -r '.status // empty' | tr '[:lower:]' '[:upper:]'); case "$st" in COMPLETED|FAILED|CANCELLED) break;; esac; i=$((i+1)); [ $i -lt 60 ] || break; sleep 2; done
  [ "$st" = COMPLETED ] && ok "execution $EID on A: COMPLETED" || bad "execution on A ended '$st'"
  apiA "$A/api/catalog/pin/$EID" > "$W/pin.json"
  jq -e --arg d "$DIG" '.digest==$d' "$W/pin.json" >/dev/null && ok "pinned to B's digest (reason $(jq -r .reason "$W/pin.json"), path $(jq -r .path "$W/pin.json"))" || bad "pin: $(head -c 300 "$W/pin.json")"
else
  bad "execute shared/hello on A: $(head -c 300 "$W/exec-start.json")"
fi

step "5. negatives"
loc "nobody/has/this" > "$W/loc-miss.json"
jq -e '(.error // .message // "" | tostring | test("0 queried"))' "$W/loc-miss.json" >/dev/null \
  && ok "unknown name: B's bloom says no, 0 peers queried ($(jq -r '.error // .message' "$W/loc-miss.json" | cut -c1-80))" || bad "miss: $(head -c 300 "$W/loc-miss.json")"
$K set env deploy/noetl-server-b NOETL_INSTANCE_TRUSTED_IDS=ni-00000000000000000000000000000000 >/dev/null
$K rollout status deploy/noetl-server-b --timeout=300s >/dev/null
kill "${PFS[1]}" 2>/dev/null || true; pf noetl-server-b "$PORT_B" 8082; sleep 3
loc "shared/hello@latest" > "$W/loc-untrusted.json"
jq -e '(.error // .message // "" | tostring | test("not trusted|403"))' "$W/loc-untrusted.json" >/dev/null \
  && ok "A no longer trusted by B: locate refused ($(jq -r '.error // .message' "$W/loc-untrusted.json" | cut -c1-90))" || bad "untrusted: $(head -c 300 "$W/loc-untrusted.json")"

step "6. object store (S3 API)"
sed 's/shared_hello/from_bucket/; s#path: shared/hello#path: shared/from_bucket#; s/from cluster B/from MinIO/g' "$HELLO" > "$W/bucket.yaml"
AK=catalog-e2e
curl -fsS -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AK:$MINIO_SECRET" "$M/playbooks" >/dev/null 2>&1 || true
curl -fsS -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AK:$MINIO_SECRET" -T "$W/bucket.yaml" "$M/playbooks/from_bucket.yaml" >/dev/null \
  && ok "uploaded playbooks/from_bucket.yaml to the S3 server" || bad "S3 upload"
BD=$(apiA -X POST "$B/api/catalog/register" -d "$(jq -n --rawfile c "$W/bucket.yaml" '{content:$c,resource_type:"Playbook"}')" | jq -r .digest)
apiA -X POST "$B/api/catalog/delete" -d '{"path":"shared/from_bucket"}' >/dev/null  # B only computed the digest for us
U="minio+http://catalog-minio.noetl.svc.cluster.local:9000/playbooks/from_bucket.yaml"
loc "$U#$BD" > "$W/loc-minio.json"
jq -e --arg d "$BD" '.found_at=="source" and .digest==$d and .path=="peer/source/shared/from_bucket"' "$W/loc-minio.json" >/dev/null \
  && ok "minio+http:// with #sha256: fetched, verified, imported as peer/source/shared/from_bucket" || bad "minio fetch: $(head -c 300 "$W/loc-minio.json")"
loc "$U#sha256:$(printf '0%.0s' $(seq 64))" > "$W/loc-minio-bad.json"
jq -e '(.error // .message // "" | tostring | test("mismatch"))' "$W/loc-minio-bad.json" >/dev/null \
  && ok "a wrong #sha256 is refused (digest mismatch)" || bad "minio wrong digest: $(head -c 300 "$W/loc-minio-bad.json")"
loc "minio+http://catalog-minio.noetl.svc.cluster.local:9000/other/x.yaml" > "$W/loc-minio-deny.json"
jq -e '(.error // .message // "" | tostring | test("NOETL_CATALOG_URI_ALLOW"))' "$W/loc-minio-deny.json" >/dev/null \
  && ok "a URI outside NOETL_CATALOG_URI_ALLOW is refused before any fetch" || bad "allowlist: $(head -c 300 "$W/loc-minio-deny.json")"

[ ${#fails[@]} -eq 0 ]
