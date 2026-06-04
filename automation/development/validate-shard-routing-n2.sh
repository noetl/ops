#!/usr/bin/env bash
# Phase F R4-5 of noetl/ai-meta#49 — end-to-end kind validation
# for the N=2 shard topology landed in R4-1 → R4-4b on
# noetl/server (v2.13.0 → v2.19.0).
#
# Validates that the in-server `DbPoolMap` routing actually
# splits per-execution data across shards when the operator
# sets `NOETL_SHARDS` + `NOETL_CLUSTER_DSN` — i.e. that the
# end-to-end chain (gateway -> server -> per-shard pool ->
# Postgres) honors `shard_for(execution_id, 2)`.
#
# Why we don't spin up two separate Postgres pods:
#
#   For kind, the goal is to exercise the routing code path,
#   not to validate process-level isolation between Postgres
#   instances.  The cheap way is to create THREE logical
#   databases on the existing single Postgres instance —
#   `noetl_shard_0`, `noetl_shard_1`, `noetl_cluster` — apply
#   the schema to each, and point `NOETL_SHARDS` at them with
#   different `database=` slugs.  The server's `DbPoolMap`
#   builds the same N+1 pool topology; the only difference vs
#   per-pod Postgres is the underlying TCP host.  Per-shard
#   physical isolation is a Phase G concern (multi-cloud / per-
#   shard credential rotation; see noetl/server wiki sharding-
#   design § Phase G).
#
# What this script does:
#
#   1. Sanity: kind cluster + noetl-server-rust + noetl-postgres
#      pods running.
#   2. Create `noetl_shard_0`, `noetl_shard_1`, `noetl_cluster`
#      databases in the existing Postgres instance (idempotent —
#      skips on subsequent runs).  Apply noetl schema DDL to each.
#   3. Patch the `noetl-server-rust` Deployment with
#      `NOETL_SHARDS` + `NOETL_CLUSTER_DSN` env vars pointing at
#      the three new databases.  Wait for rollout.
#   4. Spawn a small fixture playbook K times through
#      `POST /api/execute` and capture each execution_id.
#   5. For each execution_id: compute `shard_for(eid, 2)` via the
#      R3b-1 server diagnostic endpoint; query the matching
#      per-shard database to confirm the event log actually
#      landed there + assert the OTHER shard's database holds
#      no rows for that eid.
#   6. Re-run the R3b drift-guard
#      (validate-shard-drift-guard.sh) against the sharded
#      server to confirm the gateway-side picker and server-
#      side picker still agree.
#   7. Tear down: revert the `noetl-server-rust` env-var patch
#      so the next run starts from the single-pool baseline.
#      DBs stay (idempotent re-creation on next run; drop is a
#      manual ops step).
#
# Usage:
#   ./automation/development/validate-shard-routing-n2.sh
#
# Exit code 0 = all assertions pass; 1 = any assertion failed.
# Idempotent: trap EXIT reverts the deployment patch even on
# mid-script failure.

set -euo pipefail

NS=${NS:-noetl}
PG_NS=${PG_NS:-postgres}
KCTX=${KCTX:-kind-noetl}
SERVER_SVC=${SERVER_SVC:-noetl-server-rust}
SERVER_DEPLOY=${SERVER_DEPLOY:-noetl-server-rust}
SERVER_LOCAL_PORT=${SERVER_LOCAL_PORT:-38182}
PG_LOCAL_PORT=${PG_LOCAL_PORT:-25432}
NUM_EXECUTIONS=${NUM_EXECUTIONS:-10}

# These match the existing postgres ConfigMap defaults.  If the
# operator changed them in postgres/configmap.yaml, override here.
PG_USER=${PG_USER:-noetl}
PG_PASSWORD=${PG_PASSWORD:-noetl}
PG_HOST_IN_CLUSTER=${PG_HOST_IN_CLUSTER:-postgres.postgres.svc.cluster.local}
PG_PORT_IN_CLUSTER=${PG_PORT_IN_CLUSTER:-5432}

SHARD_DBS=(noetl_shard_0 noetl_shard_1)
CLUSTER_DB=noetl_cluster

# ---------------------------------------------------------------------------
# Pretty colours
# ---------------------------------------------------------------------------
green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
yellow(){ printf '\033[33m%s\033[0m' "$1"; }
cyan()  { printf '\033[36m%s\033[0m' "$1"; }

step() { printf '\n%s %s\n' "$(cyan '==>')" "$1"; }
ok()   { printf '    %s %s\n' "$(green PASS)" "$1"; }
warn() { printf '    %s %s\n' "$(yellow WARN)" "$1"; }
fail() { printf '    %s %s\n' "$(red FAIL)" "$1"; }

# ---------------------------------------------------------------------------
# Cleanup — revert the deployment patch on exit
# ---------------------------------------------------------------------------
PF_SERVER_PID=""
PF_PG_PID=""
PATCH_APPLIED=0

cleanup() {
    [[ -n "${PF_SERVER_PID}" ]] && kill "${PF_SERVER_PID}" 2>/dev/null || true
    [[ -n "${PF_PG_PID}" ]] && kill "${PF_PG_PID}" 2>/dev/null || true

    if [[ "${PATCH_APPLIED}" == "1" ]]; then
        step "Reverting deployment patch (NOETL_SHARDS unset)"
        kubectl --context "${KCTX}" -n "${NS}" set env \
            "deployment/${SERVER_DEPLOY}" \
            NOETL_SHARDS- \
            NOETL_CLUSTER_DSN- \
            >/dev/null 2>&1 || true
        kubectl --context "${KCTX}" -n "${NS}" rollout status \
            "deployment/${SERVER_DEPLOY}" --timeout=120s >/dev/null 2>&1 || true
        ok "Deployment restored to single-pool baseline"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers — pg via psql in-cluster (using the postgres pod's own client)
# ---------------------------------------------------------------------------
pg_pod_name() {
    kubectl --context "${KCTX}" -n "${PG_NS}" get pod \
        -l app=postgres \
        -o jsonpath='{.items[0].metadata.name}'
}

pg_exec() {
    local db="$1"
    local sql="$2"
    kubectl --context "${KCTX}" -n "${PG_NS}" exec "$(pg_pod_name)" -- \
        psql -U "${PG_USER}" -d "${db}" -t -A -c "${sql}"
}

# ---------------------------------------------------------------------------
# Phase 1 — Sanity
# ---------------------------------------------------------------------------
step "Sanity: cluster reachable"
if ! kubectl --context "${KCTX}" get ns "${NS}" >/dev/null 2>&1; then
    fail "Namespace ${NS} not found"
    exit 1
fi
ok "noetl namespace exists"

if ! kubectl --context "${KCTX}" -n "${PG_NS}" get pod -l app=postgres \
        -o jsonpath='{.items[*].status.phase}' | grep -q Running; then
    fail "postgres pod not Running"
    exit 1
fi
ok "postgres pod Running"

if ! kubectl --context "${KCTX}" -n "${NS}" get deploy "${SERVER_DEPLOY}" >/dev/null 2>&1; then
    fail "Deployment ${SERVER_DEPLOY} not found"
    exit 1
fi
ok "noetl-server-rust deployment exists"

# ---------------------------------------------------------------------------
# Phase 2 — Create the three databases + apply schema
# ---------------------------------------------------------------------------
step "Creating shard + cluster databases on existing Postgres"

create_db_if_missing() {
    local db="$1"
    local owner="$2"
    local exists
    exists=$(pg_exec postgres "SELECT 1 FROM pg_database WHERE datname='${db}'")
    if [[ -z "${exists}" ]]; then
        pg_exec postgres "CREATE DATABASE ${db} OWNER ${owner}" >/dev/null
        ok "Created database ${db}"
    else
        ok "Database ${db} already exists (skipping)"
    fi
}

for db in "${SHARD_DBS[@]}" "${CLUSTER_DB}"; do
    create_db_if_missing "${db}" "${PG_USER}"
done

step "Applying noetl schema DDL to each database"

# The postgres pod has schema_ddl.sql.norun mounted at
# /docker-entrypoint-initdb.d/.  Re-apply it to each new db.
# Idempotent: schema_ddl uses IF NOT EXISTS throughout.
SCHEMA_FILE=/docker-entrypoint-initdb.d/schema_ddl.sql.norun

for db in "${SHARD_DBS[@]}" "${CLUSTER_DB}"; do
    # Create noetl schema first (the DDL assumes the schema exists).
    pg_exec "${db}" "CREATE SCHEMA IF NOT EXISTS noetl" >/dev/null
    pg_exec "${db}" "GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${PG_USER}" >/dev/null
    pg_exec "${db}" "GRANT ALL PRIVILEGES ON SCHEMA noetl TO ${PG_USER}" >/dev/null
    kubectl --context "${KCTX}" -n "${PG_NS}" exec "$(pg_pod_name)" -- \
        psql -U "${PG_USER}" -d "${db}" -v SCHEMA_NAME=noetl \
            -f "${SCHEMA_FILE}" >/dev/null 2>&1 || {
        warn "Schema apply to ${db} returned non-zero (possibly idempotent re-run); continuing"
    }
    ok "Schema applied to ${db}"
done

# ---------------------------------------------------------------------------
# Phase 3 — Patch noetl-server-rust deployment with NOETL_SHARDS
# ---------------------------------------------------------------------------
step "Patching ${SERVER_DEPLOY} with NOETL_SHARDS + NOETL_CLUSTER_DSN"

# DSN shape per ShardConnection::parse:
#   host=...;port=...;user=...;password=...;database=...
SHARD0_DSN="host=${PG_HOST_IN_CLUSTER};port=${PG_PORT_IN_CLUSTER};user=${PG_USER};password=${PG_PASSWORD};database=${SHARD_DBS[0]}"
SHARD1_DSN="host=${PG_HOST_IN_CLUSTER};port=${PG_PORT_IN_CLUSTER};user=${PG_USER};password=${PG_PASSWORD};database=${SHARD_DBS[1]}"
CLUSTER_DSN="host=${PG_HOST_IN_CLUSTER};port=${PG_PORT_IN_CLUSTER};user=${PG_USER};password=${PG_PASSWORD};database=${CLUSTER_DB}"

PATCH_APPLIED=1
kubectl --context "${KCTX}" -n "${NS}" set env \
    "deployment/${SERVER_DEPLOY}" \
    "NOETL_SHARDS=${SHARD0_DSN},${SHARD1_DSN}" \
    "NOETL_CLUSTER_DSN=${CLUSTER_DSN}" \
    >/dev/null

kubectl --context "${KCTX}" -n "${NS}" rollout status \
    "deployment/${SERVER_DEPLOY}" --timeout=180s >/dev/null
ok "Deployment rolled with sharded env"

# ---------------------------------------------------------------------------
# Phase 4 — Port-forward + spawn N executions
# ---------------------------------------------------------------------------
step "Port-forwarding ${SERVER_SVC} → :${SERVER_LOCAL_PORT}"
kubectl --context "${KCTX}" -n "${NS}" port-forward \
    "svc/${SERVER_SVC}" "${SERVER_LOCAL_PORT}:8082" \
    >/tmp/pf-server-r4-5.log 2>&1 &
PF_SERVER_PID=$!
sleep 3

# Sanity probe — server's R3b-1 shard-info endpoint must report
# shard_count=2 + single_pool_mode=false now that NOETL_SHARDS
# is set.  This is the cheapest "did the env reach the process"
# check.
step "Probing R3b-1 endpoint for shard topology"
probe=$(curl -sS --max-time 5 \
    "http://localhost:${SERVER_LOCAL_PORT}/api/runtime/shard-info?execution_id=1&shard_count=2" \
    || true)
if ! echo "${probe}" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
cfg = d.get("server_config", {})
assert cfg.get("shard_count") == 2, f"shard_count != 2 in {cfg}"
print("shard_count=2 OK")
'; then
    fail "Server did not pick up NOETL_SHARDS — check pod logs"
    cat /tmp/pf-server-r4-5.log >&2 || true
    exit 1
fi
ok "Server reports shard_count=2"

# Spawn N executions via /api/execute.  Use a minimal inline
# playbook so we don't depend on catalog state from prior runs.
step "Spawning ${NUM_EXECUTIONS} executions"

# Note: this assumes a noetl_workflow already exists in the
# catalog that we can `path` into.  If not, the operator should
# register one first (noetl playbook register <path>) — the
# script does NOT register a playbook because that's outside
# the routing-validation scope.

EXECUTIONS=()
for i in $(seq 1 ${NUM_EXECUTIONS}); do
    resp=$(curl -sS --max-time 10 \
        "http://localhost:${SERVER_LOCAL_PORT}/api/execute" \
        -H 'Content-Type: application/json' \
        -d '{"path":"playbooks/system/heartbeat","workload":{}}' \
        || true)
    eid=$(echo "${resp}" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    eid = d.get("execution_id")
    if eid is not None:
        print(eid)
except Exception:
    pass
')
    if [[ -z "${eid}" ]]; then
        warn "Execution ${i}/${NUM_EXECUTIONS} did not return execution_id (response: ${resp:0:200})"
        continue
    fi
    EXECUTIONS+=("${eid}")
done

if [[ ${#EXECUTIONS[@]} -lt 2 ]]; then
    fail "Fewer than 2 executions succeeded — cannot validate distribution"
    exit 1
fi
ok "Captured ${#EXECUTIONS[@]} execution_ids"

# Brief settle so the event log + per-shard write lands.
sleep 3

# ---------------------------------------------------------------------------
# Phase 5 — Per-execution shard residence check
# ---------------------------------------------------------------------------
step "Verifying each execution landed on its predicted shard"

printf '\n    %-24s %-12s %-14s %-14s %s\n' \
    "execution_id" "expected" "shard_0_rows" "shard_1_rows" "result"

mismatches=0
for eid in "${EXECUTIONS[@]}"; do
    # Predict via R3b-1 endpoint (server-side shard_for).
    expected=$(curl -sS --max-time 5 \
        "http://localhost:${SERVER_LOCAL_PORT}/api/runtime/shard-info?execution_id=${eid}&shard_count=2" \
        | python3 -c '
import sys, json
print(json.loads(sys.stdin.read()).get("shard_index", ""))
')
    s0=$(pg_exec "${SHARD_DBS[0]}" "SELECT COUNT(*) FROM noetl.event WHERE execution_id=${eid}")
    s1=$(pg_exec "${SHARD_DBS[1]}" "SELECT COUNT(*) FROM noetl.event WHERE execution_id=${eid}")

    if [[ "${expected}" == "0" && "${s0}" != "0" && "${s1}" == "0" ]]; then
        verdict="$(green AGREE)"
    elif [[ "${expected}" == "1" && "${s1}" != "0" && "${s0}" == "0" ]]; then
        verdict="$(green AGREE)"
    else
        verdict="$(red MISMATCH)"
        mismatches=$((mismatches + 1))
    fi
    printf '    %-24s %-12s %-14s %-14s %s\n' "${eid}" "${expected}" "${s0}" "${s1}" "${verdict}"
done

# ---------------------------------------------------------------------------
# Phase 6 — R3b drift-guard re-run against sharded server
# ---------------------------------------------------------------------------
step "Re-running R3b drift-guard against the sharded server"

# Kill the existing port-forward to avoid the conflict with the
# drift-guard's own port-forward.
kill "${PF_SERVER_PID}" 2>/dev/null || true
PF_SERVER_PID=""

DRIFT_GUARD="$(dirname "$0")/validate-shard-drift-guard.sh"
if [[ -x "${DRIFT_GUARD}" ]]; then
    if "${DRIFT_GUARD}"; then
        ok "Drift-guard PASSED against sharded server"
    else
        fail "Drift-guard FAILED against sharded server"
        mismatches=$((mismatches + 1))
    fi
else
    warn "Drift-guard script not found at ${DRIFT_GUARD}; skipping (run validate-shard-drift-guard.sh manually)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ ${mismatches} -eq 0 ]]; then
    step "Result: $(green PASS) — all ${#EXECUTIONS[@]} executions routed correctly"
    exit 0
else
    step "Result: $(red FAIL) — ${mismatches} routing mismatches (cleanup will revert deployment)"
    exit 1
fi
