# Google Pub/Sub Emulator (subscription-tool E2E)

A single-pod Google Pub/Sub **emulator** for end-to-end validation of the
NoETL `subscription` tool's Pub/Sub pull backend
([noetl/ai-meta#90](https://github.com/noetl/ai-meta/issues/90) Phase 1).
This is a test broker, not a production component.

## Components

- **Deployment** `pubsub-emulator` — runs
  `gcloud beta emulators pubsub start --host-port=0.0.0.0:8085
  --project=noetl-e2e` from the gcloud SDK `:emulators` image.
- **Service** `pubsub-emulator` (ClusterIP, port 8085).
- **Namespace** `pubsub`.

## How the worker reaches it

The `subscription` tool's Pub/Sub backend
([`source/pubsub.rs`](https://github.com/noetl/tools/blob/main/src/tools/source/pubsub.rs))
treats any plaintext `http://` endpoint as an emulator and skips the
`Authorization` header. The E2E playbook references a `pubsub`-typed
credential whose `endpoint` is
`pubsub-emulator.pubsub.svc.cluster.local:8085`; the worker's
credential-alias resolver merges that `endpoint` into the tool config.

## Topics / subscriptions are ephemeral

The emulator holds topics and subscriptions in memory only — they are
lost on pod restart. The E2E runner
(`noetl/e2e/scripts/kind_validate_subscription_pubsub.sh`) creates the
topic + subscription and publishes test messages over a
`kubectl port-forward` at test time, mirroring how the NATS rig creates
its stream + durable consumer before draining.

## Apply

```bash
kubectl --context kind-noetl apply -f namespace.yaml
kubectl --context kind-noetl apply -f deployment.yaml
kubectl --context kind-noetl -n pubsub rollout status deploy/pubsub-emulator
```

The image must be present in the kind node (`kind load image-archive`)
since `imagePullPolicy: IfNotPresent`.
