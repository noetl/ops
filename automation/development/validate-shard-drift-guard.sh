#!/usr/bin/env bash
# Phase F R3b-3 of noetl/ai-meta#49 — end-to-end shard-routing
# drift-guard.
#
# Posts to BOTH the noetl-server shard-info endpoint
# (`GET /api/runtime/shard-info`, R3b-1 / server v2.12.0) and the
# noetl-gateway twin endpoint (`GET /sharding/preview`, R3b-2 /
# gateway v3.2.0) across a battery of (execution_id, shard_count)
# pairs.  Asserts the `shard_index` field agrees between the two
# sources.
#
# Catches runtime drift the unit-test pinning on either side
# can't see:
#   - One side's `twox-hash` crate version bumped without the
#     other's.
#   - One side's `SHARD_HASH_SEED` constant drifted while its
#     test suite still passes in isolation.
#   - i64 → bytes encoding diverged (LE vs BE).
#   - The hash function silently changed (e.g. crate's internal
#     algorithm rev with no major-version bump).
#
# Usage:
#   ./automation/development/validate-shard-drift-guard.sh
#
# Exit code 0 = all pairs agree.  Exit code 1 = at least one
# mismatch (or a transport error reaching one endpoint).
#
# Idempotent: cleans up port-forwards on exit (trap EXIT).

set -euo pipefail

NS=${NS:-noetl}
KCTX=${KCTX:-kind-noetl}
SERVER_SVC=${SERVER_SVC:-noetl-server-rust}
GATEWAY_SVC=${GATEWAY_SVC:-noetl-gateway}
SERVER_LOCAL_PORT=${SERVER_LOCAL_PORT:-38182}
GATEWAY_LOCAL_PORT=${GATEWAY_LOCAL_PORT:-38190}

# ---------------------------------------------------------------------------
# Pretty colours
# ---------------------------------------------------------------------------
green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
yellow(){ printf '\033[33m%s\033[0m' "$1"; }
cyan()  { printf '\033[36m%s\033[0m' "$1"; }

step() {
    printf '\n%s %s\n' "$(cyan '==>')" "$1"
}

ok()   { printf '    %s %s\n' "$(green PASS)" "$1"; }
warn() { printf '    %s %s\n' "$(yellow WARN)" "$1"; }
fail() { printf '    %s %s\n' "$(red FAIL)" "$1"; }

# ---------------------------------------------------------------------------
# Battery of (execution_id, shard_count) pairs.
# ---------------------------------------------------------------------------
# execution_ids: a mix of small + canonical (R1.5 kind-val ID) +
# extreme values to exercise the i64 range.
EXECUTION_IDS=(
    "1"
    "42"
    "9999999999"
    "320816801799737344"
    "9223372036854775807"
    "-1"
)
# shard_counts: powers of two + the practical maximum (1024 =
# 2^10, matching the snowflake machine_id ceiling).
SHARD_COUNTS=(
    "2"
    "4"
    "16"
    "64"
    "1024"
)

# ---------------------------------------------------------------------------
# Cleanup — kill port-forwards on exit.
# ---------------------------------------------------------------------------
PF_SERVER_PID=""
PF_GATEWAY_PID=""

cleanup() {
    if [[ -n "${PF_SERVER_PID}" ]]; then
        kill "${PF_SERVER_PID}" 2>/dev/null || true
    fi
    if [[ -n "${PF_GATEWAY_PID}" ]]; then
        kill "${PF_GATEWAY_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Sanity — both Services + Deployments must exist.
# ---------------------------------------------------------------------------
step "Sanity: noetl-server-rust + noetl-gateway reachable"

if ! kubectl --context "${KCTX}" -n "${NS}" get svc "${SERVER_SVC}" >/dev/null 2>&1; then
    fail "Service '${SERVER_SVC}' not found in namespace '${NS}'"
    exit 1
fi
ok "Service ${SERVER_SVC} exists"

if ! kubectl --context "${KCTX}" -n "${NS}" get svc "${GATEWAY_SVC}" >/dev/null 2>&1; then
    fail "Service '${GATEWAY_SVC}' not found in namespace '${NS}'"
    exit 1
fi
ok "Service ${GATEWAY_SVC} exists"

# ---------------------------------------------------------------------------
# Port-forward both services.
# ---------------------------------------------------------------------------
step "Port-forwarding ${SERVER_SVC} → :${SERVER_LOCAL_PORT}"
kubectl --context "${KCTX}" -n "${NS}" port-forward \
    "svc/${SERVER_SVC}" "${SERVER_LOCAL_PORT}:8082" \
    >/tmp/pf-server.log 2>&1 &
PF_SERVER_PID=$!

step "Port-forwarding ${GATEWAY_SVC} → :${GATEWAY_LOCAL_PORT}"
kubectl --context "${KCTX}" -n "${NS}" port-forward \
    "svc/${GATEWAY_SVC}" "${GATEWAY_LOCAL_PORT}:8090" \
    >/tmp/pf-gateway.log 2>&1 &
PF_GATEWAY_PID=$!

# Give port-forwards a moment to bind.
sleep 3

# ---------------------------------------------------------------------------
# Probe — basic reachability before running the full battery.
# ---------------------------------------------------------------------------
step "Probing endpoints"

# Server endpoint: known-good (eid=1, N=2) should return 200
# with a shard_index field.
PROBE_SERVER=$(curl -sS --max-time 5 \
    "http://localhost:${SERVER_LOCAL_PORT}/api/runtime/shard-info?execution_id=1&shard_count=2" \
    || true)
if ! echo "${PROBE_SERVER}" | grep -q 'shard_index'; then
    fail "server probe failed; response: ${PROBE_SERVER}"
    cat /tmp/pf-server.log >&2
    exit 1
fi
ok "server endpoint responding"

PROBE_GATEWAY=$(curl -sS --max-time 5 \
    "http://localhost:${GATEWAY_LOCAL_PORT}/sharding/preview?execution_id=1&shard_count=2" \
    || true)
if ! echo "${PROBE_GATEWAY}" | grep -q 'shard_index'; then
    fail "gateway probe failed; response: ${PROBE_GATEWAY}"
    cat /tmp/pf-gateway.log >&2
    exit 1
fi
ok "gateway endpoint responding"

# ---------------------------------------------------------------------------
# Battery — iterate (eid, N) pairs, compare shard_index.
# ---------------------------------------------------------------------------
step "Comparing shard_index across $(( ${#EXECUTION_IDS[@]} * ${#SHARD_COUNTS[@]} )) pairs"

# Pre-print the header.
printf '\n    %-22s %-12s %-14s %-14s %s\n' \
    "execution_id" "shard_count" "server.idx" "gateway.idx" "result"

MISMATCH_COUNT=0
TOTAL_COUNT=0

extract_shard_index() {
    # Parse the top-level `shard_index` from JSON via python.
    # The server's response also contains a nested
    # `server_config.shard_index` field (the deployment topology),
    # so we MUST use a real JSON parser — a regex would match
    # the wrong field on the server response.  python3 is the
    # universal dev-box parser; no jq dependency.
    python3 -c '
import sys, json
try:
    d = json.loads(sys.argv[1])
    print(d.get("shard_index", ""))
except Exception:
    print("")
' "$1"
}

for eid in "${EXECUTION_IDS[@]}"; do
    for n in "${SHARD_COUNTS[@]}"; do
        TOTAL_COUNT=$((TOTAL_COUNT + 1))

        server_resp=$(curl -sS --max-time 5 \
            "http://localhost:${SERVER_LOCAL_PORT}/api/runtime/shard-info?execution_id=${eid}&shard_count=${n}" \
            || echo "{}")
        gateway_resp=$(curl -sS --max-time 5 \
            "http://localhost:${GATEWAY_LOCAL_PORT}/sharding/preview?execution_id=${eid}&shard_count=${n}" \
            || echo "{}")

        server_idx=$(extract_shard_index "${server_resp}")
        gateway_idx=$(extract_shard_index "${gateway_resp}")

        if [[ -z "${server_idx}" ]] || [[ -z "${gateway_idx}" ]]; then
            printf '    %-22s %-12s %-14s %-14s %s\n' \
                "${eid}" "${n}" "${server_idx:-<missing>}" "${gateway_idx:-<missing>}" \
                "$(red TRANSPORT-ERR)"
            MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
            continue
        fi

        if [[ "${server_idx}" == "${gateway_idx}" ]]; then
            printf '    %-22s %-12s %-14s %-14s %s\n' \
                "${eid}" "${n}" "${server_idx}" "${gateway_idx}" "$(green AGREE)"
        else
            printf '    %-22s %-12s %-14s %-14s %s\n' \
                "${eid}" "${n}" "${server_idx}" "${gateway_idx}" "$(red MISMATCH)"
            MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
        fi
    done
done

printf '\n'

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
if [[ ${MISMATCH_COUNT} -eq 0 ]]; then
    step "Result: $(green PASS) — all ${TOTAL_COUNT} pairs agree"
    exit 0
else
    step "Result: $(red FAIL) — ${MISMATCH_COUNT} of ${TOTAL_COUNT} pairs disagree"
    cat <<'EOF'

Drift detected.  Likely causes:

  1. One side's twox-hash crate version moved without the other's.
     Check the Cargo.lock entries in noetl-server and noetl-gateway.
  2. One side's SHARD_HASH_SEED constant changed.  Check
     repos/server/src/sharding.rs and repos/gateway/src/sharding.rs.
  3. The i64 → bytes encoding diverged (LE vs BE).  Both sides
     MUST use to_le_bytes().
  4. The hash crate's internal algorithm changed with a non-major
     bump (unlikely with twox-hash 1.6 but possible).

Repro the drift-guard locally without the cluster:
  cd repos/server  && cargo test --quiet --lib sharding::
  cd repos/gateway && cargo test --quiet sharding::

Both pin (eid, N) → shard expected values.  If one side passes
and the other fails, the drift is in the failing side.  If both
pass but this integration test still mismatches, the drift is in
the deployed dependency (re-run `cargo update` on both sides).
EOF
    exit 1
fi
