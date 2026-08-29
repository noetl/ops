# pgbouncer — declared, and no longer holding a stale password

## ⚠⚠ Do not apply this directory blind

Two prerequisites must exist first. Applying without them **takes the pooler
down**, and with it every NoETL component — which is precisely the failure mode
[noetl/ai-meta#267](https://github.com/noetl/ai-meta/issues/267) is about.

Apply the files **individually**, never `kubectl apply -f` on the directory.

## Why this file exists at all

Until 2026-08-29 the prod pgbouncer Deployment was **declared nowhere**. It ran
only in the cluster, so there was nothing to review, nothing to diff, and nothing
to restore from. It was found while fixing
[noetl/ai-meta#311](https://github.com/noetl/ai-meta/issues/311), and the outage
that prompted it is a good illustration of the cost: the pooler was rescheduled
by Autopilot, regenerated its userlist from a stale inline `DATABASE_URLS`, and
every database connection failed for hours.

Captured from the live Deployment rather than written from memory, so a DR apply
reproduces what runs: image `edoburu/pgbouncer:v1.24.1-p1`, SA `cloudsql-proxy`,
the cloud-sql-proxy sidecar's exact args, both tcpSocket probes, all eleven
non-secret env values, and the Autopilot-adjusted resources.

## What changed vs. the live object

1. **The userlist is seeded from a Secret Manager CSI mount** before the image's
   entrypoint runs. A reschedule can no longer reinstate a stale password.
2. **`DATABASE_URLS` moves from an inline literal to a `secretKeyRef`.** The live
   value is a plaintext string containing four users' passwords; that shape is
   what [#310](https://github.com/noetl/ai-meta/issues/310) is about, and it must
   not be committed.

Everything else is byte-for-byte the live spec.

## Prerequisite 1 — IAM (owner)

pgbouncer's SA `cloudsql-proxy` maps to GSA `noetl-cloudsql-proxy@…`, which today
holds **only `roles/cloudsql.client`**. Without Secret Manager access the CSI
mount fails and the container never starts.

```bash
gcloud secrets add-iam-policy-binding noetl-postgres-password \
  --member="serviceAccount:noetl-cloudsql-proxy@shastaratech-noetl-prod.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
```

## Prerequisite 2 — the `pgbouncer-database-urls` Secret (owner)

`DATABASE_URLS` is referenced, not inlined, so the Secret must exist or the pod
will not start. Creating it means handling the value, so the owner runs it.

The value is the **same string the live Deployment already carries**; copy it
from the running object without printing it:

```bash
kubectl -n postgres get deploy pgbouncer -o \
  jsonpath='{.spec.template.spec.containers[?(@.name=="pgbouncer")].env[?(@.name=="DATABASE_URLS")].value}' \
  | kubectl -n postgres create secret generic pgbouncer-database-urls \
      --from-file=DATABASE_URLS=/dev/stdin
```

⚠ Do this **before** the rollout, and note that the `noetl` password inside it is
now irrelevant — the CSI mount supplies that user. The other three users still
authenticate from this string; retiring them is the separate, parked
weak-credential work.

## Apply

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
kubectl --context "$CTX" apply -f secretproviderclass.yaml
kubectl --context "$CTX" apply -f deployment.yaml
kubectl --context "$CTX" -n postgres rollout status deploy/pgbouncer --timeout=5m
```

## Verify

```bash
# the userlist came from the mount (masked — never print the value)
kubectl --context "$CTX" -n postgres exec deploy/pgbouncer -c pgbouncer -- \
  awk '{printf "%s %s…(%d chars)\n", $1, substr($2,1,3), length($2)-2}' /etc/pgbouncer/userlist.txt

kubectl --context "$CTX" -n noetl get pods   # the platform should heal on its own
```

## Rollback

```bash
kubectl --context "$CTX" -n postgres rollout undo deploy/pgbouncer
```

⚠ **Rollback restores the stale-password config** — the state that caused the
outage. It is not a safe resting place. If this fix fails, the fallback is the
userlist reload in `noetl/ai-meta` `playbooks/secret-manager/RECOVER-ROTATION-MISMATCH.md`.

## Evidence

Kind-proven against the real image and a real Postgres, eight arms — including
the two that matter: a pod restart regenerates a byte-identical userlist and auth
still succeeds, and a **stale wrong password left in `DATABASE_URLS` with the
correct one mounted still authenticates**, which is prod's exact situation. A
positive control (wrong value on the mount → `SASL authentication failed`) makes
both non-vacuous. Full table: `noetl/ai-meta` `playbooks/311-pgbouncer-durable-fix/README.md`.
