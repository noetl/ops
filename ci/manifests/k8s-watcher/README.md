# noetl-k8s-watcher

External K8s Job watcher that observes `Job` state transitions
in the `noetl` namespace and POSTs terminal-state events to
`noetl-server`'s container-callback endpoint
(`POST /api/internal/container-callback/{execution_id}/{step}`).

Round 1 of the
[Container Tool Callback umbrella](https://github.com/noetl/ai-meta/wiki/Umbrella-Container-Tool-Callback)
([noetl/ai-meta#43](https://github.com/noetl/ai-meta/issues/43)).
The server-side endpoint shipped in Round 2 (noetl/server v2.48.0,
[server#141](https://github.com/noetl/server/pull/141)); this round
puts a watcher in front of it.

## Why this exists

The Rust Tool::Container (Round 3, [noetl/tools#36](https://github.com/noetl/tools/issues/36))
will create a K8s Job and return immediately — the worker slot
frees as soon as the create-Job RPC returns.  Without a watcher,
the playbook would stall: nothing tells `noetl-server` when the
Job finishes.

This watcher closes the loop.  It watches all Jobs in the `noetl`
namespace, filters by the `noetl.execution-id` label (only Jobs
NoETL dispatched), and POSTs the terminal-state payload to the
server's callback endpoint on every transition to a terminal
state.

## MVP shape

A small shell wrapper around `kubectl get jobs --watch -o json`
piped through `jq` and `curl`.  Per
[noetl/ops#166](https://github.com/noetl/ops/issues/166), shell is
acceptable for round 1 — the *contract* (POST body shape, label
selector, terminal-state mapping) is what unblocks the umbrella.
A pure-Rust binary is a clean follow-up once the watcher proves
valuable in production.

## What lands here

| File | Purpose |
| :-- | :-- |
| [`rbac.yaml`](rbac.yaml) | ServiceAccount + ClusterRole (`Jobs/get,list,watch` cluster-scoped, namespaced to `noetl`) + ClusterRoleBinding |
| [`configmap.yaml`](configmap.yaml) | Watcher config — `NOETL_SERVER_URL`, `NOETL_K8S_WATCH_NAMESPACE`, `NOETL_K8S_WATCH_LABEL_SELECTOR` |
| [`deployment.yaml`](deployment.yaml) | Single-replica Deployment running the watcher entrypoint |
| [`watcher.sh`](watcher.sh) | The watcher entrypoint script (delivered via ConfigMap mount) |

## Contract — what the watcher POSTs

For each terminal-state Job transition, the watcher POSTs to:

```
POST {NOETL_SERVER_URL}/api/internal/container-callback/{execution_id}/{step}
Content-Type: application/json
Authorization: Bearer <NOETL_INTERNAL_API_TOKEN>

{
  "state":        "<succeeded|failed|failed_image_pull|failed_oom|failed_node_lost|failed_timeout>",
  "job_name":     "<Job.metadata.name>",
  "job_uid":      "<Job.metadata.uid>",
  "completed_at": "<RFC3339 timestamp of the transition>",
  "exit_code":    <Pod.containerStatuses[0].state.terminated.exitCode, or null>,
  "reason":       "<short reason string, or null>"
}
```

`execution_id` and `step` come from the Job's labels:
`noetl.execution-id` and `noetl.step-name` respectively.  Jobs
that don't carry both labels are ignored (they weren't dispatched
by NoETL).

## Terminal-state mapping

K8s Job + Pod conditions → `TerminalState` enum (matching the
[umbrella's failure-mode taxonomy](https://github.com/noetl/ai-meta/wiki/Umbrella-Container-Tool-Callback#failure-mode-taxonomy)):

| K8s signal | `state` value |
| :-- | :-- |
| `.status.conditions[?(@.type=="Complete")].status == "True"` (exit 0) | `succeeded` |
| `.status.conditions[?(@.type=="Failed")].status == "True"` with `reason == "BackoffLimitExceeded"` | `failed` |
| Pod's container `state.waiting.reason == "ImagePullBackOff"` for > 60s | `failed_image_pull` |
| Pod's container `state.terminated.reason == "OOMKilled"` | `failed_oom` |
| Pod's `status.reason == "NodeLost"` or `Evicted` pre-Complete | `failed_node_lost` |
| `.status.conditions[?(@.type=="Failed")].status == "True"` with `reason == "DeadlineExceeded"` | `failed_timeout` |

## Idempotency

The watcher's POST is idempotent per `(execution_id, step,
job_name)` tuple — `noetl-server`'s container-callback handler
(Round 2) returns 202 on a duplicate POST and won't double-emit
the `call.done` event.  The watcher may safely retry on transport
errors.

## Stale callbacks

When the watcher POSTs for an execution that doesn't exist on the
server side (gc'd, watcher pointing at the wrong namespace, Job
created out-of-band), the server returns 202 with
`status: "accepted_stale"` and bumps
`noetl_container_callback_stale_total`.  Stale rates are an
operator alert signal — not a watcher bug.

## Kind validation

Round 1 kind-val (manifest only — no real Job dispatch yet):

```bash
# 1. Apply the watcher manifests.
kubectl --context kind-noetl apply -k ci/manifests/k8s-watcher/
kubectl --context kind-noetl -n noetl rollout status deploy/noetl-k8s-watcher

# 2. Manually create a labeled Job.
kubectl --context kind-noetl -n noetl create job ctc-test --image=alpine -- sh -c 'echo hello; exit 0'
kubectl --context kind-noetl -n noetl label job ctc-test \
  noetl.execution-id=900000000000000001 \
  noetl.step-name=test_step

# 3. Wait for the Job to complete.
kubectl --context kind-noetl -n noetl wait --for=condition=complete job/ctc-test --timeout=60s

# 4. Watcher should POST within ~5s; server logs the call.
kubectl --context kind-noetl -n noetl logs deploy/noetl-k8s-watcher | grep ctc-test
# Expected: "noetl-k8s-watcher: posted callback for ctc-test (succeeded)"

# Server side (Round 2):
kubectl --context kind-noetl -n noetl logs deploy/noetl-server | grep container-callback
# Expected: "container-callback: stale" (no execution exists for that id)
#           AND noetl_container_callback_stale_total{state="succeeded"} = 1
```

## Out of scope for round 1

- **Pure-Rust binary** — the shell wrapper is the MVP; a Rust port
  is a clean follow-up once the contract is stable.
- **mTLS** — bearer token only for round 1.  mTLS lands when the
  rest of `/api/internal/*` flips to peer-cert auth.
- **Multi-namespace support** — single `noetl` namespace.
- **Helm chart packaging** — plain manifests under
  `ci/manifests/k8s-watcher/` for round 1.

## Related

- [Container Tool Callback umbrella](https://github.com/noetl/ai-meta/wiki/Umbrella-Container-Tool-Callback)
- Server endpoint: [noetl/server#141](https://github.com/noetl/server/pull/141) (v2.48.0)
- This round: [noetl/ops#166](https://github.com/noetl/ops/issues/166)
- Round 3 (Tool side): [noetl/tools#36](https://github.com/noetl/tools/issues/36)
- Round 5 (e2e val): [noetl/e2e#29](https://github.com/noetl/e2e/issues/29)
