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

## ROLLOUT RECORD — 2026-06-20 (EXECUTED on prod GKE)

The full rollout below was executed on
`gke_noetl-demo-19700101_us-central1_noetl-cluster` ns `noetl` on
2026-06-20. Prod was left **gate-ON** (CQRS publish-only + off-server
state builder), healthy. The image targets are **v3.39.1 / v5.40.2**
(NOT the v3.29.3 / v5.35.0 the "roll the images first" section below
still names — that section predates this rollout; the sequence is the
same, only the digests moved forward).

**Pre-step — one-time owner-applied `prev_event_id` migration.** The
v3.39.1 write path binds `prev_event_id` on every `noetl.event` /
`noetl.command` INSERT (the gate-off path) and stamps the one-level
chain at the emit chokepoint. The columns did not exist on prod and the
runtime `noetl` role is **not** the table owner (`owner=postgres`;
`noetl` is only a `cloudsqlsuperuser` member, which Cloud SQL restricts),
so the server's startup `ensure_columns` best-effort `ADD COLUMN` is
swallowed (`must be owner of table event`). Applied **as the DB owner**
the operator-authorized additive, idempotent, metadata-only DDL:

```sql
ALTER TABLE noetl.event   ADD COLUMN IF NOT EXISTS prev_event_id BIGINT;
ALTER TABLE noetl.command ADD COLUMN IF NOT EXISTS prev_event_id BIGINT;
CREATE INDEX IF NOT EXISTS idx_event_prev_event_id ON noetl.event (execution_id, prev_event_id) WHERE prev_event_id IS NOT NULL;
```

- **Connection used:** the working `postgres` (owner) credential the
  live `pgbouncer` deployment already carries in its `DATABASE_URLS`
  backend route (`postgres://postgres:****@127.0.0.1:6432/noetl`),
  reached over a `kubectl port-forward` to `svc/pgbouncer` (ns
  `postgres`). No password was rotated, printed, or committed.
- **Cascade:** `noetl.event` (14 partitions) + `noetl.command` (16
  partitions) are partitioned parents; in PostgreSQL 15 the `ADD COLUMN`
  and the non-concurrent partitioned `CREATE INDEX` recurse to every
  partition automatically. Verified: zero table-partitions missing the
  column; `idx_event_prev_event_id` `indisvalid=true`, 14 leaf indexes
  attached.
- **GSM `pg_noetl_k8s` secret — STALE.** The Google Secret Manager
  `pg_noetl_k8s` password is drifted and fails auth; it was NOT used and
  NOT touched. **Recommendation: the operator should rotate / realign
  `pg_noetl_k8s` to the live owner password** so future
  owner-privileged migrations have a managed credential path instead of
  the pgbouncer-embedded value.
- **The `event-chain DDL skipped` WARN PERSISTS by design** after the
  migration — Postgres checks table ownership *before* the
  `IF NOT EXISTS` skip, so the runtime `noetl` role's startup
  `ensure_columns` still errors `must be owner` and is logged-and-
  swallowed. The WARN is cosmetic; the real proof the migration worked
  is a **gate-off event write succeeding** (the INSERT binds the column).

**Rollout — images (gates at safe defaults):**

1. Server → **v3.39.1** (`@sha256:197a6d10…`, tag `c5f8cb2`) via
   `kubectl apply -f ci/manifests/noetl/server-rust-deployment-prod.yaml`.
   Verified `/api/health` `version=3.39.1`, DB+NATS connected.
2. Shared worker pool + system pool → **v5.40.2**
   (`@sha256:41713265…`, tag `48b0bde`). The v3.39.1 plug-in drive routes
   `__orchestrate__` to the **system pool**; the old `cursor-100` workers
   cannot run the v5.40.2 orchestrate protocol (`call.error` →
   `command.failed`, drive stalls), so the workers MUST roll with /
   before the server. Gate-off `test/simple_python` then COMPLETED
   end-to-end with a fully linked `prev_event_id` chain.
3. **Materializer shadow** — `NOETL_MATERIALIZER_ENABLED=true` on the
   system pool (gate still off). Materializer + off-server state-builder
   drain start clean; backlog 0 (gate-off → server publishes nothing, so
   the shadow is idle-healthy).

**The flip (STAGE 2):**

```bash
kubectl --context <ctx> -n noetl set env deploy/noetl-worker-system-pool NOETL_STATE_BUILDER=offserver
kubectl --context <ctx> -n noetl set env deploy/noetl-server-rust NOETL_EVENT_INGEST_PUBLISH_ONLY=true NOETL_STATE_BUILDER=offserver
```

Server logged `NOETL_EVENT_INGEST_PUBLISH_ONLY=ON — … materializer is the
sole writer; the server writes zero event rows`; the system pool logged
`off-server state-builder drain started (WAL drain, zero noetl.event
scans … ephemeral_rebuild=true, mode=Authoritative)`.

**Validation (gate-ON):** 5 tenant executions across `test/simple_python`,
`fixtures/playbooks/hello_world`, `tests/e2e_probe` (incl. 2× concurrent)
all COMPLETED. Per-execution chains `roots=1` / `terminals=1` /
`dangling=0`. Aggregate: server `noetl_event_ingest_published_total` ==
worker `noetl_worker_materializer_acked_total` (= total rows) ⇒
**materializer sole writer**; `noetl_worker_state_builder_event_scans_total
= 0` ⇒ **never-scan holds**; materializer backlog 0 throughout; zero pod
restarts on a 90s soak.

**Revert (one command set, on standby):**

```bash
kubectl --context <ctx> -n noetl set env deploy/noetl-server-rust NOETL_EVENT_INGEST_PUBLISH_ONLY=false NOETL_STATE_BUILDER=server
kubectl --context <ctx> -n noetl set env deploy/noetl-worker-system-pool NOETL_STATE_BUILDER=server
# (the materializer may stay enabled as a harmless idempotent shadow)
```

---

## Production (GKE) — environment specifics (READ FIRST)

The body of this runbook was written against the **kind** dev cluster (a
VictoriaMetrics stack: VMAlert / VMRule / VMServiceScrape, a vmstack
Alertmanager). **Production differs in three load-bearing ways.** A
read-only prep verification on `gke_noetl-demo-19700101_us-central1_noetl-cluster`
(2026-06-19) established the live facts below — verify them again before you
act.

- **`<ctx>` = `gke_noetl-demo-19700101_us-central1_noetl-cluster`**, namespace
  `noetl`. Routing is the `noetl` ClusterIP Service's **selector**
  (`app=noetl-server-rust`), not an Ingress. Prod **already runs the full Rust
  stack** — the Python→Rust cutover (noetl/ai-meta#49) is done. There is no
  Python deployment to keep serving; the "Python stays serving" framing from
  earlier prep briefs is obsolete.

- **Monitoring is Google Managed Prometheus (GMP), NOT VictoriaMetrics.** The
  `vmalert` / `VMRule` / `VMServiceScrape` commands in this runbook do not
  exist on prod. The prod equivalents shipped in
  [`ci/manifests/noetl/gmp/`](../ci/manifests/noetl/gmp/):
  `podmonitoring-noetl.yaml` (GMP `PodMonitoring` — the worker + server scrape)
  and `rules-materializer-lag.yaml` (GMP `Rules` — the same PromQL/thresholds
  as the kind VMRule). Both were **applied during prep** (observability-only,
  non-traffic-affecting). Query backlog/alerts through Cloud Monitoring
  (Managed Prometheus) or the GMP rule-evaluator, not a VMAlert port-forward.
  Alerts route to the **GMP managedAlertmanager** (OperatorConfig `config` in
  `gmp-public` → secret `alertmanager`), not the vmstack Alertmanager.

- **Both flip secrets already exist** (created when the Rust cutover landed,
  ~5 days before this prep): `noetl-secret` carries `NOETL_ENCRYPTION_KEY`
  (alongside `NOETL_PASSWORD` / `POSTGRES_PASSWORD`) and
  `noetl-internal-api-token` carries `token`. The "create the encryption key /
  internal-api token" operator step from the #49 cutover runbook is **done** —
  do not recreate them. (Credential plaintext re-entry was part of that
  cutover, not this flip; the Rust server has been serving credential-backed
  executions since, so it is not a flip prerequisite.)

### Prod prerequisite the kind runbook does NOT mention: roll the images first

The materializer loop + lag poller exist only in **worker v5.35.0**; the
publish-only gate + `noetl_event_ingest_published_total` counter exist only in
**server v3.29.3**. Prod is still on the **pre-#103 images** — live
`noetl-server-rust` runs `server-rust:batch-dispatch-v1` and the system pool
runs `noetl-worker-rust:cursor-100`. **The flip is not possible until the
images roll.** Prep pushed both target images to the prod Artifact Registry
(digests in the prep report / Releases wiki). The roll-forward manifests are
staged, NOT applied:
[`ci/manifests/noetl/server-rust-deployment-prod.yaml`](../ci/manifests/noetl/server-rust-deployment-prod.yaml)
(→ v3.29.3, `NOETL_EVENT_INGEST_PUBLISH_ONLY=false`) and
[`ci/manifests/noetl/worker-system-pool-deployment-prod.yaml`](../ci/manifests/noetl/worker-system-pool-deployment-prod.yaml)
(→ v5.35.0, `NOETL_MATERIALIZER_ENABLED=false`).

**Operator sequence on prod (each step gated, conservative):**

1. **Roll the system pool to v5.35.0** (materializer still `false`):
   `kubectl --context <ctx> -n noetl apply -f ci/manifests/noetl/worker-system-pool-deployment-prod.yaml`.
   This is a rolling update of one system-pool pod — low blast radius (system
   playbooks only), brings in the lag poller so the backlog gauge starts
   reporting. Confirm `noetl_worker_nats_consumer_*` series appear in GMP.
2. **Roll the server to v3.29.3** (gate still `false`):
   `kubectl --context <ctx> -n noetl apply -f ci/manifests/noetl/server-rust-deployment-prod.yaml`.
   This rolls the **live, traffic-serving** `noetl-server-rust` deployment
   (zero-downtime: `maxUnavailable=0`, `maxSurge=1`). Watch gateway 5xx and
   `/api/health` (DB + NATS connected). This is traffic-touching — treat it as
   a normal prod server release, not part of the gate flip.
3. **Enable the materializer as a shadow** — set `NOETL_MATERIALIZER_ENABLED=true`
   on the system pool. Server gate still `false`, so the materializer drains
   the stream idempotently while the server still INSERTs. This is the
   green-baseline check below (backlog ≈ 0).
4. **Wire the pager** (Alert routing section, GMP variant below).
5. **Then, and only then, flip the gate** (The flip section).

Steps 1–2 are the new-image rollout; 3–5 are the actual staged flip the rest of
this runbook describes. Until step 1, the materializer-lag alerts are inert
(their series do not exist yet) — expected, not a fault.

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

### kind (VictoriaMetrics)

Routing on kind is a blackhole catch-all (`ci/vmstack/vmstack-values.yaml`
`alertmanager.config`) — no external receiver is wired. To exercise delivery on
kind: add a receiver under `alertmanager.config.receivers`, a route matching
`noetl.io/flip-guardrail="publish-only"` + `severity=~"critical"`, and
`helm upgrade vmstack …`. With blackhole, alerts still reach `firing` and are
visible in the VMAlert UI/API — routing only governs delivery, not evaluation.

### Production (GKE / Google Managed Prometheus) — OPERATOR-GATED

Prod does NOT use the vmstack Alertmanager. The GMP managed rule-evaluator
sends alerts to the **GMP managedAlertmanager**, configured by OperatorConfig
`config` in namespace `gmp-public`:

```yaml
# kubectl --context <ctx> -n gmp-public get operatorconfig config -o yaml
managedAlertmanager:
  configSecret:
    name: alertmanager        # secret in gmp-public
    key: alertmanager.yaml
```

The receiver/route config lives in the `alertmanager` secret's
`alertmanager.yaml` key. **Prep did NOT touch it** — wiring a real pager needs
the receiver endpoint (Slack webhook / PagerDuty routing key / email), which is
an operator secret this prep does not hold. To wire it:

1. Author an `alertmanager.yaml` with your receiver. **Templated stub**
   (replace the placeholder; pick one receiver type):

   ```yaml
   route:
     receiver: default
     group_by: [alertname, cluster]
     routes:
       # Page the criticals from the CQRS flip guardrail.
       - matchers:
           - 'noetl_io_flip_guardrail="publish-only"'   # GMP sanitizes the `/` and `.` in label names to `_`
           - 'severity="critical"'
         receiver: noetl-flip-pager
         continue: false
   receivers:
     - name: default
     - name: noetl-flip-pager
       # --- PagerDuty (uncomment + fill) ---
       # pagerduty_configs:
       #   - routing_key: <PAGERDUTY_ROUTING_KEY>
       #     severity: critical
       # --- or Slack (uncomment + fill) ---
       # slack_configs:
       #   - api_url: <SLACK_WEBHOOK_URL>
       #     channel: '#noetl-prod-alerts'
       #     title: '{{ .CommonAnnotations.summary }}'
       #     text: '{{ .CommonAnnotations.description }}  Runbook: {{ .CommonAnnotations.runbook_url }}'
   ```

   > Note: GMP rewrites label names with `/` or `.` to `_` in the rule
   > pipeline, so the alert label `noetl.io/flip-guardrail` is matched as
   > `noetl_io_flip_guardrail` in the Alertmanager route. Confirm the rewritten
   > name on a live firing alert before relying on the matcher.

2. Replace the secret (it currently exists with a default/empty config):

   ```bash
   kubectl --context <ctx> -n gmp-public create secret generic alertmanager \
     --from-file=alertmanager.yaml=./alertmanager.yaml \
     --dry-run=client -o yaml | kubectl --context <ctx> -n gmp-public apply -f -
   ```

   The GMP operator reloads the managed Alertmanager automatically; no
   OperatorConfig edit is needed (it already points at this secret).

Until this is wired, the criticals still **evaluate and fire** in GMP (visible
in Cloud Monitoring / the rule-evaluator) — only delivery is missing. Treat
pager wiring as a hard prerequisite before flipping the gate in prod: the flip
makes materializer availability load-bearing, and an un-paged critical defeats
the guardrail.

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
