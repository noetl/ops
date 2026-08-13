# Cloud Monitoring alert policies (NoETL prod)

These are **Cloud Monitoring alertPolicies**, not Kubernetes objects. They are
recorded here because until now every alert policy in
`shastaratech-noetl-prod` was created by hand and existed in no repository —
so the only way to answer "what alerts on this platform?" was to query GCP.

## ⚠ There are TWO alerting paths in this project, and only one delivers

This distinction cost a session to discover, so it is written down.

| | GMP `Rules` (in-cluster) | Cloud Monitoring `alertPolicies` |
| :-- | :-- | :-- |
| Defined in | `ci/manifests/noetl/gmp/rules-*.yaml` | this directory |
| Evaluated by | the `rule-evaluator` Deployment in `gke-gmp-system` | Cloud Monitoring |
| Alerts go to | the **managed Alertmanager** StatefulSet in `gke-gmp-system` | the notification channels named in each policy |
| Routing config | secret `alertmanager` (key `alertmanager.yaml`) in ns `gmp-public` | on the policy itself |
| **Does it page anyone today?** | **NO** — that secret does not exist, so alerts route nowhere | **YES** |

`OperatorConfig/config` in `gmp-public` points `managedAlertmanager.configSecret`
at a secret named `alertmanager` which has never been created. Every GMP
alerting rule in `ci/manifests/noetl/gmp/` therefore fires into a void. They are
still useful — the rule state is visible in-cluster — but **an alert that must
reach a human belongs here, not there**, unless and until that secret is
configured.

## Notification channels

Two email channels exist in the project, both enabled:

| id | display name | destination |
| :-- | :-- | :-- |
| `6930211842535753236` | NoETL prod alerts (default) | the platform owner's address |
| `8780236184765331124` | email-shastaratech-alerts | the GCP account address |

Addresses are not repeated here; read them with the command below. The three
EHDB policies route to **both**, because a tier that has stopped serving
authoritatively should not depend on one inbox being watched.

```bash
gcloud --account=<owner> auth print-access-token   # then:
curl -s -H "Authorization: Bearer $TOK" \
  "https://monitoring.googleapis.com/v3/projects/shastaratech-noetl-prod/notificationChannels" | jq .
```

⚠ Neither channel reports a `verificationStatus`. They are `enabled: true` and
one of them already backs five live policies, but **email delivery has not been
positively confirmed by this repo**. If an expected alert never arrives, verify
the channel before assuming the rule is wrong.

## The policies here

| file | fires when | severity |
| :-- | :-- | :-- |
| `ehdb-demoted.json` | any serve decision returns `ServedByIncumbent` while the tier is `primary` | critical |
| `ehdb-divergence.json` | the tier disagrees with the authoritative `noetl.event` log | critical |
| `ehdb-appenderr.json` | tier-store appends fail — the noetl/ai-meta#261 corruption guard | critical |

All three key on counters whose steady state is a flat `0`, so there is no
threshold to tune, and all three use `sum(...)` with **no `by (pod)`**:
`served_primary` is per-pod because the server's mirror relay targets one
Service, so a per-pod rule would fire on idle replicas and mean nothing.

## Applying

```bash
PROJECT=shastaratech-noetl-prod
TOK=$(gcloud --account=<owner> auth print-access-token)

# create
curl -s -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d @ci/monitoring/alertpolicies/ehdb-demoted.json \
  "https://monitoring.googleapis.com/v3/projects/$PROJECT/alertPolicies"

# update an existing one (PATCH, needs the policy name)
curl -s -X PATCH -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d @ci/monitoring/alertpolicies/ehdb-demoted.json \
  "https://monitoring.googleapis.com/v3/$POLICY_NAME"
```

`gcloud alpha monitoring` is **not installed** in this environment and returns a
meaningless `count: 0` rather than an error, so use the REST API and always run
a positive control alongside any query that returns zero.

## Verifying a policy is live rather than merely present

A policy whose query matches nothing is indistinguishable from a healthy one.
Evaluate the condition **and** a positive control:

```bash
# the condition (empty result = not firing)
curl -s -H "Authorization: Bearer $TOK" --data-urlencode \
  'query=sum(increase(noetl_ehdb_dataplane_ops_total{operation="tier_service.append",outcome=~"error|invalid"}[5m])) > 0' \
  "https://monitoring.googleapis.com/v1/projects/$PROJECT/location/global/prometheus/api/v1/query"

# the control — must be non-zero, proving the series is ingested at all
curl -s -H "Authorization: Bearer $TOK" --data-urlencode \
  'query=sum(increase(noetl_ehdb_dataplane_ops_total{operation="tier_service.append",outcome="ok"}[60m]))' \
  "https://monitoring.googleapis.com/v1/projects/$PROJECT/location/global/prometheus/api/v1/query"
```

Measured at creation (2026-08-13): demoted `0` with the series live, appenderr
`0` with `append{ok}=40/hr`, divergence **`8`** — actively firing on a real
open defect, see below.

## ⚠ `ehdb-divergence` is EXPECTED to be firing when applied

At creation, every hourly `system/scheduled_cleanup` execution mirrors **11 of
13** events into the tier; the two missing are both `command.claimed`.
User-pool executions are clean (`29/29`). This is a real open defect on a tier
that is `primary` and serving — not a false positive and not a tuning problem.
Do not silence this policy to make it quiet.
