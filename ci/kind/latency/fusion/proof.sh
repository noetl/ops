#!/usr/bin/env bash
# proof.sh OUT N — run each correctness playbook N times on the kind lat stack, dump rows
set -euo pipefail
OUT=${1:?}; N=${2:-5}; mkdir -p "$OUT"; H=$(cd "$(dirname "$0")" && pwd)
K="kubectl --context kind-noetl -n noetl"; B=http://127.0.0.1:38091
$K port-forward svc/noetl-server-lat 38091:8082 >/dev/null 2>&1 & PF=$!; trap 'kill $PF' EXIT
for _ in $(seq 1 30); do curl -fsS -m 2 $B/api/health >/dev/null 2>&1 && break; sleep 1; done
for f in "$H"/../playbooks/bench_fuse_*.yaml; do curl -sS -m 30 -H 'Content-Type: application/json' -X POST $B/api/catalog/register -d "$(jq -n --rawfile c "$f" '{content:$c,resource_type:"Playbook"}')" | jq -c '{path,version}'; done
for pb in ${PBS:-bench/fuse_multitool bench/fuse_goto bench/seq10_py}; do
  for i in $(seq 1 "$N"); do
    eid=$(curl -sS -m 30 -H 'Content-Type: application/json' -X POST $B/api/execute -d "$(jq -n --arg p $pb '{path:$p,payload:{}}')" | jq -r .execution_id)
    for _ in $(seq 1 300); do st=$(curl -sS -m 5 $B/api/executions/$eid/status | jq -r '.status' | tr a-z A-Z); case $st in COMPLETED|FAILED|CANCELLED) break;; esac; sleep 0.2; done
    sleep 2  # let the materializer land the tail
    n=${pb#bench/}; "$H/dump.sh" "$eid" "$OUT/$n-$i.jsonl"
    curl -sS -m 10 $B/api/executions/$eid > "$OUT/$n-$i.api.json"
    echo "$pb #$i $eid $st rows=$(wc -l < "$OUT/$n-$i.jsonl" | tr -d ' ')"
  done
done
