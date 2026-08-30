# Runbook — the D1 durability window

The window is the interval between an append being **acknowledged** and that
record being durable on the substrate. Records inside it exist on **one disk**:
losing the writer's node loses them.

Instrumented by [noetl/ehdb#328](https://github.com/noetl/ehdb/issues/328), live
on prod since worker **v5.125.1**.

## ⚠⚠ Read the right port

The writer pod hosts **two independent L0 engines**:

| bus | data dir | metrics port |
| :-- | :-- | :-- |
| command | `/data/cmdbus` | `9102` |
| **event (the `primary` tier)** | `/data/eventbus` | **`9106`** |

Both render `ehdb_l0_*` names. **A reading from 9102 says nothing about the event
log.**

```bash
kubectl -n noetl exec noetl-cmdbus-writer-0 -c noetl-worker -- \
  sh -c "wget -qO- 127.0.0.1:9106 | grep -E 'unreplicated|replicated_lag|durability_sample_ok'"
```

⚠ Use `exec`, **not** `kubectl port-forward` — port-forward fails open, and a
bound local port has previously routed a "kind" check straight into prod.

⚠ Port 9106 binds ~37 s after process start, after the three group resumes. A
probe run earlier gets `Connection refused`; that is a **timing artifact, not a
defect**. Confirm against the pod's own `endpoint up` log line.

## The metrics

| metric | meaning |
| :-- | :-- |
| `ehdb_l0_unreplicated_age_seconds{shard}` | age of the **oldest** acked record not yet durable — the window itself |
| `ehdb_l0_unreplicated_records{shard}` | how many such records |
| `ehdb_l0_replicated_lag_seconds` | append → substrate-durable, as a histogram |
| `ehdb_l0_durability_sample_ok` | whether the scrape managed to sample at all |

Every shard is pinned to a row, so **an idle shard reads `0` rather than
vanishing**. Absence means the binary predates the metric.

## ⚠⚠ Three readings that will mislead you

1. **`upload_lag_micros_total`** — measured from the **seal**, not the append. A
   record waiting in an unsealed active part contributes **zero**. On a quiet
   shard that is the dominant term, so this reads healthy in exactly the failing
   case. It is a post-seal diagnostic, never the SLO.
2. **`mean_upload_lag_micros`** — a mean. A durability window is bounded by its
   **maximum**; a mean of 50 ms is consistent with a p99 of 30 s.
3. **`ehdb_feed_shard_lag` / `ehdb_feed_total_lag`** — **consumer backlog**, not
   replication lag. Adjacent name, unrelated meaning, and the one an alert author
   reaches for first.

## Why the window is currently unbounded, by design

`should_seal()` triggers on `seal_max_bytes` (8 MiB) or `seal_max_records`
(1024) and — until [ehdb#329](https://github.com/noetl/ehdb/issues/329) is
**enabled** — never on age. A record reaches the substrate only when its part
seals. So a shard that appends a few records and goes quiet holds them
indefinitely.

**The system is least durable where it is least active**, which inverts the
intuition most people bring.

Observed on prod 2026-08-30: `unreplicated_age` **387 → 497 s monotonic** on 4
records with `replicated_lag_seconds_count 0`, while `ehdb_feed_total_lag 0` and
`out_of_order_appends 0` reported perfect health at the same instant.

## Alert policies

Four, in `ci/monitoring/alertpolicies.json`. **None is applied.**

⚠⚠ **Three of the four are gated on ehdb#329 being enabled, not merely on
approval.** With no age trigger the window is legitimately unbounded on a quiet
shard, so `EhdbUnreplicatedWindowExceeded`, `…Stalled` and the seal-trigger
positive control would page for an accepted condition.

**`the durability window could not be sampled` is safe to enable now** — it does
not depend on `seal_max_age`.

## Responding

| reading | means |
| :-- | :-- |
| age high, `records` small, `replicated_lag_count` climbing | replication is working, this shard is just quiet — expected until #329 |
| age high, `replicated_lag_count` **0** since start | nothing has *ever* replicated in this process. Check the substrate path exists and is writable |
| `durability_sample_ok 0` sustained | the window is **unobserved**; treat readings in that period as unknown, not healthy |
| age flat at 0 with `ehdb_l0_appends 0` | genuinely idle — correct, not a fault |

⚠ Remediation for a sustained window is **enabling `NOETL_EHDB_SEAL_MAX_AGE`**,
which is owner-gated and touches the live writer. See
[the four-gate plan](https://github.com/noetl/ai-meta/blob/main/playbooks/324-four-gates/README.md).

⚠ And note what a healthy window does **not** buy today: the substrate shares the
writer's PVC ([ehdb#332](https://github.com/noetl/ehdb/issues/332)), so
replication currently adds **no independent failure domain**. A perfect window
over one disk is still one disk.
