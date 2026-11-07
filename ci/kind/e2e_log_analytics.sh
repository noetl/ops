#!/usr/bin/env bash
# End-to-end validation of the kind log-analytics IaC stack (docs/specs/noetl-iac-log-analytics.md).
# Local kind only. Every step goes through the NoETL playbooks; this script only sequences
# them and checks what they leave behind.
#
#   1  plan → apply (ClickHouse + Vector + MCP)              provision via automation/iap/kind/log_analytics.yaml
#   2  verify                                                 row via noetl http, read back, queried through MCP
#   3  qnetmon log rows                                       a copy of the edge daemon's logs, shipped by
#                                                             qnetmon playbooks/housekeeping/logs.yaml, queried
#                                                             via SQL and via MCP run_query
#   4  Phase 0 state                                          Feather executions written; second apply = all noop;
#                                                             backup → local loss → restore gives the same state
#   5  drift                                                  clean → field taken by another manager → drift exit 10
#                                                             → apply reconcile=enforce → clean
#   6  destroy                                                state owns 0, namespace + PV gone, drift after
#
# Isolation: a private credential store, a private state dir and a local stand-in for the
# object store (a gsutil shim over a directory: no cloud is touched). The live qnetmon
# var/runs is only READ (copied). Gates: 1-min load below MAX_LOAD (default 5); the kind
# API must answer. A podman machine or kind node container that was stopped is started, and
# stopped again at the end, so the cluster is left as it was found.
#
#   ci/kind/e2e_log_analytics.sh            # from the ops repo root
#   NOETL_BIN=/path/to/noetl (>= 5.5.0)  QNETMON=/path/to/qnetmon  LIVE_RUNS=/path/to/var/runs
set -euo pipefail
OPS=$(cd "$(dirname "$0")/../.." && pwd)
N=${NOETL_BIN:-noetl}
QN=${QNETMON:?set QNETMON to a qnetmon checkout (playbooks/housekeeping/logs.yaml)}
LIVE=${LIVE_RUNS:-}
MAX_LOAD=${MAX_LOAD:-5}
MACHINE=${PODMAN_MACHINE:-noetl-dev}
CTX=kind-noetl; NS=log-analytics; K="kubectl --context $CTX"
W=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/la-e2e.XXXXXX")}
mkdir -p "$W/bin" "$W/bucket" "$W/creds" "$W/state" "$W/qn"
export NOETL_CREDENTIALS_DIR="$W/creds"
STARTED=0; NODE_STARTED=0
NODE=${KIND_NODE:-noetl-control-plane}
pass=0; fails=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad()  { fails+=("$*"); printf '  FAIL %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
cleanup() {
  if [ "$NODE_STARTED" = 1 ]; then echo; echo "stopping kind node $NODE (it was stopped before this run)"; podman stop "$NODE" >/dev/null || true; fi
  if [ "$STARTED" = 1 ]; then echo; echo "stopping podman machine $MACHINE (it was stopped before this run)"; podman machine stop "$MACHINE" >/dev/null || true; fi
}
trap cleanup EXIT

# gsutil stand-in: gs://fake/<p> → $W/bucket/<p>. Lets backup/restore run for real, offline.
cat > "$W/bin/gsutil" <<'EOF'
#!/bin/bash
args=(); for a in "$@"; do case "$a" in -q|-m|cp|-r) ;; gs://fake/*) args+=("$FAKE_BUCKET/${a#gs://fake/}") ;; *) args+=("$a") ;; esac; done
dst="${args[${#args[@]}-1]}"; unset 'args[${#args[@]}-1]'
case "$dst" in */) mkdir -p "$dst" ;; esac
shopt -s nullglob; for src in ${args[@]}; do cp -R $src "$dst"; done
EOF
chmod +x "$W/bin/gsutil"; export PATH="$W/bin:$PATH" FAKE_BUCKET="$W/bucket"
BK=gs://fake/iac/log-analytics

pb() {  # pb <action> [--set k=v ...]  → prints the run log; returns the playbook's exit code
  local a=$1; shift
  (cd "$OPS" && "$N" run automation/iap/kind/log_analytics.yaml -r local --set action="$a" --set noetl_bin="$N" \
     --set state_dir="$W/state" --set state_backup="$BK" "$@" --json > "$W/out.json" 2>"$W/err.log")
  local rc=$?
  jq -r '.final_result // empty' "$W/out.json" 2>/dev/null || true
  [ $rc = 0 ] || tail -25 "$OPS/.noetl/log-analytics/latest.log" || true
  return $rc
}
LB="$N buffer --dir $W/state"
owned() { $LB cat --stack log-analytics --event-type provider.fact | jq -s -c '
  reduce (.[].result.data.provider_fact) as $f ({};
    if ($f.verb=="ensure" and ($f.outcome=="changed" or $f.outcome=="noop")) then .[$f.urn]=1
    elif ($f.verb=="delete") then del(.[$f.urn]) else . end) | length'; }

step "0. gates"
"$N" buffer --help >/dev/null 2>&1 || { echo "REFUSED: $N has no 'buffer' (needs noetl >= 5.5.0)"; exit 2; }
L=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || cut -d' ' -f1 /proc/loadavg)
awk -v l="$L" -v m="$MAX_LOAD" 'BEGIN{exit !(l<m)}' || { echo "REFUSED: 1-min load $L >= $MAX_LOAD; rerun when the host is quiet"; exit 3; }
ok "host load $L (< $MAX_LOAD)"
if ! $K get --raw /readyz >/dev/null 2>&1; then
  if podman machine inspect "$MACHINE" --format '{{.State}}' 2>/dev/null | grep -qv running; then
    echo "  starting podman machine $MACHINE"; podman machine start "$MACHINE" >/dev/null; STARTED=1
  fi
  # A machine restart does not restart the kind node container (no restart policy).
  if [ "$(podman inspect "$NODE" --format '{{.State.Running}}' 2>/dev/null)" = false ]; then
    echo "  starting kind node $NODE"; podman start "$NODE" >/dev/null; NODE_STARTED=1
  fi
  i=0; until $K get --raw /readyz >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 150 ] || { echo "FAILED: kind API not ready"; exit 4; }; sleep 2; done
  # Let the node's own workloads settle before adding ours (and re-check load).
  $K wait --for=condition=Ready node --all --timeout=300s >/dev/null
fi
ok "kind API ready ($CTX)"
$K get ns "$NS" >/dev/null 2>&1 && { echo "REFUSED: namespace $NS already exists; destroy it first"; exit 5; }

step "1. plan + apply (provision via NoETL)"
pb plan >/dev/null && ok "plan" || bad "plan"
pb apply > "$W/apply1.txt" && ok "apply: $(grep -c . "$W/apply1.txt") log lines" || { bad "apply"; exit 1; }
grep -q "state written: 14 changed" "$W/apply1.txt" && ok "state: 14 resources recorded as changed" || bad "first apply did not record 14 changed facts"
for o in statefulset/clickhouse daemonset/vector deployment/clickhouse-mcp; do
  $K -n "$NS" get "$o" >/dev/null && ok "$o exists" || bad "$o missing"; done

step "2. verify (noetl http insert/select + MCP)"
pb verify > "$W/verify.txt" && ok "verify passed" || bad "verify failed"
grep '^ok ' "$W/verify.txt" | sed 's/^/       /' || true

step "3. qnetmon log rows → ClickHouse → MCP"
mkdir -p "$W/qn/var/runs"
if [ -n "$LIVE" ] && [ -d "$LIVE" ]; then
  for f in events.jsonl subscribe.log subscribe.err; do [ -f "$LIVE/$f" ] && cp "$LIVE/$f" "$W/qn/var/runs/"; done
else
  printf '{"execution_id":1,"event_type":"playbook.completed","step":"end","status":"COMPLETED","created_at":"%s","context":{"playbook":"cycle.yaml","subscription":"qnetmon-edge-mac"}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)" > "$W/qn/var/runs/events.jsonl"
fi
(cd "$QN" && "$N" run playbooks/housekeeping/logs.yaml -r local --set home="$W/qn" --set runs=var/runs \
   --set clickhouse_url=http://127.0.0.1:30123 --set restart_cmd=true \
   --set files="events.jsonl:102400:events subscribe.log:102400:stdout subscribe.err:102400:stderr" \
   --json > "$W/qn.json" 2>"$W/qn.err") && ok "qnetmon logs.yaml shipped" || bad "qnetmon logs.yaml failed: $(tail -3 "$W/qn.err")"
chq() { $K -n "$NS" exec clickhouse-0 -c clickhouse -- clickhouse-client -q "$1"; }
qrows=$(chq "SELECT count() FROM logs.events WHERE source = 'qnetmon'")
[ "${qrows:-0}" -gt 0 ] && ok "ClickHouse holds $qrows qnetmon rows" || bad "no qnetmon rows in logs.events"
chq "SELECT stream, count() FROM logs.events WHERE source='qnetmon' GROUP BY stream ORDER BY stream FORMAT TSV" | sed 's/^/       /' || true
# MCP: same JSON-RPC sequence verify_mcp uses, asking for qnetmon rows.
$K -n "$NS" port-forward svc/clickhouse-mcp 38125:8000 >/dev/null 2>&1 & PF=$!
MCP=http://127.0.0.1:38125; i=0; until curl -fsS -m 2 "$MCP/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 30 ] || break; sleep 0.5; done
TOKEN=$($K -n "$NS" get secret log-analytics-credentials -o json | jq -r '.data["mcp-token"]' | base64 -d)
H=$(mktemp); B=$(mktemp)
rpc() { curl -sS -m 30 -o "$B" -D "$H" -H "Authorization: Bearer $TOKEN" ${2:+-H "mcp-session-id: $2"} \
          -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$1" "$MCP/mcp"
        if grep -q '^data: ' "$B"; then sed -n 's/^data: //p' "$B" | tail -1; else cat "$B"; fi; }
rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"la-e2e","version":"1"}}}' >/dev/null
SID=$(awk 'tolower($1)=="mcp-session-id:"{print $2}' "$H" | tr -d '\r')
rpc '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$SID" >/dev/null || true
res=$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_query","arguments":{"query":"SELECT count() AS n FROM logs.events WHERE source = '\''qnetmon'\''"}}}' "$SID")
mn=$(printf '%s' "$res" | jq -r '.result.content[0].text' | grep -oE '[0-9]+' | head -1 || true)
[ "${mn:-0}" = "$qrows" ] && ok "MCP run_query counts the same $mn qnetmon rows" || bad "MCP count '$mn' != SQL count '$qrows': $(printf '%s' "$res" | head -c 300)"
kill $PF 2>/dev/null || true; unset TOKEN; rm -f "$H" "$B"

step "4. Phase 0 Feather state: write, no-op re-apply, backup, restore"
ex=$($LB list --stack log-analytics --json)
[ "$(printf '%s' "$ex" | jq '[.[] | select(.status=="COMPLETED")] | length')" -ge 1 ] && ok "$(printf '%s' "$ex" | jq length) closed Feather execution(s) under $W/state" || bad "no closed buffer execution"
f=$(printf '%s' "$ex" | jq -r '.[0].dir')/events.feather
head -c 6 "$f" | grep -q ARROW1 && ok "events.feather is Arrow IPC (ARROW1 magic)" || bad "events.feather magic"
python3 -I -c 'import pyarrow.feather as F,sys; t=F.read_table(sys.argv[1]); print("       pyarrow:", t.num_rows, "rows,", t.schema.names[:6], "...")' "$f" 2>/dev/null || true
pb apply > "$W/apply2.txt" && grep -q "state written: 0 changed, 14 unchanged, 0 pruned" "$W/apply2.txt" \
  && ok "second apply is a no-op (0 changed, 14 unchanged)" || bad "second apply not a no-op: $(grep 'state written' "$W/apply2.txt")"
[ "$(owned)" = 14 ] && ok "fold owns 14" || bad "fold owns $(owned), want 14"
nb=$(ls "$W/bucket/iac/log-analytics" | wc -l | tr -d ' '); nl=$($LB list --stack log-analytics --json | jq length)
[ "$nb" = "$nl" ] && ok "object-store copy holds all $nb executions" || bad "backup has $nb executions, local $nl"
mv "$W/state" "$W/state.lost"; mkdir -p "$W/state"
pb state > "$W/state.txt" && grep -q "state restored from backup" "$W/state.txt" && [ "$(owned)" = 14 ] \
  && ok "local state lost → restored from object store, fold owns 14 again" || bad "restore failed"
"$N" provider orphans --help >/dev/null 2>&1 && true
"$N" push --all --stack log-analytics --dir "$W/state" --dry-run --server http://127.0.0.1:9 | jq -c . | sed 's/^/       push (dry-run): /' || bad "push dry-run"

step "5. drift"
pb drift > "$W/drift0.txt" && ok "drift clean after apply" || bad "drift not clean: $(tail -5 "$W/drift0.txt")"
$K -n "$NS" patch deployment clickhouse-mcp --field-manager=e2e-intruder --type=merge \
  -p '{"spec":{"template":{"spec":{"terminationGracePeriodSeconds":7}}}}' >/dev/null
set +e; pb drift > "$W/drift1.txt"; rc=$?; set -e
[ $rc = 10 ] && ok "drift detects the foreign change (exit 10)" || bad "drift exit $rc after a foreign change, want 10"
pb apply --set reconcile=enforce > "$W/apply3.txt" && pb drift > "$W/drift2.txt" && ok "apply reconcile=enforce restores; drift clean" || bad "enforce/redrift failed"

step "6. destroy + teardown"
pb destroy --set confirm=log-analytics > "$W/destroy.txt" && ok "destroy" || bad "destroy failed"
grep -q "DESTROYED: state now owns 0" "$W/destroy.txt" && ok "state owns 0" || bad "state not empty after destroy"
$K get ns "$NS" >/dev/null 2>&1 && bad "namespace $NS still exists" || ok "namespace $NS gone"
[ "$($K get pv -o json | jq --arg ns "$NS" '[.items[] | select(.spec.claimRef.namespace==$ns)] | length')" = 0 ] && ok "no PV left" || bad "PV left"
[ "$($K get clusterrole,clusterrolebinding -l noetl.io/stack=log-analytics -o name | wc -l | tr -d ' ')" = 0 ] && ok "no cluster-scoped objects left" || bad "cluster-scoped leftovers"

echo
echo "work dir: $W"
echo "passed: $pass   failed: ${#fails[@]}"
[ ${#fails[@]} = 0 ] || { printf '  - %s\n' "${fails[@]}"; exit 1; }
