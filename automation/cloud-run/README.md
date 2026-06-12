# Out-of-cluster subscription runtime on Cloud Run (RFC #90 Phase 5)

The NoETL subscription runtime (RFC Mode B) runs the same `noetl-worker`
binary in `WORKER_MODE=subscription`, holding a `kind: Subscription`'s
message source open and turning each message into one execution. **Phase 5**
runs that runtime **out of the cluster** on Google Cloud Run so an IoT-scale
firehose never consumes cluster capacity — it enters the cluster network only
once it is already a well-formed `POST /api/execute`.

This directory is the build + deploy + teardown recipe.

```
setup-gcp.sh   provision least-privilege SA + spool bucket + Pub/Sub source
deploy.sh      build the worker image (Cloud Build) + gcloud run deploy
teardown.sh    delete the service (stop the cost); optionally the demo resources
service.yaml   declarative Knative service spec (alternative to deploy.sh)
```

## The shape

```
Pub/Sub topic ──► Cloud Run service (min=1, noetl-worker WORKER_MODE=subscription)
                    │  pull loop: poll → directives → POST /api/execute  (HTTPS)
                    │  outage:    probe → circuit → spool to GCS → ack
                    ▼
              NoETL server  (events flow back: POST /api/events)
```

- **Pull, not push.** A Cloud Run *service* at `--min-instances 1`
  `--no-cpu-throttling` holds the subscription continuously. (Push/Pub-Sub-
  push is the gateway Mode-C path from Phase 3 and scales to zero; pull is the
  dedicated-runtime path and must keep one instance alive.)
- **No DB connection.** The runtime is an ingress producer. Every message is a
  `POST /api/execute`; lifecycle/spool/directive events are `POST /api/events`.
  It never touches `noetl.*` (`data-access-boundary.md`).
- **Auth.** The service runs as a dedicated runtime service account (Workload
  Identity — no key file). Set `NOETL_INTERNAL_API_TOKEN` to make the worker
  send `Authorization: Bearer <token>` to the control plane (worker v5.18+).
- **Spool.** Under a downstream outage the runtime buffers to a **GCS bucket**
  via the `gcs` backend (tools v3.5+), the same Phase-4 engine (circuit
  breaker, ordered replay, idempotency, dead-letter). Circuit state is
  in-memory on Cloud Run (no in-cluster NATS KV); a restart re-probes from
  closed. The bucket is the durable buffer.

## Health port

Cloud Run injects `$PORT` and probes a TCP connect on it. The worker's metrics
server (`/healthz` + `/metrics`) binds it — `WORKER_METRICS_BIND=0.0.0.0:$PORT`
(worker v5.18+ also auto-derives `0.0.0.0:$PORT` from `PORT`). No HTTP code is
added for Cloud Run.

## Reachability

Cloud Run reaches the NoETL server over **HTTPS**. Options, in order of
production-readiness:

1. **A public NoETL server** (GKE Ingress / Cloud Run / load balancer with TLS)
   — the production path. Point `NOETL_SERVER_URL` at it.
2. **A secure tunnel to a dev/kind server** — for proving the out-of-cluster
   path without exposing a server. `cloudflared tunnel --url http://localhost:8082`
   prints a `https://<random>.trycloudflare.com` URL; use it as
   `NOETL_SERVER_URL`. Ephemeral, no account. (ngrok works the same way.)

The kind server is not publicly reachable on its own — a tunnel (or a real
public server) is required for a live end-to-end.

## Run it

```bash
# 1. provision (idempotent)
PROJECT=noetl-demo-19700101 REGION=us-central1 ./setup-gcp.sh

# 2. register the kind: Subscription on the server (catalog), then deploy
PROJECT=noetl-demo-19700101 \
NOETL_SERVER_URL=https://<your-server-or-tunnel> \
SUBSCRIPTION_PATH=subscriptions/cloudrun_demo \
SPOOL_BUCKET=noetl-demo-19700101-sub-spool \
WORKER_REPO_DIR=../../../worker \
./deploy.sh

# 3. publish a message to the source topic → one execution on the server
gcloud pubsub topics publish noetl-sub --project noetl-demo-19700101 \
  --message '{"hello":"cloud-run"}'

# 4. tear down (stop the cost)
PROJECT=noetl-demo-19700101 ./teardown.sh
```

## Cost

A pull runtime bills for one always-allocated instance (256Mi / 1 vCPU,
`--no-cpu-throttling`) while deployed. `teardown.sh` deletes the service to
stop it — scale-to-zero is not possible for a pull listener. The spool bucket
and Pub/Sub topic cost ~nothing when empty; the bucket has a 7-day lifecycle
TTL as the orphan backstop. Pass `DELETE_RESOURCES=1` to `teardown.sh` to
remove the demo bucket/topic/subscription too.
