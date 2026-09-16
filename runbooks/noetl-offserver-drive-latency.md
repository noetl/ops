# Operator Runbook — off-server drive per-hop latency safety net

**Scope:** The latent monitoring safety net for the off-server orchestrate
drive's per-hop latency, covering both failure modes of
[noetl/ai-meta#156](https://github.com/noetl/ai-meta/issues/156).

**Tracks:** [noetl/ai-meta#156](https://github.com/noetl/ai-meta/issues/156)
(tail-attach per-hop latency fix) and
[noetl/ai-meta#130](https://github.com/noetl/ai-meta/issues/130)
(off-server drive per-hop latency / event-signalled drive). The deeper
remediation lever is the event-stream / event-log GC direction in
[noetl/ai-meta#104](https://github.com/noetl/ai-meta/issues/104).

**Audience:** any on-call operator. These alerts are **WARNING** only.

> **Golden rule.** There is **NOTHING to do for the alert itself.** No flag to
> flip, no image to roll, no revert. These alerts do not signal an outage —
> planner turns still complete, they just get slower. The alert is a *latent
> safety-net* telling you the per-hop drive cost is drifting up. The actual
> remediation, when it fires and stays firing, is to **bound / GC the
> `noetl_events` JetStream stream and the `noetl.event` log** so the
> per-execution drive tail (and any cold rebuild) stays cheap — the
> [#104](https://github.com/noetl/ai-meta/issues/104) result-tier-GC
> direction. That is a deliberate, separate change, not a panic action.

---

## Background — what the drive does and why it can drift

Each orchestrate hop builds its drive state from the worker-side WAL index.
The [#156](https://github.com/noetl/ai-meta/issues/156) tail-attach fix
(server **v3.48.0** + worker **v5.48.0**, `NOETL_OFFSERVER_ATTACH_TAIL=true`)
makes the server ship a **bounded per-execution event tail** on the
`__offserver_build__` dispatch, so the worker applies it to its WAL index and
the build cost is **O(execution tail)** rather than **O(global event log)**.

Without the tail (or when it arrives late), a hop's build can fall back to
walking the large, ever-growing prod `noetl.event` — the per-hop latency
variance and the ~8s drain-lag reconcile cliff documented in
[#130](https://github.com/noetl/ai-meta/issues/130) and
[#156](https://github.com/noetl/ai-meta/issues/156). Because this
deployment's traffic is **low**, that drift would never show up in a load
test — it shows up slowly, as the event log grows. These alerts are the
signal that catches it.

## Signals (metrics, verified against prod worker v5.48.0)

All on the worker `/metrics` (`:9090`), scraped by the `noetl-workers`
PodMonitoring (`gmp/podmonitoring-noetl.yaml`). The drive runs on the
**system pool** (`noetl-worker-system-pool`), which runs the orchestrate
`wasm` plugin.

| Metric | Meaning |
| :-- | :-- |
| `noetl_worker_state_builder_drive_builds_total{outcome="served"\|"fallback_incomplete"\|"fallback_disabled"}` | Per-hop drive build outcome. Healthy = all `served`. |
| `noetl_worker_state_builder_drive_wait_total{outcome="woken"\|"timeout"}` | Build-retry waits: `woken` by the drain append signal (fast) vs `timeout` at the per-wait cap (slow reconcile). |
| `noetl_worker_state_builder_tail_total{kind="attached"\|"applied_new"}` | Tail-attach activity: `attached` = shipped on dispatch; `applied_new` = new to the pool-side index (drain hadn't caught up). |
| `noetl_worker_dispatch_duration_seconds{tool_kind="wasm"}` | Per-hop drive dispatch latency histogram. |

**Healthy baseline (verified 2026-06-28):** drive builds 100% `outcome="served"`
(0 fallback); wasm dispatch p95 ≈ **0.8s**, mean ≈ 0.22s; `tail_total` all
`kind="attached"` with `applied_new=0` (drain keeping up).

---

## OffserverDriveFallbackCliff

**Fires when:** over 10m, more than **5%** of off-server drive builds complete
as `fallback_incomplete` (rather than `served`), with a denominator-rate
traffic guard so it stays silent when idle.

**What it means:** the per-execution WAL tail isn't reaching the worker in
time, so hops are dropping to the slow reconcile path. The #156 per-hop
latency win is eroding.

**What to do:**

1. **Nothing for the alert itself.** Confirm planner turns are still
   completing (they will be — this is latency, not failure).
2. Check `noetl_worker_state_builder_tail_total` — a rising `applied_new`
   fraction means the WAL drain is lagging behind the attached tail.
3. Check whether the prod `noetl.event` / `noetl_events` stream has grown
   large (see [Event-stream growth](#event-stream-growth-the-underlying-lever)).
4. If sustained, the remediation is the [#104](https://github.com/noetl/ai-meta/issues/104)
   event-stream / event-log GC direction — a deliberate, separate change.

**What NOT to do:** do not flip `NOETL_OFFSERVER_ATTACH_TAIL`, do not roll the
worker/server image, do not touch the result-store / OQ5 / shadow config. None
of those is the lever.

## OffserverDriveReconcileWaits

**Fires when:** over 10m, more than **50%** of off-server drive build-retry
waits hit the per-wait `timeout` cap (slow reconcile path) instead of being
`woken` by the drain's append signal, with a small absolute floor (~0.6
timeouts/min) so a single stray timeout in a near-idle window doesn't trip it.

**What it means:** the event-signalled drive
([#130](https://github.com/noetl/ai-meta/issues/130)) is no longer keeping up —
hops are waiting on WAL data that arrives after the cap. Trends the same way as
the fallback cliff.

**What to do:** same as [OffserverDriveFallbackCliff](#offserverdrivefallbackcliff)
— nothing for the alert itself; the lever is event-stream GC ([#104](https://github.com/noetl/ai-meta/issues/104)).

## OffserverDriveDispatchLatencyP95High

**Fires when:** the off-server drive per-hop dispatch p95
(`noetl:offserver_drive_dispatch_p95_seconds`, computed from
`noetl_worker_dispatch_duration_seconds{tool_kind="wasm"}`) has been above
**2s** for 10m. Healthy prod p95 is ≈0.8s. The quantile is NaN when there is
no drive traffic, so the alert stays silent under idle.

**What it means:** the **slow-drift** signal — per-hop drive cost creeping up
as the event log grows, *without* a load spike and possibly *without* any
fallback. This is the one designed to catch the low-load case where everything
is technically "served" but each build is reading more and more.

**What to do:**

1. **Nothing for the alert itself.** Planner turns complete, just slower.
2. Correlate with event-log size (below). A p95 rising in lockstep with
   `noetl.event` row count is the textbook log-growth creep.
3. The remediation is the [#104](https://github.com/noetl/ai-meta/issues/104)
   event-stream / event-log GC direction.

---

## Event-stream growth — the underlying lever

Because all three alerts share one root cause (the drive reading a growing
event surface), the single remediation is bounding the event stream:

- Inspect the `noetl_events` JetStream stream config (retention, `max_age`,
  `max_bytes`, current message count / bytes). An **unbounded** stream means
  the per-execution tail and any cold rebuild grow without limit.
- The fix direction is tracked under
  [noetl/ai-meta#104](https://github.com/noetl/ai-meta/issues/104)
  (result-tier-GC) — give the stream and the `noetl.event` log a bounded
  retention / GC policy so the drive's working set stays small.

This is a deliberate change made off the back of a *sustained* alert, not an
in-the-moment mitigation. If an alert fires once and clears, no action is
needed — that's the safety net doing its job.

## Related

- [`noetl-cqrs-publish-only-flip.md`](noetl-cqrs-publish-only-flip.md) — the
  materializer-lag guardrail (same Prometheus/GMP stack, same manifest
  location, sibling pattern).
- GMP rule: `ci/manifests/noetl/gmp/rules-offserver-drive-latency.yaml`
  (prod); VM rule: `ci/manifests/noetl/vmrule-offserver-drive-latency.yaml`
  (kind).
- Scrape: `ci/manifests/noetl/gmp/podmonitoring-noetl.yaml`.
