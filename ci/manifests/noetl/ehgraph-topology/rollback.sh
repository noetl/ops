#!/usr/bin/env bash
# Roll the topology-writer standup back. One restart.
#
#   CONFIRM=yes rollback.sh b     # writer off, embedded ehgraph stays
#   CONFIRM=yes rollback.sh a     # both off (the server is back to its pre-standup env)
#   CONFIRM=yes PURGE=yes rollback.sh a   # also delete /data/ehgraph (the graph's files)
#
# The SecretProviderClass entries and the GSM secrets are left in place: mounted files nobody
# reads change nothing. Remove them by hand if the standup is abandoned (README).
# The image is not touched; the server's own image rollback is independent of this.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CTX=${CTX:-noetl-prod}; NS=${NS:-noetl}; STS=${STS:-noetl-server-rust-embedded}; KIND=${KIND:-statefulset}
PHASE=${1:?phase a or b}
K() { kubectl --context "$CTX" -n "$NS" "$@"; }
[ "${CONFIRM:-}" = yes ] || { echo "refusing: set CONFIRM=yes (target: $CTX $KIND/$STS)"; exit 2; }
B=(NOETL_EHGRAPH_TOPOLOGY_WRITER- NOETL_EHGRAPH_TOPOLOGY_TOKEN_FILE-)
A=(NOETL_EHGRAPH_EMBEDDED- NOETL_EHGRAPH_CONFIG- NOETL_EHGRAPH_HOST_REPLICAS- NOETL_EHGRAPH_HOST_ORDINAL-)
case "$PHASE" in b) U=("${B[@]}") ;; a) U=("${B[@]}" "${A[@]}") ;; *) echo "phase must be a or b"; exit 2 ;; esac
K set env "$KIND/$STS" "${U[@]}"
K rollout status "$KIND/$STS" --timeout=600s
if [ "$PHASE" = a ] && [ "${PURGE:-}" = yes ]; then
  pod=$(K get pods -o name | grep -m1 "${STS}")
  K exec "${pod#pod/}" -- rm -rf /data/ehgraph && echo "purged /data/ehgraph"
fi
if [ "$PHASE" = a ]; then SKIP_GRAPH=1 "$HERE/smoke.sh" rollback-a; else "$HERE/smoke.sh" a; fi
