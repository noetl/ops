#!/usr/bin/env bash
# Phase 5 (Leg 1) of noetl/ai-meta#166 — end-to-end kind validation
# for SERVER-ROUTED PER-SHARD COMMAND PUBLISH.
#
# noetl/ai-meta#166 makes the off-server state_builder cache shardable:
# each system-pool drive replica owns a shard range and keeps those
# executions warm.  Phase 4 (worker-side, LIVE on prod) steers a drive
# hop that lands on the wrong replica to the owner via a NAK redirect —
# ~1 redirect per drive at 2 shards.  Phase 5 Leg 1 (server v3.51.0,
# `NOETL_SHARD_SUBJECT_ROUTE`) removes that redirect tax by publishing an
# execution's system-pool commands straight to a per-shard subject the
# owning replica's consumer filters for.
#
# Merged server code (`src/sharding.rs::command_subject`):
#   legacy   : noetl.commands.<pool>.<execution_id>
#   sharded  : noetl.commands.<pool>.shard.<n>.<execution_id>
#              n = shard_for(execution_id, NOETL_COMMAND_SHARD_COUNT)
#   routed iff  shard_route ON  &&  count > 1  &&  pool == "system"
#
# The sharded subject is a SUBTREE of the legacy pool wildcard
# `noetl.commands.<pool>.>` — this "subject subsumption" is the safety
# property: a replica still bound to the broad filter (a fleet mid-
# rollout, or a shard with no dedicated consumer) STILL receives the
# shard-routed command and degrades to the Phase-4 NAK path, so a wrong
# route never drops a hop.  `claim_command` atomicity stays the single
# exactly-once gate.
#
# WHAT THIS SCRIPT PROVES (default mode — NON-DISRUPTIVE, no server or
# worker change, no rebuild):
#
#   Phase 0  preconditions: kind + server + NATS reachable; the
#            NOETL_COMMANDS stream captures the shard subtree and uses
#            `limits` retention (so per-shard + broad consumers coexist).
#   Phase 1  hash parity: the live server's `/api/runtime/shard-info`
#            (the SAME `shard_for` `command_subject` calls) matches the
#            cross-repo pinned vectors, so a per-shard consumer filter
#            `…shard.<n>.>` catches exactly the eids the server routes
#            to shard n.
#   Phase 2  real-JetStream subsumption + per-shard isolation: create
#            additive per-shard + broad pull consumers on the LIVE
#            stream under an ISOLATED synthetic pool token (default
#            `shardtest166`, never `system`) so the live system worker's
#            consumer never sees test traffic, publish to real shard/
#            legacy subjects, and assert delivery routing.
#
# WHAT THIS SCRIPT DOES NOT DO BY DEFAULT:
#
#   Phase 3  (gated behind `--enable-server-route`) flips
#            `NOETL_SHARD_SUBJECT_ROUTE=true` + `NOETL_COMMAND_SHARD_COUNT`
#            on the LIVE server (one rolling restart) and drives a real
#            system-pool execution to observe the REAL publish path.
#            This is Mode A of the human-gated prod rollout; it mutates
#            a shared deployment, so it is OFF by default and refuses to
#            run unless the flag is passed.  Rollback is a single
#            `kubectl set env … NOETL_SHARD_SUBJECT_ROUTE-` (printed).
#
# Why an isolated synthetic pool for Phase 2: publishing to the real
# `noetl.commands.system.*` subtree would be delivered to the live
# `noetl_worker_pool_system` consumer (filter `noetl.commands.system.>`),
# which would try to process a bogus command.  The subject-tree mechanics
# this phase validates (subtree subsumption, `.shard.<n>.>` isolation)
# are pool-token-agnostic, so substituting the pool token isolates the
# test from every real worker while proving the identical routing shape.
#
# Usage:
#   ./automation/development/validate-shard-command-publish-166.sh
#   ./automation/development/validate-shard-command-publish-166.sh --enable-server-route   # gated Mode A
#
# Exit 0 = all run phases passed.  Exit 1 = a precondition or assertion
# failed.  Idempotent: unique per-run nonce subjects + trap-EXIT cleanup
# of every consumer and port-forward it creates.
#
# Env overrides: NS, KCTX, SERVER_SVC, NATS_NS, NATS_POD, STREAM,
# TEST_POOL, SERVER_LOCAL_PORT, NATS_LOCAL_PORT.

set -euo pipefail

NS=${NS:-noetl}
KCTX=${KCTX:-kind-noetl}
SERVER_SVC=${SERVER_SVC:-noetl-server-rust}
NATS_NS=${NATS_NS:-nats}
NATS_POD=${NATS_POD:-nats-0}
STREAM=${STREAM:-NOETL_COMMANDS}
TEST_POOL=${TEST_POOL:-shardtest166}
SERVER_LOCAL_PORT=${SERVER_LOCAL_PORT:-38182}
NATS_LOCAL_PORT=${NATS_LOCAL_PORT:-34222}
NATS_USER=${NATS_USER:-noetl}
NATS_PASS=${NATS_PASS:-noetl}

ENABLE_SERVER_ROUTE=0
for arg in "$@"; do
    case "$arg" in
        --enable-server-route) ENABLE_SERVER_ROUTE=1 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Pretty colours (match validate-shard-drift-guard.sh)
# ---------------------------------------------------------------------------
green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
yellow(){ printf '\033[33m%s\033[0m' "$1"; }
cyan()  { printf '\033[36m%s\033[0m' "$1"; }
step()  { printf '\n%s %s\n' "$(cyan '==>')" "$1"; }
ok()    { printf '    %s %s\n' "$(green PASS)" "$1"; }
warn()  { printf '    %s %s\n' "$(yellow WARN)" "$1"; }
fail()  { printf '    %s %s\n' "$(red FAIL)" "$1"; }

FAILURES=0
note_fail() { FAILURES=$((FAILURES + 1)); fail "$1"; }

# Per-run nonce so replayed/historical test messages never collide with
# this run's assertions.  `date` in a shell is fine here (this is not the
# JS workflow engine).
NONCE="$(date +%s)$$"

# ---------------------------------------------------------------------------
# Cleanup — kill port-forwards + delete any consumer we created.
# ---------------------------------------------------------------------------
PF_SERVER_PID=""
PF_NATS_PID=""
CREATED_CONSUMERS=()

nats_cli() { nats --server "nats://${NATS_USER}:${NATS_PASS}@127.0.0.1:${NATS_LOCAL_PORT}" "$@"; }

cleanup() {
    for c in "${CREATED_CONSUMERS[@]:-}"; do
        [[ -n "$c" ]] && nats_cli consumer rm "${STREAM}" "$c" -f >/dev/null 2>&1 || true
    done
    [[ -n "${PF_SERVER_PID}" ]] && kill "${PF_SERVER_PID}" 2>/dev/null || true
    [[ -n "${PF_NATS_PID}" ]]   && kill "${PF_NATS_PID}"   2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Phase 0 — preconditions.
# ---------------------------------------------------------------------------
step "Phase 0: preconditions (server + NATS reachable, stream shape)"

command -v nats >/dev/null 2>&1 || { fail "the 'nats' CLI is required (brew install nats-io/nats-tools/nats)"; exit 1; }

kubectl --context "${KCTX}" -n "${NS}" get svc "${SERVER_SVC}" >/dev/null 2>&1 \
    || { fail "Service ${SERVER_SVC} not found in ns ${NS}"; exit 1; }
ok "Service ${SERVER_SVC} exists"

kubectl --context "${KCTX}" -n "${NATS_NS}" get pod "${NATS_POD}" >/dev/null 2>&1 \
    || { fail "NATS pod ${NATS_POD} not found in ns ${NATS_NS}"; exit 1; }
ok "NATS pod ${NATS_POD} exists"

kubectl --context "${KCTX}" -n "${NS}" port-forward "svc/${SERVER_SVC}" \
    "${SERVER_LOCAL_PORT}:8082" >/tmp/pf-166-server.log 2>&1 &
PF_SERVER_PID=$!
kubectl --context "${KCTX}" -n "${NATS_NS}" port-forward "pod/${NATS_POD}" \
    "${NATS_LOCAL_PORT}:4222" >/tmp/pf-166-nats.log 2>&1 &
PF_NATS_PID=$!
sleep 3

curl -sS --max-time 5 \
    "http://localhost:${SERVER_LOCAL_PORT}/api/runtime/shard-info?execution_id=1&shard_count=2" \
    | grep -q 'shard_index' \
    || { fail "server /api/runtime/shard-info not responding"; cat /tmp/pf-166-server.log >&2; exit 1; }
ok "server /api/runtime/shard-info responding"

STREAM_JSON=$(nats_cli stream info "${STREAM}" --json 2>/dev/null || echo '{}')
STREAM_RC=0
python3 - "$STREAM_JSON" <<'PY' || STREAM_RC=$?
import sys, json
d = json.loads(sys.argv[1] or "{}")
cfg = d.get("config", {})
subs = cfg.get("subjects", [])
ret = cfg.get("retention", "")
# The shard subtree noetl.commands.<pool>.shard.<n>.<eid> must be captured
# by a stream subject, and retention must be `limits` (not workqueue) so a
# per-shard consumer + a broad consumer can BOTH receive the same message.
captured = any(s in ("noetl.commands.>", ">") for s in subs)
print(f"subjects={subs} retention={ret}")
sys.exit(0 if (captured and ret == "limits") else 3)
PY
if [[ ${STREAM_RC} -eq 0 ]]; then
    ok "stream ${STREAM} captures the shard subtree + retention=limits (rollout precondition)"
else
    note_fail "stream ${STREAM} does NOT capture the shard subtree or is not retention=limits — Phase 5 rollout precondition unmet"
fi

# ---------------------------------------------------------------------------
# Phase 1 — hash parity: the server's shard_for == command_subject's shard.
# ---------------------------------------------------------------------------
step "Phase 1: hash parity — /api/runtime/shard-info vs command_subject pins"

# (eid, count, expected_shard) — pinned cross-repo parity vectors from the
# server Phase-5 unit tests (src/sharding.rs):
#   command_subject("system", 325, true, 8) == noetl.commands.system.shard.4.325
#   shard_for(320816801799737344, 16) == 14  (worker/server shared pin)
PARITY_VECTORS=(
    "325 8 4"
    "320816801799737344 16 14"
    "1 2 -"
    "42 4 -"
)
printf '\n    %-22s %-8s %-10s %-10s %s\n' "execution_id" "count" "expected" "server" "subject a shard-<n> consumer catches"
for v in "${PARITY_VECTORS[@]}"; do
    read -r eid count expected <<<"$v"
    resp=$(curl -sS --max-time 5 \
        "http://localhost:${SERVER_LOCAL_PORT}/api/runtime/shard-info?execution_id=${eid}&shard_count=${count}" || echo '{}')
    got=$(python3 -c 'import sys,json; print(json.loads(sys.argv[1]).get("shard_index",""))' "$resp")
    subj="noetl.commands.system.shard.${got}.${eid}"
    if [[ "$expected" == "-" ]]; then
        [[ -n "$got" ]] && { printf '    %-22s %-8s %-10s %-10s %s\n' "$eid" "$count" "(derive)" "$got" "$subj"; } \
                        || note_fail "eid=$eid count=$count: server returned no shard_index"
    elif [[ "$got" == "$expected" ]]; then
        printf '    %-22s %-8s %-10s %-10s %s\n' "$eid" "$count" "$expected" "$(green "$got")" "$subj"
    else
        printf '    %-22s %-8s %-10s %-10s %s\n' "$eid" "$count" "$expected" "$(red "$got")" "$subj"
        note_fail "eid=$eid count=$count: server shard $got != pinned $expected (cross-repo hash drift)"
    fi
done
[[ ${FAILURES} -eq 0 ]] && ok "server shard_for matches command_subject's pinned vectors"

# ---------------------------------------------------------------------------
# Phase 2 — real-JetStream subsumption + per-shard isolation (additive).
# ---------------------------------------------------------------------------
step "Phase 2: real-JetStream routing under isolated pool '${TEST_POOL}' (non-disruptive)"

SUB_BROAD="noetl.commands.${TEST_POOL}.>"
SUB_SHARD0="noetl.commands.${TEST_POOL}.shard.0.>"
SUB_SHARD1="noetl.commands.${TEST_POOL}.shard.1.>"
C_BROAD="vald166_broad_${NONCE}"
C_SHARD0="vald166_shard0_${NONCE}"
C_SHARD1="vald166_shard1_${NONCE}"

add_consumer() {  # name  filter_subject
    nats_cli consumer add "${STREAM}" "$1" \
        --pull --filter "$2" --ack explicit --deliver new \
        --replay instant --max-deliver 1 --max-pending 0 \
        --wait 1s --defaults >/dev/null 2>&1
    CREATED_CONSUMERS+=("$1")
}
# `--deliver new` → each consumer only sees messages published AFTER it is
# created, so we create all three FIRST, then publish.
add_consumer "${C_BROAD}"  "${SUB_BROAD}"  && ok "created broad consumer (filter ${SUB_BROAD})"  || note_fail "could not create broad consumer"
add_consumer "${C_SHARD0}" "${SUB_SHARD0}" && ok "created shard-0 consumer (filter ${SUB_SHARD0})" || note_fail "could not create shard-0 consumer"
add_consumer "${C_SHARD1}" "${SUB_SHARD1}" && ok "created shard-1 consumer (filter ${SUB_SHARD1})" || note_fail "could not create shard-1 consumer"

EID_A="700000000000000${NONCE: -3}"
EID_B="700000000000001${NONCE: -3}"
EID_C="700000000000002${NONCE: -3}"
PUB_SHARD0="noetl.commands.${TEST_POOL}.shard.0.${EID_A}"
PUB_SHARD1="noetl.commands.${TEST_POOL}.shard.1.${EID_B}"
PUB_LEGACY="noetl.commands.${TEST_POOL}.${EID_C}"

nats_cli pub "${PUB_SHARD0}" "{\"execution_id\":${EID_A},\"probe\":\"shard0\"}" >/dev/null 2>&1
nats_cli pub "${PUB_SHARD1}" "{\"execution_id\":${EID_B},\"probe\":\"shard1\"}" >/dev/null 2>&1
nats_cli pub "${PUB_LEGACY}" "{\"execution_id\":${EID_C},\"probe\":\"legacy\"}" >/dev/null 2>&1
ok "published 3 probes: shard-0 subject, shard-1 subject, legacy (no-shard) subject"

count_received() {  # consumer -> integer messages fetchable
    # `nats consumer next` prints one "… subj: <subject> … str seq: …" header
    # line per delivered message, then exits non-zero on the trailing fetch
    # timeout — hence the `|| true`.  Count the per-message header lines.
    nats_cli consumer next "${STREAM}" "$1" --count 10 --no-ack --timeout 2s 2>/dev/null \
        | grep -c 'str seq:' || true
}
sleep 1
GOT_S0=$(count_received "${C_SHARD0}")
GOT_S1=$(count_received "${C_SHARD1}")
GOT_BR=$(count_received "${C_BROAD}")

printf '\n    %-32s %-10s %s\n' "consumer (filter)" "received" "expected"
printf '    %-32s %-10s %s\n' "shard-0 (…shard.0.>)" "${GOT_S0:-0}" "1 (its shard only)"
printf '    %-32s %-10s %s\n' "shard-1 (…shard.1.>)" "${GOT_S1:-0}" "1 (its shard only)"
printf '    %-32s %-10s %s\n' "broad   (…${TEST_POOL}.>)" "${GOT_BR:-0}" "3 (subsumption: both shards + legacy)"
printf '\n'

[[ "${GOT_S0:-0}" == "1" ]] && ok "shard-0 consumer received exactly its shard subject" \
                            || note_fail "shard-0 consumer expected 1, got ${GOT_S0:-0} (isolation broken)"
[[ "${GOT_S1:-0}" == "1" ]] && ok "shard-1 consumer received exactly its shard subject" \
                            || note_fail "shard-1 consumer expected 1, got ${GOT_S1:-0} (isolation broken)"
[[ "${GOT_BR:-0}" == "3" ]] && ok "broad consumer received all 3 (shard subtree + legacy subsumed)" \
                            || note_fail "broad consumer expected 3, got ${GOT_BR:-0} (subsumption broken)"

warn "Mode-B note: the legacy (no-shard) probe reached ONLY the broad consumer, NOT either per-shard consumer."
warn "→ a per-shard system consumer must ALSO retain a broad/legacy filter for non-drive system commands"
warn "  (scheduled_cleanup etc.), which the server does NOT shard-route — else those would be stranded."

# ---------------------------------------------------------------------------
# Phase 3 — GATED real-server Mode A (mutates the shared server).
# ---------------------------------------------------------------------------
step "Phase 3: real-server Mode A (server-routed publish end-to-end)"
if [[ "${ENABLE_SERVER_ROUTE}" -ne 1 ]]; then
    warn "SKIPPED — this flips NOETL_SHARD_SUBJECT_ROUTE on the shared ${SERVER_SVC} (one rolling restart)."
    warn "It is Mode A of the human-gated #166 prod rollout. Re-run with --enable-server-route to execute."
    cat <<EOF

    Operator recipe (Mode A, kind):
      SAVE=\$(kubectl --context ${KCTX} -n ${NS} get deploy ${SERVER_SVC} \\
        -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="NOETL_SHARD_SUBJECT_ROUTE")]}{.value}{end}')
      kubectl --context ${KCTX} -n ${NS} set env deploy/${SERVER_SVC} \\
        NOETL_SHARD_SUBJECT_ROUTE=true NOETL_COMMAND_SHARD_COUNT=2
      # drive a system-pool execution (Muno / system playbook), capture eid,
      # then: GET /api/runtime/shard-info?execution_id=<eid>&shard_count=2 → n
      # and observe noetl.commands.system.shard.<n>.<eid> on a shard-<n> consumer.
      # ROLLBACK (behavior-neutral by subsumption either way):
      kubectl --context ${KCTX} -n ${NS} set env deploy/${SERVER_SVC} \\
        NOETL_SHARD_SUBJECT_ROUTE- NOETL_COMMAND_SHARD_COUNT-
EOF
else
    warn "--enable-server-route passed: this WILL restart ${SERVER_SVC}. Ensure no soak is mid-flight."
    # (Operator-run path — intentionally left as the documented recipe above;
    #  automating a shared-deployment mutation inside CI-style validation is a
    #  rollout action, not a test.  Flip + drive + assert by hand per the recipe.)
    note_fail "Phase 3 automation is deliberately not wired — follow the printed recipe to run Mode A by hand."
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
if [[ ${FAILURES} -eq 0 ]]; then
    step "Result: $(green PASS) — non-disruptive Phase 5 Leg-1 routing validated in kind"
    exit 0
else
    step "Result: $(red FAIL) — ${FAILURES} check(s) failed"
    exit 1
fi
