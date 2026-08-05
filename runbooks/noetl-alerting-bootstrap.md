# Bootstrapping alerting on prod — what exists, what is missing, what to do

**As of 2026-08-05 there is no alerting on `shastaratech-noetl-prod`.** Not
misconfigured — absent. This runbook records the measured state and the order
of operations, because applying rules alone produces nothing.

## Measured state

```
GMP rules / clusterrules / globalrules / prometheusrules   0    (cluster-wide)
Cloud Monitoring alertPolicies                             0
Cloud Monitoring notificationChannels                      0

PodMonitoring (ns noetl)                                   1    writer only
ClusterPodMonitoring                                       2    gke-managed
```

Collection is real: `prometheus.googleapis.com/ehdb_*` returns 11 ingested
series. The API works, the project is right, metrics flow — nothing evaluates
them, and there is nowhere for an alert to go.

> The first attempt to check this used `gcloud alpha monitoring policies list`,
> which is not installed and returned **"count: 0"** — a meaningless zero that
> looks exactly like the real answer. Every number above came from the
> Monitoring REST API with a positive control (the same call returning non-zero
> metric descriptors). Re-verify the same way.

## Order of operations

Alerting needs three things, and only the third is in this repo today.

### 1. Collection — partly missing

| target | declared | applied | note |
| :-- | :-- | :-- | :-- |
| `noetl-cmdbus-writer` cmdbus-lag + metrics | yes | **yes** | the only live scrape |
| `noetl-cmdbus-writer` **events-lag (9106)** | **added in this PR** | no | `ehdb_events_*` is ingested by nothing today |
| `noetl-server-rust` | yes (`podmonitoring-noetl.yaml`) | **no** | `noetl_server_*` descriptors: 0 |
| worker pools | yes (`podmonitoring-noetl.yaml`) | **no** | |

`podmonitoring-noetl.yaml` is **correct and simply unapplied** — its selectors
(`app: noetl-server-rust`, and the worker `matchExpressions`) match live pod
labels, and the named ports (`http:8082`, `metrics:9090`) exist on the live
containers. Verified 2026-08-05. It needs applying, not fixing.

### 2. Notification channels — none exist

With zero channels a firing rule notifies nobody. **Choosing the channel and
who pages is an ownership decision and is deliberately not proposed here.**

### 3. Rules — proposed in this PR

`rules-ehdb-platform.yaml`, seven alerts, each tied to an incident that
actually happened:

| alert | would have caught |
| :-- | :-- |
| `EhdbOutOfOrderAppends` | noetl/ai-meta#203 delivery loss (17/40 commands stuck) |
| `EhdbUncleanWriterRestart` | noetl/ai-meta#209 unsealed tail |
| `EhdbCommandBacklog{Warning,Critical}` | noetl/ai-meta#210 user pool unscaled for a week |
| `EhdbNoAppends` | a silently broken ingest path |
| `EhdbEventsGroupLag` | the 3h24m consumer wedge behind a green dashboard |
| `EhdbEventsCursorErrors` | non-durable consumer progress |

## What is NOT covered by cluster alerting

`publish-ar` has failed on **every** release (noetl/ai-meta#211) and no
Prometheus rule can see that — it is a GitHub Actions outcome, not a cluster
metric. It needs GitHub-side notification (branch protection, a required check,
or a workflow that reports failure) rather than a GMP rule. Recording it here so
the gap is not assumed covered by this work.

## Suggested first cut

Do not enable all seven at once into a fresh channel. `EhdbNoAppends` is the
most likely to be noisy on a quiet cluster — prod is idle for long stretches and
the window wants tuning against a real traffic profile first.

Start with the two zero-threshold integrity alerts
(`EhdbOutOfOrderAppends`, `EhdbEventsCursorErrors`): steady state is exactly 0,
so they cannot be noisy, and both indicate durable-log damage.
