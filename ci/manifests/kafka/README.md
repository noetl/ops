# Apache Kafka — single-broker KRaft (subscription-tool E2E)

A single-pod, single-broker **KRaft-mode** Apache Kafka for end-to-end
validation of the NoETL `subscription` tool's Kafka poll backend
([noetl/ai-meta#90](https://github.com/noetl/ai-meta/issues/90) Phase 1).
This is a test broker, not a production component.

## Image choice

Uses the maintained official **`apache/kafka`** image from Docker Hub. The
retired `bitnami/kafka` legacy images are deliberately avoided. KRaft
combined mode (broker + controller in one process) — no ZooKeeper.

## Components

- **Deployment** `kafka` — `apache/kafka:3.9.1`, combined broker +
  controller, plaintext listener on 9092, controller on 9093.
- **Service** `kafka` (ClusterIP, port 9092).
- **Namespace** `kafka`. Storage is ephemeral (`emptyDir`).

## Advertised listener (the load-bearing setting)

`KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka.kafka.svc.cluster.local:9092`.
A Kafka client connects, fetches metadata, then reconnects to the
**advertised** address — so it must be resolvable from the NoETL worker
pod in the `noetl` namespace. The in-cluster Service DNS satisfies that.

The E2E runner creates the topic and produces messages by `kubectl
exec`-ing the broker's bundled `kafka-topics.sh` /
`kafka-console-producer.sh` against `localhost:9092` inside the pod — so
no host-reachable advertised listener is required.

## Phase 1 limitations honored here

The tool's Kafka backend
([`source/kafka.rs`](https://github.com/noetl/tools/blob/main/src/tools/source/kafka.rs))
is **plaintext-only** in Phase 1 (no TLS/SASL) and does not surface record
headers, so only a `PLAINTEXT` listener is configured.

## Apply

```bash
kubectl --context kind-noetl apply -f namespace.yaml
kubectl --context kind-noetl apply -f kafka.yaml
kubectl --context kind-noetl -n kafka rollout status deploy/kafka
```

The image must be present in the kind node (`kind load image-archive`)
since `imagePullPolicy: IfNotPresent`.
