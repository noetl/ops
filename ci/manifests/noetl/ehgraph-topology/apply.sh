#!/usr/bin/env bash
# Steps 2-3 of the topology-writer standup on the prod server StatefulSet. Two phases, one
# restart each, smoked after each, rolled back automatically if a smoke fails:
#
#   CONFIRM=yes ci/manifests/noetl/ehgraph-topology/apply.sh a   # embedded ehgraph only
#   CONFIRM=yes ci/manifests/noetl/ehgraph-topology/apply.sh b   # + topology writer
#
# Phase a also adds the two GSM secrets to the SecretProviderClass (they mount at the pod
# start this phase causes). CTX/NS/STS/SPC are overridable so kind_validate.sh can drive the
# same code against kind.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CTX=${CTX:-noetl-prod}; NS=${NS:-noetl}; STS=${STS:-noetl-server-rust-embedded}; KIND=${KIND:-statefulset}
SPC=${SPC-noetl-server-secrets}
PHASE=${1:?phase a or b}
K() { kubectl --context "$CTX" -n "$NS" "$@"; }
[ "${CONFIRM:-}" = yes ] || { echo "refusing: set CONFIRM=yes (target: $CTX $KIND/$STS)"; exit 2; }
SNAP=${SNAP:-$HERE/.snap-$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p "$SNAP"
K get "$KIND" "$STS" -o json > "$SNAP/server.json"
echo "rollback pin: $(jq -r '.spec.template.spec.containers[0].image' "$SNAP/server.json")  (snapshot $SNAP)"

PHASE_A=(NOETL_EHGRAPH_EMBEDDED=true NOETL_EHGRAPH_CONFIG=/var/secrets/sm/ehgraph-config.toml
         NOETL_EHGRAPH_HOST_REPLICAS=1 NOETL_EHGRAPH_HOST_ORDINAL=0)
PHASE_B=(NOETL_EHGRAPH_TOPOLOGY_WRITER=true NOETL_EHGRAPH_TOPOLOGY_TOKEN_FILE=/var/secrets/sm/ehgraph-topology-token)

case "$PHASE" in
  a)
    if [ -n "$SPC" ]; then
      K get secretproviderclass "$SPC" -o json > "$SNAP/spc.json"
      if ! jq -r '.spec.parameters.secrets' "$SNAP/spc.json" | grep -q noetl-ehgraph-config; then
        P=$(jq -r '.spec.parameters.secrets' "$SNAP/spc.json")
        P="$P
- resourceName: \"projects/shastaratech-noetl-prod/secrets/noetl-ehgraph-config/versions/latest\"
  path: \"ehgraph-config.toml\"
- resourceName: \"projects/shastaratech-noetl-prod/secrets/noetl-ehgraph-topology-token/versions/latest\"
  path: \"ehgraph-topology-token\""
        K patch secretproviderclass "$SPC" --type merge -p "$(jq -n --arg s "$P" '{spec:{parameters:{secrets:$s}}}')"
      fi
    fi
    SET=("${PHASE_A[@]}") ;;
  b) SET=("${PHASE_B[@]}") ;;
  *) echo "phase must be a or b"; exit 2 ;;
esac

K set env "$KIND/$STS" "${SET[@]}"
K rollout status "$KIND/$STS" --timeout=600s
if "$HERE/smoke.sh" "$PHASE"; then
  echo "== phase $PHASE: smoke green"
else
  echo "== phase $PHASE: SMOKE FAILED, rolling phase $PHASE back"
  CONFIRM=yes "$HERE/rollback.sh" "$PHASE"
  exit 1
fi
