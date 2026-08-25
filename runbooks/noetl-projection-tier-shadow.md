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
| P1 | server ≥ the release carrying #355 + #356, worker ≥ v5.121.0, both **deployed** | `kubectl --context <prod> -n noetl get deploy -o jsonpath='{..image}'` | ⬜ not deployed |
| P2 | manifests declare the EHDB env and agree with the cluster | `ci/manifests/noetl/ehdb-env-drift-check.sh <prod-context>` | ✅ agrees as of 2026-08-25 |
| P3 | the writer's tier service is listening and its store is on the PVC | §2 below | ⬜ |
| P4 | `noetl_ehdb_projection_*` series exist at 0 on `/metrics` | §2 below | ⬜ |
| P5 | rollback rehearsed — each flag off restores prior behaviour in one rollout | kind `restore` arm | ✅ in kind |

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
