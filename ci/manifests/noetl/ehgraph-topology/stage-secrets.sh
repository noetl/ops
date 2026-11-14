#!/usr/bin/env bash
# Step 1 of the topology-writer standup: create the two GSM secrets and grant the server's
# Workload Identity access. Creates secrets only; the running server does not read them
# until apply.sh adds them to the SecretProviderClass and restarts the pod.
#
#   CONFIRM=yes ci/manifests/noetl/ehgraph-topology/stage-secrets.sh
#
# The token is generated here, piped straight into GSM, and never printed or written to disk
# outside a 0600 temp file that is removed on exit. Idempotent: an existing secret is left
# alone (re-running never rotates the token; see README "Rotating the token").
set -euo pipefail
PROJECT=${PROJECT:-shastaratech-noetl-prod}
GSA=${GSA:-noetl-result-tier@shastaratech-noetl-prod.iam.gserviceaccount.com}
HERE=$(cd "$(dirname "$0")" && pwd)
[ "${CONFIRM:-}" = yes ] || { echo "refusing: set CONFIRM=yes (this writes to GSM in $PROJECT)"; exit 2; }

have() { gcloud secrets describe "$1" --project "$PROJECT" >/dev/null 2>&1; }
if have noetl-ehgraph-config || have noetl-ehgraph-topology-token; then
  have noetl-ehgraph-config && have noetl-ehgraph-topology-token \
    || { echo "only one of the two secrets exists; fix by hand (they must hold the same token)"; exit 3; }
  echo "both secrets already exist; leaving them as they are"
else
  umask 077; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  openssl rand -hex 32 | tr -d '\n' > "$T/token"
  TOPOLOGY_TOKEN=$(cat "$T/token") envsubst '${TOPOLOGY_TOKEN}' < "$HERE/config.template.toml" > "$T/config.toml"
  grep -qF '${TOPOLOGY_TOKEN}' "$T/config.toml" && { echo "render failed"; exit 4; }
  grep -q '^token = "[0-9a-f]\{64\}"$' "$T/config.toml" || { echo "render produced no token line"; exit 4; }
  gcloud secrets create noetl-ehgraph-topology-token --project "$PROJECT" --replication-policy=automatic --data-file="$T/token" >/dev/null
  gcloud secrets create noetl-ehgraph-config --project "$PROJECT" --replication-policy=automatic --data-file="$T/config.toml" >/dev/null
  echo "created noetl-ehgraph-topology-token and noetl-ehgraph-config (token not shown)"
fi
for s in noetl-ehgraph-config noetl-ehgraph-topology-token; do
  gcloud secrets add-iam-policy-binding "$s" --project "$PROJECT" \
    --member="serviceAccount:$GSA" --role=roles/secretmanager.secretAccessor >/dev/null
  echo "accessor $GSA on $s"
done
