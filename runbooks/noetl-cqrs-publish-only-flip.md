# Operator Runbook — CQRS `NOETL_EVENT_INGEST_PUBLISH_ONLY` flip

**Scope:** Flip the NoETL control plane from synchronous `noetl.event`
INSERTs to the CQRS write path, where the server **publishes** every event
to the `noetl_events` JetStream stream and the worker-side **materializer**
becomes the sole `noetl.event` writer.

**Tracks:** [noetl/ai-meta#103](https://github.com/noetl/ai-meta/issues/103)
(CQRS event-log cutover) — the server is **flip-ready** (all three blockers
closed: ack-after-materialize durability, off-server-drive×gate
reconciliation, the two ExecutionService cancel/finalize sites). The only
remaining gate is **operator observability**: this runbook + the
materializer-lag alerts.

**Audience:** the operator with **write** access to the target cluster.

> **Golden rule.** The flip is reversible in one command. Setting
> `NOETL_EVENT_INGEST_PUBLISH_ONLY=false` on `noetl-server` makes the server
> resume synchronous INSERTs immediately; the materializer keeps draining
> whatever it already had (idempotent `ON CONFLICT`, so no double rows). The
> flip is **staged**: turn the materializer on as a harmless shadow FIRST,
> confirm it is healthy, and only then flip the server gate.

> **Default is OFF.** `NOETL_EVENT_INGEST_PUBLISH_ONLY` ships default-off in
> every environment. Production is NOT flipped by landing this runbook — the
> flip is a deliberate operator action taken against this gate.

---

## Why this gate exists

Under `PUBLISH_ONLY` the server writes **zero** `noetl.event` rows. Every
event is published to `noetl_events`; the materializer loop on the system
worker pool (`NOETL_MATERIALIZER_ENABLED=true`,
`repos/worker/src/materializer.rs`) drains the stream and POSTs
`/api/internal/events/project`, acking each batch **only after** a durable
insert. If that loop falls behind or dies, published events pile up
un-materialized and the event log silently stops advancing — the orchestrator
reads a stale log, replay misses data, audit gaps open.

"Materializer availability is now load-bearing" (the
[cutover design note](https://github.com/noetl/docs/blob/main/docs/architecture/cqrs_write_path_cutover.md)).
The materializer-lag alerts are how the operator sees that condition before it
becomes data loss, and the revert is how they stop it.

---

## The signals (what the alerts watch)

All defined in
[`ci/manifests/noetl/vmrule-materializer-lag.yaml`](../ci/manifests/noetl/vmrule-materializer-lag.yaml),
evaluated by VMAlert, visualized by the
[materializer dashboard](../ci/manifests/grafana-dashboards/noetl-materializer-configmap.yaml).

| Metric | Owner | Meaning |
| :-- | :-- | :-- |
| `noetl_worker_nats_consumer_pending{stream="noetl_events",consumer="noetl_materializer"}` | worker (lag poller) | events in the stream not yet delivered to the materializer |
| `noetl_worker_nats_consumer_ack_pending{…}` | worker (lag poller) | delivered to the materializer, not yet acked (in-flight) |
| `noetl:materializer_backlog` (recording rule) | derived | `max(pending + ack_pending)` — total un-materialized events |
| `noetl_event_ingest_published_total` | server | events PUBLISHED to the stream — **moves only when the gate is ON** |
| `noetl_worker_materializer_projected_total` / `_acked_total` | worker | events inserted / batches acked by the materializer |
| `noetl_worker_materializer_project_errors_total` | worker | `events/project` POST failures (batch redelivers; no loss) |

The backlog gauge is reported by the lag poller on an **independent task**, so
a stalled or dead materializer loop — which cannot report its own lag — still
surfaces as a climbing gauge.

---

## Alerts and what they mean

### `MaterializerBacklogWarning` (warning)
Backlog > 200 for 10m. The materializer is falling behind. Investigate the
system pool; not yet a revert condition. Check `events/project` latency and DB
health.

### `MaterializerBacklogCritical` (critical / page)
Backlog > 2000 for 5m. The log is not keeping up. **If the gate is ON,
execute the revert** (below), then diagnose while the materializer drains.

### `MaterializerBacklogGrowing` (critical / page)
Backlog > 200 **and** rising for 15m. A slow leak the static thresholds would
miss until large. Same response as critical.

### `MaterializerStalledUnderGate` (critical / page)
The server is publishing (gate ON, active) but the materializer has acked
nothing for 5m — the sole writer is stuck mid-batch or down. **Execute the
revert immediately**, then diagnose. This is the sharpest data-loss-risk
signal.

### `MaterializerProjectErrors` (warning)
`events/project` is failing; batches redeliver (no loss by design) but
materialization is stalled until the server sink recovers. Check noetl-server
logs + DB.

### `MaterializerAbsentUnderGate` (critical / page)
Publishing under the gate but **no** materializer metrics are scraped — the
system-pool worker is not running. The log is not being written. **Execute the
revert** and restore the system pool.

---

## Pre-flip — green-baseline check (REQUIRED before flipping)

The flip is staged. Step 1 (materializer-on) is a **harmless shadow** while the
server still writes synchronously (`events/project` is idempotent), so the
baseline check runs in shadow before any gate change.

1. **Monitoring is live.** VMAlert is running and has selected the rule:
   ```bash
   kubectl --context <ctx> -n vmstack get vmalert
   # rule loaded + group present:
   kubectl --context <ctx> -n vmstack port-forward svc/vmalert-vmstack-victoria-metrics-k8s-stack 8080:8080 &
   curl -s localhost:8080/api/v1/rules | jq '.data.groups[] | select(.name=="noetl-materializer-lag") | .rules[].name'
   ```
2. **Materializer ON as shadow.** Set `NOETL_MATERIALIZER_ENABLED=true` on the
   system pool (`worker-system-pool-deployment*.yaml`). Server gate still OFF.
3. **Backlog ~0.** Confirm the green baseline — the materializer is draining
   the shadow stream as fast as it fills:
   ```bash
   curl -s localhost:8080/api/v1/query --data-urlencode 'query=noetl:materializer_backlog' | jq '.data.result'
   # expect a single sample near 0
   ```
4. **No firing alerts** in the `noetl-materializer-lag` group:
   ```bash
   curl -s localhost:8080/api/v1/alerts | jq '.data.alerts[] | select(.labels.component=="materializer") | {name:.labels.alertname, state}'
   # expect [] or all "inactive"
   ```
5. **Throughput matches.** `projected/s` tracks `published/s` would be zero
   here (gate still off), but `noetl_worker_materializer_acked_total` should be
   advancing from the shadow drain with `duplicates` only (no loss). Confirm on
   the dashboard "published vs projected vs acked" panel.

Do **not** proceed to the flip until the baseline is green and stable for a
sustained window (≥ 15–30 min under representative load).

---

## The flip

```bash
# Server: stop synchronous INSERTs; publish to noetl_events instead.
kubectl --context <ctx> -n noetl set env deploy/noetl-server-rust \
  NOETL_EVENT_INGEST_PUBLISH_ONLY=true
kubectl --context <ctx> -n noetl rollout status deploy/noetl-server-rust
```

Confirm the startup log line:
`NOETL_EVENT_INGEST_PUBLISH_ONLY=ON — … materializer is the sole writer`.

### During / after the flip — what to watch

- `noetl:materializer_backlog` stays near 0 (transient spikes ≤ one batch are
  normal). A sustained climb is the materializer not keeping up.
- "published vs projected vs acked" panel: all three rise together. **Published
  rising while acked is flat = `MaterializerStalledUnderGate` → revert.**
- `noetl_event_ingest_published_total` now advances (it was flat pre-flip) —
  this is the gate confirming itself active.
- Run a smoke playbook; confirm it reaches its terminal state and the event
  rows appear in `noetl.event` (written by the materializer, not the server).

---

## Revert (one command)

If any **critical** alert fires, or the backlog climbs without draining:

```bash
kubectl --context <ctx> -n noetl set env deploy/noetl-server-rust \
  NOETL_EVENT_INGEST_PUBLISH_ONLY=false
kubectl --context <ctx> -n noetl rollout status deploy/noetl-server-rust
```

The server resumes synchronous INSERTs the moment the new pod is ready.
Anything already published to `noetl_events` is still drained by the
materializer and inserted idempotently (`ON CONFLICT` → duplicates counted,
never double rows). Leave the materializer enabled through the revert — it
drains the in-flight backlog harmlessly. No data is lost across the revert:
the published-but-not-yet-materialized events are durable in JetStream until
acked.

After reverting, the backlog should drain to 0 and all alerts clear. Diagnose
the materializer (system-pool logs, `events/project` errors, DB health) before
attempting the flip again.

---

## Alert routing

Routing today is a blackhole catch-all (`ci/vmstack/vmstack-values.yaml`
`alertmanager.config`) — no external receiver is wired. **Before flipping in
production**, wire the criticals to a real pager:

1. Add a receiver (Slack/PagerDuty) under `alertmanager.config.receivers`
   (commented examples are in the values file).
2. Add a route matching `noetl.io/flip-guardrail="publish-only"` +
   `severity=~"critical"` to that receiver (commented example under
   `alertmanager.config.route.routes`).
3. Re-apply the vmstack values (`helm upgrade vmstack …`).

With blackhole, alerts still reach `firing` and are visible in the VMAlert
UI/API and the dashboard — routing only governs delivery, not evaluation.

---

## Kind validation (how this was proven)

The metric + rules were validated end-to-end on the local kind cluster:
deploy the VM stack, confirm `noetl:materializer_backlog` ≈ 0 at steady state,
then **induce lag** (pause the materializer while events publish under the
gate), confirm the backlog gauge climbs and the alert transitions to firing,
resume the materializer, and confirm the backlog drains to ~0 and the alert
clears. The induce → fire → recover → clear cycle is the proof the alert
catches a falling-behind materializer, not just that the rule deploys. See the
session log entry for noetl/ai-meta#103 and the worker
`NOETL_MATERIALIZER_FAULT_FAIL_FIRST` knob (deterministic redelivery
injection) used to exercise the path.
