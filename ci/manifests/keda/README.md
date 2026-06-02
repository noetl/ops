# KEDA autoscaling for NoETL workers

This directory holds the KEDA `ScaledObject` manifests that scale the
two worker Deployments based on NATS JetStream consumer lag:

- **`scaledobject-worker-cpu-01.yaml`** — Python `noetl-worker`
  deployment.  The original scaler from the v2-spec Phase 4 round.
- **`scaledobject-worker-rust-pool.yaml`** — Rust `noetl-worker-rust`
  deployment.  Added 2026-06-02 alongside R-3 Phase B-4 dual-scaling.

Both scalers point at the **same** NATS stream + consumer
(`NOETL_COMMANDS` / `noetl_worker_pool`), because both deployments
claim from the same shared consumer.  NATS dispatches each pending
message to whichever pool's pod sends the next pull request, so the
two pools naturally share load without any per-pool subject filter.
KEDA scales each Deployment independently against the same lag metric
— total active pods will be roughly 2× a single-pool config but total
throughput stays the same because the consumer is shared.

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
