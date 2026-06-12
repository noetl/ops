#!/usr/bin/env bash
# Build the noetl-worker image and deploy the out-of-cluster subscription
# runtime to Cloud Run (noetl/ai-meta#90 Phase 5).
#
# The runtime is the SAME noetl-worker binary in WORKER_MODE=subscription —
# no separate artifact. Cloud Run runs it as a min-instances=1 service so the
# pull loop holds the Pub/Sub subscription continuously; --no-cpu-throttling
# keeps CPU allocated to the background loop between requests. The container
# binds $PORT (Cloud Run's health port) via the worker's existing metrics
# server (/healthz + /metrics), so no HTTP code is added for Cloud Run.
#
# It holds NO database connection: every message becomes one POST /api/execute
# on $NOETL_SERVER_URL over HTTPS, and lifecycle/spool/directive events flow
# back via POST /api/events (data-access-boundary.md). The spool buffers to a
# GCS bucket (the gcs backend, tools v3.5.0) under a downstream outage.
#
# Prereqs: ./setup-gcp.sh has run; NOETL_SERVER_URL points at an HTTPS-
# reachable NoETL server (a public server, or a tunnel to a kind/dev server —
# see README.md "Reachability").
#
# Usage:
#   PROJECT=noetl-demo-19700101 \
#   NOETL_SERVER_URL=https://my-server.example.com \
#   SUBSCRIPTION_PATH=subscriptions/cloudrun_demo \
#   WORKER_REPO_DIR=../../../worker \
#   ./deploy.sh
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-noetl-subscription-runtime}"
SA_NAME="${SA_NAME:-noetl-subscription-runtime}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
SPOOL_BUCKET="${SPOOL_BUCKET:-${PROJECT}-sub-spool}"
SUBSCRIPTION_PATH="${SUBSCRIPTION_PATH:?set SUBSCRIPTION_PATH to the kind: Subscription catalog path}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:?set NOETL_SERVER_URL to an HTTPS-reachable server}"
AR_REPO="${AR_REPO:-noetl}"
IMAGE_TAG="${IMAGE_TAG:-phase5}"
IMAGE="${IMAGE:-${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}/noetl-worker:${IMAGE_TAG}}"
WORKER_REPO_DIR="${WORKER_REPO_DIR:-../../../worker}"
RUST_LOG="${RUST_LOG:-info,noetl_worker=debug}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "== building image via Cloud Build: ${IMAGE} =="
  gcloud builds submit "${WORKER_REPO_DIR}" --project "${PROJECT}" --tag "${IMAGE}"
else
  echo "== SKIP_BUILD=1, using existing image ${IMAGE} =="
fi

echo "== deploying Cloud Run service: ${SERVICE} =="
# A pull listener is a singleton: min=max=1 so exactly one instance holds the
# subscription. No --allow-unauthenticated: the service is a producer, not an
# invokable endpoint. WORKER_METRICS_BIND binds $PORT so Cloud Run's startup
# probe (TCP on the port) passes the moment the metrics server is up.
gcloud run deploy "${SERVICE}" \
  --project "${PROJECT}" --region "${REGION}" \
  --image "${IMAGE}" \
  --service-account "${SA_EMAIL}" \
  --no-cpu-throttling \
  --min-instances 1 --max-instances 1 \
  --no-allow-unauthenticated \
  --port 8080 \
  --memory 256Mi --cpu 1 \
  --set-env-vars "^@@^WORKER_MODE=subscription@@NOETL_SUBSCRIPTION_PATH=${SUBSCRIPTION_PATH}@@NOETL_SERVER_URL=${NOETL_SERVER_URL}@@WORKER_METRICS_BIND=0.0.0.0:8080@@NOETL_SPOOL_BUCKET=${SPOOL_BUCKET}@@RUST_LOG=${RUST_LOG}"

echo "== deployed =="
gcloud run services describe "${SERVICE}" --project "${PROJECT}" --region "${REGION}" \
  --format='value(status.url)'
echo "Tail logs:  gcloud beta run services logs read ${SERVICE} --project ${PROJECT} --region ${REGION}"
echo "Tear down:  PROJECT=${PROJECT} SERVICE=${SERVICE} ./teardown.sh"
