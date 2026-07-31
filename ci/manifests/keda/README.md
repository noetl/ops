# KEDA autoscaling for NoETL workers

This directory holds the KEDA `ScaledObject` manifests that scale the
two worker Deployments based on NATS JetStream consumer lag:

- **`scaledobject-worker-cpu-01.yaml`** — Python `noetl-worker`
  deployment.  **Three triggers** (one per pool segment: legacy,
  shared, python) after noetl/ai-meta#42 PR-4 to handle per-pool
  command routing for tool kinds the Rust worker can't dispatch
  (today: `agent`; tomorrow: `container` per #43).  KEDA's HPA
  reconciler picks the `MAX` desired-replicas across triggers, so
  the pool scales on whichever consumer has the largest backlog.
- **`scaledobject-worker-rust-pool.yaml`** — Rust `noetl-worker-rust`
  deployment.  Single trigger on the `noetl_worker_pool_shared`
  consumer (Rust workers only subscribe to the shared segment per
  PR-2b/PR-3).

The Python pool's three consumers map to the three subject branches
the Python worker subscribes to:

| Consumer | Filter subject | Notes |
|---|---|---|
| `noetl_worker_pool` | _none_ (wide-open) | Legacy single-consumer; receives publishes on the bare subject (today's behaviour, kept active until PR-6 cleanup once the cutover soak completes). |
| `noetl_worker_pool_shared` | `noetl.commands.shared.>` | Receives commands routed to the shared segment after PR-5 cutover. |
| `noetl_worker_pool_python` | `noetl.commands.python.>` | Receives commands routed to the Python-only segment (currently: `agent` kind). |

The Rust pool's single consumer (`noetl_worker_pool_shared`) is the
same JetStream durable as the Python pool's second trigger — both
pools claim from it competitively, NATS dispatches each pending
message to whichever pod sends the next pull request first.

The generator that produced both YAMLs lives at
[`noetl/core/runtime/keda.py`](https://github.com/noetl/noetl/blob/main/noetl/core/runtime/keda.py)
in the [`noetl/noetl`](https://github.com/noetl/noetl) repo and is
documented on the wiki at
[`noetl/core/runtime/keda`](https://github.com/noetl/noetl/wiki/keda).
A drift guard lives at
[`tests/core/runtime/test_keda.py::test_sample_manifest_matches_generator_output`](https://github.com/noetl/noetl/blob/main/tests/core/runtime/test_keda.py)
and asserts both samples match the generator output verbatim.

KEDA install + apply is a **manual one-off step** today. It is
deliberately not bundled into the stock `noetl k8s deploy` workflow
in this round so the diff stays small and reviewable.

## One-time KEDA install

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version 2.15.0
```

Verify the operator is healthy:

```bash
kubectl get pods -n keda
kubectl rollout status deployment/keda-operator -n keda
```

## Apply both pool scalers

```bash
kubectl apply -f ci/manifests/keda/scaledobject-worker-cpu-01.yaml
kubectl apply -f ci/manifests/keda/scaledobject-worker-rust-pool.yaml
```

## Verify

```bash
# Both ScaledObjects
kubectl get scaledobject -n noetl

# KEDA creates an HPA per ScaledObject behind the scenes
kubectl get hpa -n noetl

# Full status for either pool (active flag, last scale time, trigger health)
kubectl describe scaledobject noetl-worker-scaler-worker-cpu-01 -n noetl
kubectl describe scaledobject noetl-worker-rust-scaler-worker-rust-pool -n noetl
```

To exercise the scalers, drive load through the NATS command stream
(e.g. by submitting playbook executions that fan out work) and watch
both `kubectl get deploy -n noetl noetl-worker` and
`kubectl get deploy -n noetl noetl-worker-rust` replica counts climb
as consumer lag exceeds `lagThreshold` (default 10).  Because both
deployments claim from the same shared consumer, NATS will balance
the dispatch fairly — pods that finish their commands faster pull the
next message sooner regardless of which pool they're in.

## Regenerating after a generator change

Both sample manifests are committed verbatim so the noetl/noetl drift
guard (`tests/core/runtime/test_keda.py::test_sample_manifest_matches_generator_output`)
catches hand-edits.  The guard runs against fixtures under
`noetl/noetl/tests/fixtures/keda/` that mirror these manifest bodies
(header comments here are operator-facing and not part of the fixture
comparison).

To regenerate after a `noetl.core.runtime.keda` change:

```python
from noetl.core.runtime.keda import (
    ScaledObjectSpec, build_worker_scaledobject, dump_scaledobject_yaml,
)

# Python pool (existing)
spec_python = ScaledObjectSpec(
    worker_pool_urn="noetl://tenant/default/org/default/worker/worker-cpu-01",
    deployment="noetl-worker",
    nats_consumer="noetl_worker_pool",
)
print(dump_scaledobject_yaml(build_worker_scaledobject(spec_python)))

# Rust pool (added 2026-06-02)
spec_rust = ScaledObjectSpec(
    worker_pool_urn="noetl://tenant/default/org/default/worker/worker-rust-pool",
    deployment="noetl-worker-rust",
    nats_consumer="noetl_worker_pool",
)
print(dump_scaledobject_yaml(build_worker_scaledobject(spec_rust)))
```

Pipe each output into the matching
`ci/manifests/keda/scaledobject-*.yaml` file, preserving the header
comments.  Update the noetl/noetl fixtures
(`tests/fixtures/keda/scaledobject-*.yaml`) in the same change set
so the drift guard stays green.

## EHDB command bus scaler (L1 T4, shadow) — 2026-07-21

`scaledobject-worker-ehdb-command-bus.yaml` is **not** generated by the
NATS `build_worker_scaledobject` helper — it uses a **Prometheus** trigger
(not `nats-jetstream`) on `sum(ehdb_feed_total_lag)`, the backlog gauge the
per-shard EHDB writer (co-located in the system-pool worker) exposes when
`NOETL_COMMAND_BUS=ehdb`/`shadow` (noetl/ai-meta#194 L1 path A).

It ships **paused** (`autoscaling.keda.sh/paused: "true"`) — the "signal
before cutover" guardrail: KEDA evaluates the metric but does not scale
until the command bus is authoritative on EHDB (T4) and an operator removes
the annotation. It does not replace the NATS-lag scaler; both can coexist
during the shadow window (the NATS one stays active).

Activation prerequisites (part of the gated kind/prod deploy, tracked in the
[cutover runbook](https://github.com/noetl/ehdb/wiki/Runbook-L1-Command-Bus-Cutover)):
the worker runs with `NOETL_COMMAND_BUS_HOST=true` +
`NOETL_COMMAND_BUS_METRICS_BIND`, a VMServiceScrape covers that metrics port,
and `NOETL_COMMAND_BUS_WRITER_DIR` is a PVC. No drift-guard fixture — this is
a hand-authored Prometheus-trigger manifest, not generator output.

## User-pool EHDB-lag trigger (prod) — the T5 prerequisite, 2026-07-30

`scaledobject-worker-rust-prod.yaml` now carries **two** triggers: the
existing `nats-jetstream` one and a new `metrics-api` one reading the
EHDB command-bus backlog off the writer's `:9102` endpoint.

This is the last prerequisite for T5 (deleting NATS) on
[noetl/ai-meta#194](https://github.com/noetl/ai-meta/issues/194). The
command bus is already LIVE on EHDB in prod, so the NATS consumer this
scaler watched has a permanently-zero backlog; at T5 it loses its signal
outright. With only that trigger, deleting NATS would freeze the user
pool at its current slots (`minReplicaCount` 2 × `WORKER_MAX_CONCURRENT`
4 = 8) with nothing able to absorb a burst.

The EHDB trigger is **added, not substituted**. KEDA's HPA reconciler
takes the `MAX` desired-replicas across triggers, so nothing regresses
while NATS is still installed, and removing the NATS trigger becomes a
T5 teardown step rather than a prerequisite for it.

### Why `metrics-api` and not `prometheus`

The prod cluster has **no in-cluster PromQL endpoint**. Monitoring is
Google Managed Prometheus: `PodMonitoring/noetl-cmdbus-writer`
(`ci/manifests/noetl/gmp/podmonitoring-cmdbus-writer.yaml`) scrapes the
writer and the samples land in Cloud Monitoring, queryable over the GMP
HTTP API but not from inside the cluster. The VictoriaMetrics endpoint
the kind sample `scaledobject-worker-ehdb-command-bus.yaml` points at
does not exist here — the `vmservicescrape` CRD is not installed.

Giving KEDA a `prometheus` trigger would mean deploying the GMP query
frontend (`gmp-public/frontend`), which needs a GSA with
`roles/monitoring.viewer` plus a Workload Identity binding. The project
has **no** `monitoring.*` role binding today, so that is a new IAM grant
— human-gated — and it puts a new always-on workload in an autoscaler's
query path. `gcp-stackdriver` has the same IAM problem.

`metrics-api` scrapes the writer's Prometheus endpoint directly,
in-cluster, over the same ClusterIP the workers already claim through:
no IAM, no new workload, and autoscaling does not depend on the
monitoring pipeline being healthy.

### The `valueLocation` is a contract

KEDA's `metrics-api` scaler in `format: prometheus` has **no label
selector** — it prefix-matches `valueLocation` against the whole
`name{labels}` token of each exposition line and returns the first hit
([`metrics_api_scaler.go`](https://github.com/kedacore/keda/blob/v2.15.0/pkg/scalers/metrics_api_scaler.go)).
The ehdb renderer emits sorted, single-label, space-free lines so this
stays stable, and a test in `noetl/ehdb` pins the byte shape. Do not
reformat the value.

### Threshold

`targetValue` is an AverageValue, so `desiredReplicas = ceil(lag /
targetValue)`. At `targetValue: "2"` the pool adds a replica per 2 queued
commands: it reaches its 8-slot capacity in replicas at a backlog of 8,
with headroom already on the way up. Waiting for backlog to exceed
capacity (`targetValue: "4"`) is too late — the noetl/ai-meta#205
saturating-burst measurement showed p50 dispatch spiking to ~2 s purely
from queueing once the slots filled.

### Activate the EHDB lag trigger

**Done on 2026-07-31** — the manifest is now active and this section is the
record of how, plus the procedure for any future pool.

The trigger reads **this pool's own** backlog,
`ehdb_feed_subject_lag{subject="commands.shared.shard.0"}`, which requires a
worker image carrying noetl/worker#197 (≥ **v5.82.0**). Order matters: applying
the per-subject `valueLocation` against an older writer points KEDA at a series
that does not exist, and a `valueLocation` matching no line is a **scaler
error**, not a backlog of 0.

Do not expect to prove anything while paused. KEDA 2.15's
`autoscaling.keda.sh/paused` **deletes the HPA and stops the scaler loop** —
`get hpa` returns nothing, the external-metrics API 404s, and
`.status.externalMetricNames` freezes on whatever trigger was live when it was
paused. So step 1 below only becomes answerable *after* unpausing.

```bash
# 0. Writer first: confirm the per-subject series actually exists.
kubectl -n noetl run lagprobe --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s http://noetl-cmdbus-writer-0.noetl.svc.cluster.local:9102/metrics \
  | grep ehdb_feed_subject_lag
# expect: ehdb_feed_subject_lag{subject="commands.shared.shard.0"} 0

# 1. Apply the manifest (no paused annotation) and unpause any live object.
kubectl -n noetl apply -f scaledobject-worker-rust-prod.yaml
kubectl -n noetl annotate scaledobject noetl-worker-rust \
  autoscaling.keda.sh/paused- --overwrite

# 2. KEDA should now create the HPA and register the external metric.
kubectl -n noetl get hpa
kubectl -n noetl get scaledobject noetl-worker-rust \
  -o jsonpath='{.status.health}{"\n"}{.status.externalMetricNames}{"\n"}'

# 3. Confirm the value served matches the writer.
kubectl -n noetl get --raw \
  "/apis/external.metrics.k8s.io/v1beta1/namespaces/noetl/s0-metric-api-ehdb_feed_subject_lag%7Bsubject=%22commands.shared.shard.0%22%7D"
```

### Rollback

```bash
# Re-pause (instant; the Deployment keeps its current replica count).
kubectl -n noetl annotate scaledobject noetl-worker-rust \
  autoscaling.keda.sh/paused=true --overwrite

# Or drop back to the NATS-only scaler (valid only while NATS still exists).
kubectl -n noetl apply -f \
  https://raw.githubusercontent.com/noetl/ops/<pre-change-sha>/ci/manifests/keda/scaledobject-worker-rust-prod.yaml

# Or remove autoscaling entirely and pin the pool by hand.
kubectl -n noetl delete scaledobject noetl-worker-rust
kubectl -n noetl scale deploy noetl-worker-rust --replicas=2
```

Deleting the ScaledObject also deletes `keda-hpa-noetl-worker-rust`; the
Deployment keeps whatever replica count it had at that moment, so a
manual `scale` afterwards is what sets the floor.

### Per-shard writers

The trigger names one writer (`noetl-cmdbus-writer-0`) because prod runs
a single command shard (`NOETL_COMMAND_SHARD_COUNT=1`). Adding a shard
means adding one `metrics-api` trigger per writer service — KEDA takes
the `MAX` across them, which is the correct aggregation for "some shard
is backed up".
