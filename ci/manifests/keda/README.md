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
