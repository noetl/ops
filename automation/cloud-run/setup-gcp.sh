#!/usr/bin/env bash
# Provision the least-privilege GCP resources the out-of-cluster Cloud Run
# subscription runtime needs (noetl/ai-meta#90 Phase 5).
#
# Creates, idempotently:
#   - a dedicated runtime service account (the Cloud Run service identity),
#   - a GCS bucket for the store-and-forward spool (RFC §8, the gcs backend),
#   - a Pub/Sub topic + pull subscription as the message source,
# and grants the SA exactly two scoped roles — objectAdmin on the spool
# bucket and subscriber on the pull subscription. No project-wide roles, no
# service-account key file (the runtime uses the metadata-server identity /
# Workload Identity on Cloud Run, ADC locally).
#
# Re-running is safe: every step checks for existence first.
#
# Usage:
#   PROJECT=noetl-demo-19700101 REGION=us-central1 ./setup-gcp.sh
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to the GCP project id}"
REGION="${REGION:-us-central1}"
SA_NAME="${SA_NAME:-noetl-subscription-runtime}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
SPOOL_BUCKET="${SPOOL_BUCKET:-${PROJECT}-sub-spool}"
TOPIC="${TOPIC:-noetl-sub}"
SUBSCRIPTION="${SUBSCRIPTION:-${TOPIC}-pull}"

echo "project=${PROJECT} region=${REGION}"
echo "sa=${SA_EMAIL}"
echo "spool_bucket=gs://${SPOOL_BUCKET}"
echo "topic=${TOPIC} subscription=${SUBSCRIPTION}"

echo "== enabling required APIs (idempotent) =="
gcloud services enable run.googleapis.com pubsub.googleapis.com \
  storage.googleapis.com artifactregistry.googleapis.com \
  cloudbuild.googleapis.com iam.googleapis.com --project "${PROJECT}"

echo "== service account =="
if gcloud iam service-accounts describe "${SA_EMAIL}" --project "${PROJECT}" >/dev/null 2>&1; then
  echo "  exists: ${SA_EMAIL}"
else
  gcloud iam service-accounts create "${SA_NAME}" --project "${PROJECT}" \
    --display-name="NoETL Subscription Runtime (Cloud Run, #90 Phase 5)"
fi

echo "== spool bucket =="
if gcloud storage buckets describe "gs://${SPOOL_BUCKET}" --project "${PROJECT}" >/dev/null 2>&1; then
  echo "  exists: gs://${SPOOL_BUCKET}"
else
  gcloud storage buckets create "gs://${SPOOL_BUCKET}" --project "${PROJECT}" \
    --location="${REGION}" --uniform-bucket-level-access
fi
# Lifecycle: drained spool objects are deleted immediately by the runtime, but
# set a 7-day TTL as the backstop cost ceiling for anything orphaned by a crash.
printf '{"rule":[{"action":{"type":"Delete"},"condition":{"age":7}}]}' \
  | gcloud storage buckets update "gs://${SPOOL_BUCKET}" --project "${PROJECT}" \
      --lifecycle-file=/dev/stdin

echo "== bucket IAM (objectAdmin, scoped to this bucket only) =="
gcloud storage buckets add-iam-policy-binding "gs://${SPOOL_BUCKET}" --project "${PROJECT}" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/storage.objectAdmin" >/dev/null

echo "== Pub/Sub topic + pull subscription =="
gcloud pubsub topics describe "${TOPIC}" --project "${PROJECT}" >/dev/null 2>&1 \
  || gcloud pubsub topics create "${TOPIC}" --project "${PROJECT}"
gcloud pubsub subscriptions describe "${SUBSCRIPTION}" --project "${PROJECT}" >/dev/null 2>&1 \
  || gcloud pubsub subscriptions create "${SUBSCRIPTION}" --topic "${TOPIC}" \
       --project "${PROJECT}" --ack-deadline=30

echo "== subscription IAM (subscriber, scoped to this subscription only) =="
gcloud pubsub subscriptions add-iam-policy-binding "${SUBSCRIPTION}" --project "${PROJECT}" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/pubsub.subscriber" >/dev/null

echo "== done =="
echo "SA_EMAIL=${SA_EMAIL}"
echo "SPOOL_BUCKET=${SPOOL_BUCKET}"
echo "SUBSCRIPTION=${SUBSCRIPTION}"
