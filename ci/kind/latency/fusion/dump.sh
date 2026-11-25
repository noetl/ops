#!/usr/bin/env bash
# dump.sh EID OUT.jsonl — every noetl.event row of an execution (kind lat DB), event_id order
set -euo pipefail
kubectl --context kind-noetl -n postgres exec -i deploy/postgres -- psql -U noetl -d noetl_lat -At -c \
 "select row_to_json(e) from (select event_id, prev_event_id, parent_event_id, event_type, node_id, node_name, node_type, status, result, meta, context, error, worker_id, created_at from noetl.event where execution_id=$1 order by event_id) e" > "$2"
