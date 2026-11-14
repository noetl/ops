#!/usr/bin/env bash
# Latency benchmark stack (noetl/ai-meta#557).
#
# A complete, ISOLATED NoETL runtime inside the shared kind cluster, so a
# benchmark (or a stage's before/after) never swaps the images or env of the
# stack other sessions are using:
#
#   database   noetl_lat (fresh, from server/db/ddl/postgres/schema_ddl.sql)
#   writer     sts/noetl-cmdbus-writer-lat      (cmdbus + event bus + KV + tier)
#   server     deploy/noetl-server-lat          svc/noetl-server-lat:8082
#   workers    deploy/noetl-worker-lat          (user pool, 4 slots)
#              deploy/noetl-worker-system-lat   (system pool, 2 slots)
#
# Every spec is DERIVED from the live A stack (secrets refs, probes, resources)
# and then pointed at its own writer, server and database.  The server env is
# overlaid with prod's dispatch-path settings (ops/ci/manifests/noetl/
# server-rust-embedded-sts-prod.yaml): offserver state builder, publish-only
# ingest, retrigger-on-clear, shard subject routing.  Kind A does not run the
# offserver builder, so measuring on A would measure a path prod does not take.
#
# Usage
#   SERVER_IMAGE=... WORKER_IMAGE=... ci/kind/latency/stack.sh up
#   ci/kind/latency/stack.sh set  [--prod-resources] [--server-image I] [--worker-image I] \
#                                 [--server-env K=V ...] [--worker-env K=V ...]
#   ci/kind/latency/stack.sh status
#   ci/kind/latency/stack.sh down        # deletes every *-lat object + noetl_lat
#
# `set` is how a stage is measured: flip a flag (or swap an image) on the lat
# stack only, wait for the rollout, run bench.sh, flip it back.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OPS=$(cd "$HERE/../../.." && pwd)
CTX=${KIND_CONTEXT:-kind-noetl}; NS=noetl
K="kubectl --context $CTX -n $NS"
PSQL="kubectl --context $CTX -n postgres exec -i deploy/postgres -- psql -v ON_ERROR_STOP=1"
PG_ADMIN_USER=${PG_ADMIN_USER:-demo}
DB=${LAT_DB:-noetl_lat}
W=${LAT_WORK:-${TMPDIR:-/tmp}/noetl-lat-stack}
LAT_OBJECTS="deploy/noetl-server-lat deploy/noetl-worker-lat deploy/noetl-worker-system-lat sts/noetl-cmdbus-writer-lat svc/noetl-server-lat svc/noetl-cmdbus-writer-lat-0 svc/noetl-cmdbus-writer-lat-headless"
DEPLOYS="noetl-server-lat noetl-worker-lat noetl-worker-system-lat"
clean='del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.status)'

die() { echo "ERROR: $*" >&2; exit 1; }

# Point a spec at the lat stack's own writer and server.
to_lat='walk(if type == "string" then
    gsub("noetl-cmdbus-writer-0\\.noetl"; "noetl-cmdbus-writer-lat-0.noetl")
    | gsub("noetl-cmdbus-writer-headless"; "noetl-cmdbus-writer-lat-headless")
    | gsub("http://noetl\\.noetl\\.svc"; "http://noetl-server-lat.noetl.svc")
    | gsub("http://noetl-server-rust\\.noetl\\.svc"; "http://noetl-server-lat.noetl.svc")
    | gsub("noetl-worker-rust-metrics\\.noetl"; "noetl-worker-lat-metrics.noetl")
    | gsub("noetl-worker-system-pool-metrics\\.noetl"; "noetl-worker-lat-metrics.noetl")
  else . end)'
rename() {
  echo ".metadata.name = \"$1\" | del(.metadata.labels) | del(.metadata.annotations) | .spec.replicas = 1
  | .spec.selector = {matchLabels:{app:\"$1\"}} | .spec.template.metadata = {labels:{app:\"$1\", \"noetl-lat\":\"true\"}}
  | .spec.template.spec.volumes = [ (.spec.template.spec.volumes // [])[] | select(.persistentVolumeClaim == null) ]"
}
# Replace every /data mount with an emptyDir (the lat stack is disposable).
data_emptydir='.spec.template.spec.volumes = ([ (.spec.template.spec.volumes // [])[] | select(.name != "lat-data") ] + [{"name":"lat-data","emptyDir":{}}])
  | .spec.template.spec.containers[0].volumeMounts = ([ (.spec.template.spec.containers[0].volumeMounts // [])[] | select(.mountPath | startswith("/data") | not) ] + [{"name":"lat-data","mountPath":"/data"}])'
env_set() {  # env_set NAME VALUE → jq filter that upserts one env var on container 0
  printf '.spec.template.spec.containers[0].env = ([ .spec.template.spec.containers[0].env[] | select(.name != "%s") ] + [{"name":"%s","value":"%s"}])' "$1" "$1" "$2"
}
env_del() { printf '.spec.template.spec.containers[0].env = [ .spec.template.spec.containers[0].env[] | select(.name != "%s") ]' "$1"; }

# Prod's dispatch path (server-rust-embedded-sts-prod.yaml, 2026-11-13).
SERVER_PROD_ENV=(
  NOETL_STATE_BUILDER=offserver
  NOETL_EVENT_INGEST_PUBLISH_ONLY=true
  NOETL_ORCH_RETRIGGER_ON_CLEAR=true
  NOETL_SHARD_SUBJECT_ROUTE=true
  NOETL_EVENT_READ_PATH=event_scan
  NOETL_OFFSERVER_ATTACH_TAIL=false
  NOETL_PERMANENT_LOG_LEAN=true
  NOETL_ORPHAN_SWEEP_ENABLED=true
)

up() {
  : "${SERVER_IMAGE:?set SERVER_IMAGE}"; : "${WORKER_IMAGE:?set WORKER_IMAGE}"
  NODE=${KIND_NODE:-noetl-control-plane}
  for img in "$SERVER_IMAGE" "$WORKER_IMAGE"; do
    podman exec "$NODE" crictl inspecti "$img" >/dev/null 2>&1 || die "$img is not loaded in the kind node"
  done
  mkdir -p "$W/snap"
  for d in noetl-server-rust noetl-worker-rust noetl-worker-system-pool; do
    $K get deploy "$d" -o json | jq "$clean" > "$W/snap/$d.json"
  done
  $K get sts noetl-cmdbus-writer -o json | jq "$clean" > "$W/snap/writer.json"
  for s in noetl-cmdbus-writer-0 noetl-cmdbus-writer-headless; do
    $K get svc "$s" -o json | jq "$clean | del(.spec.clusterIP,.spec.clusterIPs)" > "$W/snap/svc-$s.json"
  done

  echo "== database $DB"
  $PSQL -U "$PG_ADMIN_USER" -d noetl -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1 || true
  $PSQL -U "$PG_ADMIN_USER" -d noetl -c "CREATE DATABASE $DB OWNER noetl" >/dev/null
  $PSQL -U noetl -d "$DB" -c "CREATE SCHEMA IF NOT EXISTS noetl" >/dev/null
  DDL=${SERVER_DDL:-$OPS/../server/db/ddl/postgres/schema_ddl.sql}
  [ -f "$DDL" ] || die "server DDL not found at $DDL (set SERVER_DDL)"
  $PSQL -U noetl -d "$DB" -q -f - < "$DDL" > "$W/ddl.log" 2>&1 || die "DDL: $(tail -3 "$W/ddl.log")"

  echo "== specs"
  jq "$(rename noetl-cmdbus-writer-lat) | .spec.serviceName = \"noetl-cmdbus-writer-lat-headless\" | del(.spec.volumeClaimTemplates)
      | .spec.template.spec.containers[0].image = \"$WORKER_IMAGE\" | $data_emptydir | $to_lat" \
    "$W/snap/writer.json" > "$W/writer-lat.json"
  jq '.metadata.name = "noetl-cmdbus-writer-lat-0" | del(.metadata.labels,.metadata.annotations) | .spec.selector = {app:"noetl-cmdbus-writer-lat"}' \
    "$W/snap/svc-noetl-cmdbus-writer-0.json" > "$W/svc-writer-lat.json"
  jq '.metadata.name = "noetl-cmdbus-writer-lat-headless" | del(.metadata.labels,.metadata.annotations) | .spec.selector = {app:"noetl-cmdbus-writer-lat"} | .spec.clusterIP = "None"' \
    "$W/snap/svc-noetl-cmdbus-writer-headless.json" > "$W/svc-writer-lat-headless.json"

  local f
  f="$(rename noetl-server-lat) | $to_lat | $data_emptydir | .spec.template.spec.containers[0].image = \"$SERVER_IMAGE\""
  # Chain store (chain-pg) belongs to A; the lat stack runs without it.
  f="$f | .spec.template.spec.containers[0].env = [ .spec.template.spec.containers[0].env[] | select(.name | test(\"^NOETL_CHAIN_\") | not) ]"
  f="$f | $(env_set POSTGRES_DATABASE "$DB") | $(env_set NOETL_SERVER_MACHINE_ID 7) | $(env_set NOETL_PUBLIC_SERVER_URL http://noetl-server-lat.noetl.svc.cluster.local:8082)"
  for kv in "${SERVER_PROD_ENV[@]}"; do
    f="$f | $(env_set "${kv%%=*}" "${kv#*=}")"
  done
  jq "$f" "$W/snap/noetl-server-rust.json" > "$W/server-lat.json"

  for pair in noetl-worker-rust:noetl-worker-lat noetl-worker-system-pool:noetl-worker-system-lat; do
    jq "$(rename "${pair#*:}") | .spec.template.spec.containers[0].image = \"$WORKER_IMAGE\" | $to_lat" \
      "$W/snap/${pair%%:*}.json" > "$W/${pair#*:}.json"
  done
  # Metrics: one headless service over both lat pools (scraped by bench.sh).
  for f in svc-writer-lat svc-writer-lat-headless writer-lat server-lat noetl-worker-lat noetl-worker-system-lat; do
    $K apply -f "$W/$f.json" >/dev/null
  done
  $K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: { name: noetl-server-lat }
spec: { selector: { app: noetl-server-lat }, ports: [ { name: http, port: 8082, targetPort: 8082 } ] }
---
apiVersion: v1
kind: Service
metadata: { name: noetl-worker-lat-metrics }
spec: { clusterIP: None, selector: { noetl-lat: "true" }, ports: [ { name: metrics, port: 9090, targetPort: 9090 } ] }
YAML
  if grep -qE 'noetl-cmdbus-writer-0\.noetl|noetl-server-rust\.noetl|http://noetl\.noetl\.svc' "$W"/*-lat.json "$W"/writer-lat.json; then
    die "an A address survived in the lat specs: $(grep -lE 'noetl-cmdbus-writer-0\.noetl|noetl-server-rust\.noetl|http://noetl\.noetl\.svc' "$W"/*lat*.json | xargs -n1 basename | tr '\n' ' ')"
  fi
  [ "${LAT_PROD_RESOURCES:-1}" = 1 ] && prod_resources
  wait_ready
}

wait_ready() {
  $K rollout status sts/noetl-cmdbus-writer-lat --timeout=600s >/dev/null || die "writer rollout"
  for d in $DEPLOYS; do $K rollout status "deploy/$d" --timeout=600s >/dev/null || die "$d rollout"; done
  echo "lat stack ready: $(status_line)"
}

status_line() {
  local s w
  s=$($K get deploy noetl-server-lat -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  w=$($K get deploy noetl-worker-lat -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  echo "server=$s worker=$w"
}

# Prod's pool CPU shape (resource model 2026-11-11; worker-rust-deployment-prod.yaml,
# worker-system-pool-deployment-prod.yaml): user pool 250m request / 2 CPU limit,
# system pool 750m. Kind A's manifests cap the user pool at 500m, and a stage that
# moves work between pools (#558 moves the drive onto the user pool) is then
# measured against a CFS throttle prod does not have (2026-11-14: 250 of 446
# periods throttled in a minute at 500m).
prod_resources() {
  $K get deploy noetl-worker-lat -o json | jq "$clean | .spec.template.spec.containers[0].resources.requests.cpu = \"250m\" | .spec.template.spec.containers[0].resources.limits.cpu = \"2\"" | $K replace -f - >/dev/null
  $K get deploy noetl-worker-system-lat -o json | jq "$clean | .spec.template.spec.containers[0].resources.requests.cpu = \"750m\" | .spec.template.spec.containers[0].resources.limits.cpu = \"750m\"" | $K replace -f - >/dev/null
}

set_cmd() {
  local sp=() wp=() si="" wi=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prod-resources) prod_resources; shift;;
      --server-image) si=$2; shift 2;;
      --worker-image) wi=$2; shift 2;;
      --server-env) sp+=("$2"); shift 2;;
      --worker-env) wp+=("$2"); shift 2;;
      *) die "set: unknown arg $1";;
    esac
  done
  local f d
  if [ -n "$si" ] || [ ${#sp[@]} -gt 0 ]; then
    f="."
    [ -n "$si" ] && f="$f | .spec.template.spec.containers[0].image = \"$si\""
    for kv in ${sp[@]+"${sp[@]}"}; do
      if [ -z "${kv#*=}" ]; then f="$f | $(env_del "${kv%%=*}")"; else f="$f | $(env_set "${kv%%=*}" "${kv#*=}")"; fi
    done
    $K get deploy noetl-server-lat -o json | jq "$clean | $f" | $K replace -f - >/dev/null
  fi
  if [ -n "$wi" ] || [ ${#wp[@]} -gt 0 ]; then
    f="."
    [ -n "$wi" ] && f="$f | .spec.template.spec.containers[0].image = \"$wi\""
    for kv in ${wp[@]+"${wp[@]}"}; do
      if [ -z "${kv#*=}" ]; then f="$f | $(env_del "${kv%%=*}")"; else f="$f | $(env_set "${kv%%=*}" "${kv#*=}")"; fi
    done
    for d in noetl-worker-lat noetl-worker-system-lat; do
      $K get deploy "$d" -o json | jq "$clean | $f" | $K replace -f - >/dev/null
    done
    if [ -n "$wi" ]; then
      $K get sts noetl-cmdbus-writer-lat -o json | jq "$clean | .spec.template.spec.containers[0].image = \"$wi\"" | $K replace -f - >/dev/null
    fi
  fi
  wait_ready
}

down() {
  # shellcheck disable=SC2086
  $K delete $LAT_OBJECTS svc/noetl-worker-lat-metrics --ignore-not-found >/dev/null 2>&1 || true
  $PSQL -U "$PG_ADMIN_USER" -d noetl -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1 && echo "dropped $DB" || echo "!! $DB not dropped"
  echo "lat stack removed"
}

case "${1:-}" in
  up) up;;
  set) shift; set_cmd "$@";;
  status) status_line; $K get pods -l noetl-lat=true -o wide; $K get pods -l app=noetl-cmdbus-writer-lat;;
  down) down;;
  *) sed -n '2,30p' "$0"; exit 2;;
esac
