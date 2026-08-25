# Runbook — arming the EHDB projection tier in shadow on prod

**STATUS: PREPARED, NOT EXECUTED.** No step below has been run against
production. Every step needs an explicit go from the owner, one step at a time.

**Tracks:** [noetl/ai-meta#265](https://github.com/noetl/ai-meta/issues/265) ·
Ordering and rationale: `ai-meta:playbooks/265-projection-tier/CUTOVER.md` ·
Kind evidence: `RESULTS.md`, `RESULTS-B1.md`, `RESULTS-G3.md` in the same
directory.

---

## 0. The constraint that outranks everything here

**The event-log tier (tier 1) is `primary` and serving.** No step in this
runbook reads, writes, or restarts `NOETL_EHDB_EVENTLOG`. If a step appears to
need it moved, the step is wrong — stop and re-read CUTOVER.md.

⚠ **The default kubectl context is PRODUCTION.** Every command below names its
context explicitly. A command here without `--context` is a bug in this file.

## 1. Preconditions

| # | precondition | check | status |
| :-- | :-- | :-- | :-- |
| P1 | server ≥ v3.86.0, worker ≥ v5.121.0, both **deployed** | count `noetl_ehdb_projection*` series on `/metrics` — **0 means the binary has no tier**, and the flags would be inert. See §1a Blocker 2. | ❌ **BLOCKING** — prod runs server v3.83.1 / worker v5.120.0 |
| P2 | manifests declare the EHDB env and agree with the cluster | `ci/manifests/noetl/ehdb-env-drift-check.sh <prod-context>` | ✅ agrees as of 2026-08-25 — but see §1a Blocker 1: **do not apply them** |
| P3 | the writer's tier service is listening and its store is on the PVC | §2 below | ⬜ |
| P4 | `noetl_ehdb_projection_*` series exist at 0 on `/metrics` | §2 below | ⬜ |
| P5 | rollback rehearsed — each flag off restores prior behaviour in one rollout | kind `restore` arm | ✅ in kind |


## 1a. TWO BLOCKERS FOUND ON THE FIRST ATTEMPT (2026-08-25). Read before §3.

Recorded here rather than in a session log, because both would have made C1
*wrong* rather than merely fail, and neither is visible from the runbook's own
steps.

### Blocker 1 — these manifests must NOT be `kubectl apply`-ed to prod

`ops#268` made the **EHDB slice** of the prod manifests correct. It did not make
the files applyable, and they are not. Measured with `kubectl diff` (server-side
dry run, read-only) on 2026-08-25:

| manifest | what an apply would do |
| :-- | :-- |
| `server-rust-deployment-prod.yaml` | remove ~22 live env vars — the entire object-store config, all four result-cell vars, and **all three Auth0 variables** — and roll the image to a digest in the **retired** `noetl-demo-19700101` project |
| `worker-rust-deployment-prod.yaml` | remove 10 live env vars incl. `NOETL_COMMAND_BUS`; roll the image backwards |
| `worker-system-pool-deployment-prod.yaml` | remove 20+ live env vars incl. `NOETL_INTERNAL_API_TOKEN` and `NOETL_KEYCHAIN_ENV_VARS`; roll the image backwards |
| `cmdbus-writer-statefulset-prod.yaml` | **0 lines changed — a genuine no-op** (it was captured from the live object) |

So the EHDB env in those files is a **declaration**, not an apply target, until
[ai-meta#267](https://github.com/noetl/ai-meta/issues/267) closes. **C1 is
performed with `kubectl set env`** — §3 below already does — which touches only
the named variables and is reversible in one command.

Re-check before trusting this table again:
`kubectl diff -f ci/manifests/noetl/<file>` — it is read-only.

### Blocker 2 — the running binaries do not contain the projection tier

**The C1 flags would have been inert AND silent.** Measured on prod:

| | running | needs | evidence |
| :-- | :-- | :-- | :-- |
| `noetl-server-rust` | **v3.83.1** | **v3.86.0** | **0** `noetl_ehdb_projection*` series on `/metrics` (41 `..._eventlog_mirror*` for contrast) |
| `noetl-worker-rust` | **v5.120.0** | **v5.121.0** | 0 `noetl_ehdb_projection*` series; `noetl_worker_build_info{version="5.120.0"}` |

Setting `NOETL_EHDB_PROJECTION_MIRROR_SOURCE=server` on v3.83.1 does nothing at
all — and an operator reading "shadow armed, zero divergence" would conclude the
tier agrees with the incumbent, from a binary that has no tier. That is the
inert-and-silent shape this whole issue exists to prevent
(`agents/rules/representation-drift.md`).

The worker half matters independently: without v5.121.0 the `POST
/ehdb/tiers/projection` route does not exist, and axum answers **405** because
the GET route does. The mirror classifies that as `unconfigured` with the
message "is it rolled" — the code anticipates exactly this.

**P1 is therefore a real gate, not a formality.** Both images exist in Artifact
Registry and are ready:

```
server-rust      v3.86.0   sha256:a4a8c6b4c182f634e0c04bfb93735e243b8a59b1c2ec9446b69d77030e23639d
noetl-worker-rust v5.121.0 sha256:df206c794b5bccf631ff5a5b11d74993d2b1a0270ca82ab55cb30cefc3429522
```

The server gap is exactly three merged PRs and **all three are #265's own**
(#350, #355, #356) — no unrelated change rides along. The worker gap is one
(#277).

Rolling them is a **separate decision from arming the shadow**, with its own
blast radius: it would be the first server roll since 2026-08-19 and it touches
the user pool that serves live traffic. Roll by digest, one workload at a time,
worker first — a worker that can accept the append before a server that can send
one is the ordering that never produces a 405.

## 2. Pre-flight — read-only, safe to run now

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot

# The projection variables must be ABSENT (or at their off values) before we start.
kubectl --context "$CTX" -n noetl get deploy,sts -o json \
  | jq -r '[.items[].spec.template.spec.containers[]?.env[]?
            | select(.name|startswith("NOETL_EHDB_PROJECTION"))
            | "\(.name)=\(.value)"] | .[]'
# EXPECT: only NOETL_EHDB_PROJECTION=shadow on the three worker deployments.
# Anything with a _MIRROR_SOURCE / _PARITY_ENABLED / _READ_SOURCE suffix means
# someone has started already — STOP and find out who.

# Tier 1 must be untouched, before and after every step below.
kubectl --context "$CTX" -n noetl get deploy -o json \
  | jq -r '.items[]|.metadata.name as $n
           |(.spec.template.spec.containers[]?.env[]?|select(.name=="NOETL_EHDB_EVENTLOG")|"\($n): \(.value)")'
# EXPECT: primary on all three worker deployments.

# The tier service, from inside the cluster (NOT through a port-forward —
# a bound local port silently routes curl to whatever cluster owns it).
kubectl --context "$CTX" -n noetl exec noetl-cmdbus-writer-0 -- \
  sh -c 'nc -z 127.0.0.1 9110 && echo tier-service-open || echo tier-service-SHUT'

# The projection series must be PRESENT at 0. Absent means the server predates
# #265 — prometheus prunes empty families, so absent and zero are different
# answers and only one of them means "ready".
kubectl --context "$CTX" -n noetl exec deploy/noetl-server-rust -- \
  sh -c 'wget -q -O - http://127.0.0.1:8082/metrics' \
  | grep -E '^noetl_ehdb_projection_(read|mirror|snapshot_gate)_total' | head -20
```

## 3. Step C1 — arm the mirror (write-only). **NEEDS A GO.**

Server only. The worker's `NOETL_EHDB_PROJECTION=shadow` and tier-service
address are already in place.

```bash
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  NOETL_EHDB_PROJECTION_MIRROR_SOURCE=server \
  NOETL_EHDB_PROJECTION_PARITY_ENABLED=true
kubectl --context "$CTX" -n noetl rollout status deploy/noetl-server-rust --timeout=300s
```

**What changes:** the server appends one record per snapshot upsert. **Nothing
reads the tier.** `NOETL_EHDB_PROJECTION_READ_SOURCE` stays `postgres`.

⚠ This makes `orch_snapshot::save` do a synchronous relay POST. `save` is called
from the inline orchestrator self-write, so this is on a request path. If turn
latency regresses, that is why — G3 (§5) is the fix, not a rollback, but
rolling back is always available and always correct.

**Rollback:** unset both; one rollout. The mirror only appends and never touches
`noetl.projection_snapshot`, so there is nothing to undo in the incumbent.

**Watch for 30 minutes:**
```bash
kubectl --context "$CTX" -n noetl exec deploy/noetl-server-rust -- \
  sh -c 'wget -q -O - http://127.0.0.1:8082/metrics' \
  | grep -E 'noetl_ehdb_projection_mirror_total|noetl_ehdb_projection_snapshot_gate_total'
```
- `mirror_total{outcome="mirrored"}` climbing ⇒ working.
- `{outcome="unconfigured"}` ⇒ the relay URL is missing, or the worker is not
  rolled far enough to accept the POST. The tier is silently empty; fix before
  reading anything else.
- **`snapshot_gate_total` is the one to actually watch.** It has never been
  observed moving end-to-end — kind could not reach it. If `written` stays 0
  while the others climb, the incumbent is writing no snapshots at all and every
  parity number below is about an empty population.

## 4. Step C2 — soak. Measurement, no go needed.

Minimum **7 days**, or until all three are answerable:

1. **Coverage** — `written / sum(snapshot_gate_total)`. If this is near zero,
   the soak has not started, whatever the divergence count says.
2. **Divergence** — `crossstore_divergence_total{tier="projection"}` at 0 with
   `crossstore_events_compared_total{tier="projection"}` non-trivial.
3. **Controls** — `projection_control_total{result="unexpected"}` at 0 **and**
   `{result="expected"}` moving. A comparator that cannot detect divergence
   reports zero divergence, and so does a healthy platform.

**Do not read (2) without (1) and (3) in the same breath.**

## 5. Step C3 — G3, the async mirror. **NEEDS A GO. Set BOTH.**

```bash
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  NOETL_EHDB_PROJECTION_MIRROR_ASYNC=true \
  NOETL_EHDB_PROJECTION_PARITY_LAG_TOLERANCE_SECS=30
```

**Set both or neither.** With the window at 0 the server *refuses to arm* and
stays inline — safe, and visible as `..._async_enabled 0` plus a
`REFUSING to arm the async projection mirror` line. That refusal is the designed
behaviour, not a failure.

Confirm it armed rather than refused:
```bash
kubectl --context "$CTX" -n noetl exec deploy/noetl-server-rust -- \
  sh -c 'wget -q -O - http://127.0.0.1:8082/metrics' \
  | grep -E 'projection_mirror_async_enabled|projection_parity_lag_tolerance'
kubectl --context "$CTX" -n noetl logs deploy/noetl-server-rust --tail=200 \
  | grep -E 'projection mirror queue (ARMED|REFUSING)'
```

Then set the window from evidence, not from this file: read
`noetl_ehdb_projection_mirror_lag_seconds` p99 and set the window just above it.
A wider window is a longer blind spot.

## 6. Step C4 — `verify` reads. **NEEDS A SEPARATE GO.**

```bash
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  NOETL_EHDB_PROJECTION_READ_SOURCE=verify
```

First step where a read can come from the tier. It **cannot** serve a wrong
answer: the incumbent is loaded first and the tier is served only on agreement.

**Abort immediately if any of these move:** `version_ahead`, `checksum`,
`no_body`, `divergent`, `unreadable`, `undeserialisable`.
`version_ahead` is the one that matters — it means the tier claimed to have
folded an event that does not exist.

**Expected and not faults:** `missing`, `no_incumbent`, `unconfigured`,
`stale_within_window`.

**Rollback:** `NOETL_EHDB_PROJECTION_READ_SOURCE=postgres`; one rollout; the read
path returns to a plain `SELECT` with no relay call.

## 7. Step C5 — `tier` reads. **NEEDS A SEPARATE GO, and read CUTOVER.md §2 first.**

Not scheduled. `tier` mode makes the tier's snapshot an **input** to the
incumbent's next snapshot via `/api/internal/projection/advance`, so a wrong
served value would be written back and the comparator would then report `match`.
Only after `verify` has soaked with `served_tier` dominating and every fault
class flat at 0.

## 8. Not authorised by this runbook

- Retiring `noetl.projection_snapshot`. It stays: it is the demote target.
- Any change to `NOETL_EHDB_EVENTLOG`.
- More than one variable per rollout (except the C3 pair, which is one decision).
- Applying `cmdbus-writer-statefulset-prod.yaml`. It is a capture of the running
  object, checked in so an apply *would* be a no-op — verifying that is its own
  task.
