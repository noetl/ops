#!/usr/bin/env bash
# orphans.sh DIR — step.enter rows whose parent is not a persisted event (issued by an orchestrate drive)
for f in "$1"/*.jsonl; do jq -s -r '(map(.event_id|tostring)) as $ids | [.[] | select(.event_type=="step.enter" and .parent_event_id!=null and ((.parent_event_id|tostring) as $p | $ids|index($p)|not)) | .node_name] | join(",")' "$f"; done | awk '{n++; if($0!="") {o++; s[$0]++}} END{printf "runs=%d drive-entered=%d", n, o; for(k in s) printf " [%s x%d]", k, s[k]; print ""}'
