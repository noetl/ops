# Operator Runbook — Production cutover: Python `noetl-server` → Rust `noetl-server-rust`

> ✅ **ALREADY EXECUTED — historical record (verified live 2026-06-19).** The
> Python→Rust cutover this runbook describes **has happened** in prod. On
> `gke_noetl-demo-19700101_us-central1_noetl-cluster` ns `noetl`: the `noetl`
> Service selector is `app=noetl-server-rust`; there is **no Python
> deployment**; `noetl-server-rust` (1/1), `noetl-worker-rust` (2/2), and
> `noetl-worker-system-pool` (1/1) all run the Rust stack; both secrets
> (`NOETL_ENCRYPTION_KEY` on `noetl-secret`, `noetl-internal-api-token`) are
> present. The live images are the **pre-#103** generation
> (`server-rust:batch-dispatch-v1`, `noetl-worker-rust:cursor-100`). The next
> prod change is the **CQRS PUBLISH_ONLY flip** — see
> [`noetl-cqrs-publish-only-flip.md`](noetl-cqrs-publish-only-flip.md), whose
> "Production (GKE) — environment specifics" section is the current source of
> truth for prod. Keep this file as the cutover audit trail; do not re-run it.

**Scope:** Flip the production GKE control plane from the Python FastAPI
`noetl-server` to the Rust `noetl/server` crate (`noetl-control-plane`),
on cluster `gke_noetl-demo-19700101_us-central1_noetl-cluster`.

**Tracks:** [noetl/ai-meta#49](https://github.com/noetl/ai-meta/issues/49) Phase F R5.

**Audience:** the operator (you) with **write** access to the prod cluster.
Everything in this file is an operator action — an AI prep session built the
image and these artifacts but is **not** authorized to provision prod secrets,
apply the Deployment, flip the Service selector, or scale Python down.

> **Golden rule.** Production traffic does not move until you flip the `noetl`
> Service selector (step 6). Everything before that is additive and safe.
> Rollback is one command (step 8) and takes seconds.

> 🛑 **ATTEMPT 1 (2026-06-13) FAILED — a server-only flip is NOT viable.**
> Flipping the `noetl` Service to the Rust server while keeping the **Python
> workers** breaks execution: the Rust server publishes commands to the
> hierarchical subject `noetl.commands.{pool}.{execution_id}`
> (`repos/server/src/handlers/execute.rs:1137`), but prod's NATS stream + the
> Python workers use the flat `noetl.commands` → `POST /api/execute` returns
> `500 NATS publish ack failed: no stream found for given subject`. The Rust
> **worker** is what consumes the hierarchical subjects.
> **The cutover must be the FULL Rust stack — Rust server + Rust worker, with
> Python server AND workers scaled to 0** (the kind-validated config). The
> single-step "flip the selector" below is necessary but not sufficient; it
> must be paired with deploying the Rust worker pool, provisioning a NATS
> stream that captures `noetl.commands.>`, and scaling the Python workers down.
> See [noetl/ai-meta#49](https://github.com/noetl/ai-meta/issues/49) postmortem
> 2026-06-13 for the full sequence. Also: Rust stores encrypted credentials as
> a JSON envelope (`{...}`), so `left(data_encrypted,1)='{'` does NOT prove a
> credential is plaintext — verify by reading `data` back through the serving
> server.

---

## 0. What's already prepped (by the prep session)

- ✅ Rust server image **built for linux/amd64** and pushed to the prod
  Artifact Registry from noetl/server commit `4644c49` (= release `v3.5.0`
  commit `7b217d8` **plus** a `time =0.3.47` build-fix pin — the bare v3.5.0
  commit does **not** compile; see note below):
  - `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/server-rust:4644c49`
  - `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/server-rust:v3.5.0`
  - Immutable digest: **`sha256:78cce8f3790bcc74c7e94d15a4486c67be868757621b00d1da6fa6c8a6b929fa`**
    (Cloud Build `00a26c26`, linux/amd64) — the manifest pins this digest.
- ✅ Prod manifest: [`ci/manifests/noetl/server-rust-deployment-prod.yaml`](../ci/manifests/noetl/server-rust-deployment-prod.yaml)
- ✅ Cloud Build config: [`automation/gcp_gke/assets/server/cloudbuild.yaml`](../automation/gcp_gke/assets/server/cloudbuild.yaml)

> **Why `4644c49` and not the bare `v3.5.0` tag.** Release commit `7b217d8`
> (`chore(release): version 3.5.0`) fails to compile: `time 0.3.48` (released
> 2026-06-12) collides with `async-nats 0.38` via an E0119 conflicting-impl
> under rustc 1.91+. The fix is a one-line `time =0.3.47` pin (already present
> in noetl-tools/worker/gateway). Commit `4644c49` is `7b217d8` + that pin;
> server PR: see #49. Land that PR so future server image builds work.

Nothing above touched the running cluster. Prod is still 100% Python.

## Current prod baseline (verify before you start)

```bash
PROD=gke_noetl-demo-19700101_us-central1_noetl-cluster
kubectl --context $PROD -n noetl get deploy,svc,pods
```

Expect: `noetl-server` Deployment 1/1 (image `noetl:coalesce-*`, cmd
`["python"]`), `noetl-worker` 3/3, Service `noetl` (selector
`app=noetl-server`, port `8082/TCP` only). Routing: the `gateway` LoadBalancer
(ns `gateway`, ext IP `34.46.180.136`) → env
`NOETL_BASE_URL=http://noetl.noetl.svc.cluster.local:8082` → the `noetl`
Service. The "flip" repoints that Service's selector.

---

## ⚠️ Three blocking decisions — resolve these BEFORE touching prod

### Decision A — Credential encryption (the big one)

**Finding:** prod Python's credential "encryption" is a **no-op placeholder**.
`repos/noetl/noetl/core/secret.py::encrypt_json` just does `json.dumps` — the
module docstring says so ("we only serialize/deserialize JSON without applying
cryptography"). So the `noetl.credential.data_encrypted` column holds
**plaintext JSON** in prod today.

The Rust server uses **real AES-GCM envelope encryption** keyed by
`NOETL_ENCRYPTION_KEY`. It reads `data_encrypted` as a sealed envelope and runs
an AEAD verify/decrypt.

**Consequence:** there is **NO Python key to "match"** — Python has no key.
A plaintext-JSON row will **fail** the Rust AEAD decrypt. After cutover, any
playbook step that resolves a stored credential alias will **fail closed**
(credential resolution error → `call.error` → execution FAILED; see
`no-default-connection.md`). This is silent until a credential-using playbook
runs.

**What you must do — pick ONE:**

1. **Re-enter credentials after cutover (expected path).** Generate a fresh
   key, set it (step 2a), cut over, then re-create every credential via the
   Rust server's `POST /api/credentials` (which encrypts properly). First
   inventory what's stored:

   ```bash
   PGPOD=$(kubectl --context $PROD -n postgres get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
   # count + names of stored credentials (read-only):
   kubectl --context $PROD -n postgres exec $PGPOD -- \
     psql -U noetl -d noetl -c "SELECT name, type, left(data_encrypted, 1) AS first_char FROM noetl.credential ORDER BY name;"
   ```

   A `first_char` of `{` or `[` confirms plaintext JSON (not a Rust envelope).
   Keep a list; you'll re-POST each one after cutover.

2. **Pre-migrate (optional, advanced).** Write a one-off that reads each
   plaintext row and re-POSTs it through a *canary* Rust server (step 5) so the
   data is already Rust-encrypted before the flip. Only worth it if the
   credential set is large or zero-downtime credential use is required.

**Getting it wrong:** if you set a key but skip re-entry, the server starts
fine and health is green, but the FIRST playbook that uses a stored credential
fails. Test a credential-using playbook during canary (step 5) before flipping.

### Decision B — pgbouncer transaction-mode pooling (sqlx compatibility) — RESOLVED

Prod has **no direct postgres Service**. The DB is **Cloud SQL**
(`noetl-demo-19700101:us-central1:noetl-shared-pg`) reached through
`pgbouncer.postgres.svc` running **`pool_mode=transaction`** (in front of a
`cloud-sql-proxy` sidecar). Confirmed live 2026-06-12.

sqlx's default named prepared-statement cache breaks under transaction pooling
(`prepared statement "sqlx_s_N" does not exist`). **Handled:** the Rust server
gained `NOETL_PG_STATEMENT_CACHE_CAPACITY` ([noetl/server#191](https://github.com/noetl/server/pull/191)),
and `server-rust-deployment-prod.yaml` sets it to `0` — sqlx then uses one-shot
unnamed statements that are safe behind transaction pooling. The Rust server
stays behind pgbouncer exactly like Python; **no pgbouncer change needed.**

Operator check (optional — confirm the env made it into the running pod after
step 4): `kubectl -n noetl exec deploy/noetl-server-rust -- env | grep STATEMENT_CACHE`
→ `NOETL_PG_STATEMENT_CACHE_CAPACITY=0`. The real proof is the canary
(step 5): a query-heavy playbook completing without `prepared statement` errors.

### Decision C — Arrow Flight gRPC (port 8083) — N/A in prod

The kind manifest's `noetl` Service exposes port 8083 (Arrow Flight gRPC), but
the **prod `noetl` Service exposes only `8082/TCP`** — there is no 8083 port in
prod, no Flight refs in any prod workload, and no `:8083` connections to the
server pod (verified 2026-06-12). Nothing depends on it; the selector flip is
safe. No action required.

---

## Pre-flight checklist (tick ALL before step 6 / the flip)

- [ ] **A** — Credential strategy chosen; stored-credential inventory captured;
      a fresh `NOETL_ENCRYPTION_KEY` generated and set in `noetl-secret`.
- [ ] **B** — RESOLVED: prod pgbouncer is transaction-mode; manifest sets
      `NOETL_PG_STATEMENT_CACHE_CAPACITY=0`. Confirm a query-heavy canary
      playbook runs clean (step 5).
- [ ] **C** — N/A: prod `noetl` Service has no 8083/Flight port. No action.
- [ ] `noetl-internal-api-token` secret exists (step 2b).
- [ ] Rust Deployment applied and pod **Ready** (step 4); `/api/health` shows
      `database: connected` **and** `nats: connected`.
- [ ] Canary checks pass against `noetl-server-rust` Service, including a
      **credential-using playbook** (step 5).
- [ ] Rollback command (step 8) is in your paste buffer.
- [ ] A second operator is watching gateway 5xx / error rate during the flip.

---

## Step 1 — (Optional) re-verify the image digest

The image is already pushed. To confirm / capture the immutable digest:

```bash
gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/server-rust:4644c49 \
  --format='value(image_summary.digest)'
```

Pin that `sha256:...` into the `image:` line of
`server-rust-deployment-prod.yaml` (uncomment the digest line, comment the tag
line) so a re-pushed tag can't change what prod runs.

To rebuild from scratch instead:

```bash
cd <noetl/server checkout at 4644c49>
gcloud builds submit . \
  --config=<ops>/automation/gcp_gke/assets/server/cloudbuild.yaml \
  --project=noetl-demo-19700101 --region=us-central1
```

## Step 2 — Provision the two prod secrets

### 2a — `NOETL_ENCRYPTION_KEY` into `noetl-secret`

Generate a base64-encoded 32-byte key and add it as a key on the EXISTING
`noetl-secret` (do not replace the secret — patch it so `NOETL_PASSWORD` /
`POSTGRES_PASSWORD` survive):

```bash
KEY=$(openssl rand -base64 32)
kubectl --context $PROD -n noetl patch secret noetl-secret --type=merge \
  -p "{\"data\":{\"NOETL_ENCRYPTION_KEY\":\"$(printf %s "$KEY" | base64)\"}}"
# verify the key set now lists NOETL_ENCRYPTION_KEY alongside the two existing keys:
kubectl --context $PROD -n noetl get secret noetl-secret -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```

> **Store `$KEY` in your secret manager.** Losing it means losing access to
> every credential the Rust server encrypts. Rotating it later requires
> re-encrypting all credentials.

### 2b — `noetl-internal-api-token`

```bash
TOKEN=$(openssl rand -hex 32)
kubectl --context $PROD -n noetl create secret generic noetl-internal-api-token \
  --from-literal=token="$TOKEN"
```

> This token gates `/api/internal/*`. The system worker pool (if/when deployed)
> must carry the same value. Store it in your secret manager.

## Step 3 — (If pinning by digest) finalize the manifest image

Confirm `server-rust-deployment-prod.yaml`'s `image:` line points at the digest
from step 1 (preferred) or the `:7b217d8` tag (acceptable but mutable).

## Step 4 — Apply the Rust Deployment + Service (NON-traffic-affecting)

This creates a parallel `noetl-server-rust` Deployment + Service. The `noetl`
Service still points at Python — **no traffic moves.**

```bash
kubectl --context $PROD -n noetl apply -f \
  <ops>/ci/manifests/noetl/server-rust-deployment-prod.yaml

kubectl --context $PROD -n noetl rollout status deploy/noetl-server-rust --timeout=180s
kubectl --context $PROD -n noetl get pods -l app=noetl-server-rust
```

If the pod is **not** Ready, diagnose before going further:

```bash
kubectl --context $PROD -n noetl describe pod -l app=noetl-server-rust | tail -40
kubectl --context $PROD -n noetl logs -l app=noetl-server-rust --tail=80
```

Common first-boot failures:
- `CreateContainerConfigError` → a referenced secret/key is missing (step 2).
- Crash with "Refusing to start ... NOETL_ENCRYPTION_KEY is not set" → step 2a.
- `prepared statement ... already exists` → Decision B (pgbouncer pool mode).

## Step 5 — Canary / shadow against the Rust Service (still no flip)

Port-forward the Rust Service and exercise it directly:

```bash
kubectl --context $PROD -n noetl port-forward svc/noetl-server-rust 18082:8082 &
PF=$!

# Health — REQUIRE database:connected AND nats:connected:
curl -s http://localhost:18082/api/health | jq .

# Read endpoints (compare a few against the Python server for parity):
curl -s http://localhost:18082/api/health
curl -s -X POST http://localhost:18082/api/catalog/list -H 'content-type: application/json' -d '{}' | jq 'length'

# **Credential-using playbook** — the Decision-A check.  Run a known
# credential-backed playbook end-to-end and confirm it reaches COMPLETED
# (NOT a credential-resolution failure).  If it fails on the stored credential,
# re-enter that credential via POST /api/credentials against :18082 first.

kill $PF 2>/dev/null
```

Do not proceed to the flip until health is green AND a credential-using
execution completes against the Rust server.

## Step 6 — THE FLIP (traffic moves here) 🔴

Single command. The `noetl` Service's NEG re-targets to the Rust pods; the
gateway env is unchanged.

```bash
kubectl --context $PROD -n noetl patch svc noetl \
  -p '{"spec":{"selector":{"app":"noetl-server-rust"}}}'

# confirm endpoints now resolve to the Rust pod IP(s):
kubectl --context $PROD -n noetl get endpoints noetl -o wide
```

## Step 7 — Verify live (immediately after the flip)

```bash
# through the public gateway:
curl -s http://34.46.180.136/api/health | jq .   # or the gateway's public hostname
```

Watch for ~5–15 min:
- **Gateway 5xx / error rate** — should stay at baseline. Any spike → rollback.
- **Rust pod** `/api/health` (DB + NATS connected), logs for ERROR lines.
- **NATS continuity** — in-flight executions keep transitioning (no stall at
  `command.started`); new `/api/execute` calls return an `execution_id` and
  complete.
- **SSE** — `/api/executions/{id}/events/stream` keeps streaming to the UI.
- **Credential CRUD** — a credential-using playbook completes (Decision A).

## Step 8 — ROLLBACK (if anything looks off) 🟢

One command, seconds to take effect. Python is still running (you have NOT
scaled it down yet):

```bash
kubectl --context $PROD -n noetl patch svc noetl \
  -p '{"spec":{"selector":{"app":"noetl-server"}}}'
kubectl --context $PROD -n noetl get endpoints noetl -o wide   # back to Python pod IP
```

**Roll back if:** gateway 5xx rises above baseline, `/api/health` shows
DB/NATS not connected, executions stall, SSE breaks, or a credential-using
playbook fails. Investigate with Python serving; re-attempt the flip after
fixing root cause.

## Step 9 — Scale Python down (ONLY after Rust is confirmed healthy)

Do this only after a sustained green window (suggest ≥30 min) on Rust:

```bash
kubectl --context $PROD -n noetl scale deploy noetl-server --replicas=0
```

> Keep the Python Deployment at `replicas=0` (not deleted) for a few days so
> rollback stays a 2-command operation: scale Python back to 1, flip the
> selector back. Delete it only once Rust is proven over time.

---

## Quick reference

| Action | Command |
| :-- | :-- |
| Apply Rust (no traffic) | `kubectl -n noetl apply -f ci/manifests/noetl/server-rust-deployment-prod.yaml` |
| **Flip → Rust** | `kubectl -n noetl patch svc noetl -p '{"spec":{"selector":{"app":"noetl-server-rust"}}}'` |
| **Rollback → Python** | `kubectl -n noetl patch svc noetl -p '{"spec":{"selector":{"app":"noetl-server"}}}'` |
| Scale Python to 0 | `kubectl -n noetl scale deploy noetl-server --replicas=0` |
| Scale Python back | `kubectl -n noetl scale deploy noetl-server --replicas=1` |

(Prefix every command with `--context gke_noetl-demo-19700101_us-central1_noetl-cluster`.)

## Post-cutover follow-ups (not part of the flip)

- Update [`ci/manifests/noetl/server-rust-deployment.yaml`](../ci/manifests/noetl/server-rust-deployment.yaml)
  header note (it still says "kind validation only").
- Decide the fate of port 8083 (Flight) — implement in Rust or retire from the
  `noetl` Service.
- Wire `NOETL_ENCRYPTION_KEY` into any credential-migration tooling and the
  system worker pool's expectations.
- Close [noetl/ai-meta#49](https://github.com/noetl/ai-meta/issues/49) only
  after Rust serves prod healthily and Python is scaled to 0.
