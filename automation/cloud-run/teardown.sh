#!/usr/bin/env bash
# Tear down the Cloud Run subscription runtime (noetl/ai-meta#90 Phase 5).
#
# A pull listener runs at min-instances=1, so it bills for an always-allocated
# instance. Deleting the service is the way to stop the cost (scale-to-zero is
# not available for a pull runtime — it must hold the subscription). The spool
# bucket + Pub/Sub topic are left in place by default (they cost ~nothing when
# empty and are part of the durable design); pass DELETE_RESOURCES=1 to remove
# the throwaway demo bucket/topic/subscription too.
#
# Usage:
#   PROJECT=noetl-demo-19700101 ./teardown.sh
#   PROJECT=... DELETE_RESOURCES=1 ./teardown.sh   # also delete bucket/topic/sub
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-noetl-subscription-runtime}"

echo "== deleting Cloud Run service ${SERVICE} =="
gcloud run services delete "${SERVICE}" --project "${PROJECT}" --region "${REGION}" --quiet \
  || echo "  (service not found — already gone)"

if [[ "${DELETE_RESOURCES:-0}" == "1" ]]; then
  SPOOL_BUCKET="${SPOOL_BUCKET:-${PROJECT}-sub-spool}"
  TOPIC="${TOPIC:-noetl-sub}"
  SUBSCRIPTION="${SUBSCRIPTION:-${TOPIC}-pull}"
  echo "== DELETE_RESOURCES=1: removing demo bucket/topic/subscription =="
  gcloud pubsub subscriptions delete "${SUBSCRIPTION}" --project "${PROJECT}" --quiet || true
  gcloud pubsub topics delete "${TOPIC}" --project "${PROJECT}" --quiet || true
  gcloud storage rm --recursive "gs://${SPOOL_BUCKET}" --project "${PROJECT}" || true
fi

echo "== done. Remaining cost-bearing resources: none (service deleted)$( [[ "${DELETE_RESOURCES:-0}" == "1" ]] && echo '; demo bucket/topic/sub deleted' || echo '; spool bucket/topic retained (empty → ~free)' ) =="
