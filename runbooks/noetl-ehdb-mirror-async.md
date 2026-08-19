# Runbook — async event-log mirror (noetl/ai-meta#155 Option 3)

The alerts in `ci/manifests/noetl/gmp/rules-ehdb-mirror-lag.yaml` (prod) and
`ci/manifests/noetl/vmrule-ehdb-mirror-lag.yaml` (kind) all point here.

## The one-line revert

```bash
kubectl -n noetl set env deployment/noetl-server NOETL_EHDB_EVENTLOG_MIRROR_ASYNC=false
```

That restores the inline mirror. It costs ~8.4 s per Muno planner turn and it
is always safe: the inline mirror is what prod ran before this change, and the
queue drains on shutdown so the roll loses nothing.

**Also set the tolerance back to 0** once the async mirror is off — a window
with no async mirror behind it is a blind spot with no benefit:

```bash
kubectl -n noetl set env deployment/noetl-server NOETL_EHDB_CROSSSTORE_PARITY_LAG_TOLERANCE_SECS=0
```

## What this changed, in one paragraph

The server mirrors every authoritative event into the EHDB event-log tier, and
that tier serves `primary`. The mirror used to run inline on the event-write
path, so an event was in the tier before `emit_events` returned. It now goes
through a bounded in-process queue with a single drain task. The event write no
longer waits for the tier.

The consequence is that the cross-store parity comparator — the thing that
**demotes** the tier when it disagrees with `noetl.event` — can now sample an
execution whose newest events are still queued. Without a recency bound it would
call that `missing_event` and demote a healthy tier. So the comparator gained a
lag tolerance window, and these alerts are what verify the mirror stays inside
it. Nothing in the code can check that; it is a claim about wall-clock time in
production.

## The knobs

| variable | default | what it does |
| :-- | :-- | :-- |
| `NOETL_EHDB_EVENTLOG_MIRROR_ASYNC` | `false` | Arms the queue. Off ⇒ inline mirror, byte-identical to before. |
| `NOETL_EHDB_CROSSSTORE_PARITY_LAG_TOLERANCE_SECS` | `0` | The comparator's window. **Must be > 0 whenever the async flag is on**, and should be set just above the observed `noetl:ehdb_mirror_lag_p99`. |
| `NOETL_EHDB_EVENTLOG_MIRROR_QUEUE_CAPACITY` | `512` | Queue depth in batches. |
| `NOETL_EHDB_EVENTLOG_MIRROR_ENQUEUE_TIMEOUT_MS` | `5000` | How long the emit path waits for room before delivering inline. |
| `NOETL_EHDB_EVENTLOG_MIRROR_DRAIN_MAX_BATCHES` | `64` | Batches coalesced per drain pass. |
| `NOETL_EHDB_EVENTLOG_MIRROR_FLUSH_TIMEOUT_MS` | `10000` | Shutdown flush deadline. |

## The two settings that must agree

`..._MIRROR_ASYNC=true` with `..._LAG_TOLERANCE_SECS=0` is the dangerous
combination: the mirror is queued and the comparator has no window, so it will
demote the tier on its own liveness. Check both together:

```bash
kubectl -n noetl get deployment noetl-server -o json \
  | jq -r '.spec.template.spec.containers[0].env[]
           | select(.name|test("MIRROR_ASYNC|LAG_TOLERANCE"))
           | "\(.name)=\(.value)"'
```

The server publishes the window it actually loaded, which is the number to
trust over the manifest (`representation-drift.md` — read the original, not the
copy):

```bash
kubectl -n noetl exec deploy/noetl-server -- \
  wget -qO- 127.0.0.1:8082/metrics \
  | grep -E 'mirror_async_enabled|parity_lag_tolerance_seconds'
```

## Alerts

### EhdbMirrorLagExceedsParityWindow

The measured p99 enqueue→durable lag has passed the window the comparator was
told to allow. Events are aging out of the window while still queued, so they
will be reported as `missing_event` and the serve policy will demote a tier that
is healthy.

1. Check whether the queue is backed up or the tier is slow:
   ```bash
   kubectl -n noetl exec deploy/noetl-server -- wget -qO- 127.0.0.1:8082/metrics \
     | grep -E 'mirror_pending_events|mirror_queue_depth|mirror_queue_total'
   ```
2. If `pending_events` is high → the tier service is slow. Look at the writer
   (`noetl-eventbus-writer-0`) and at
   `noetl_ehdb_eventlog_mirror_total{outcome="unavailable"}`.
3. If `pending_events` is ~0 but lag is high → individual appends are slow, not
   the queue. That is the tier, not this change.
4. **Do not widen the window as the first move.** A wider window is a longer
   period during which a genuinely lost event is invisible. Fix the mirror, or
   revert to inline.

### EhdbMirrorQueueStalled

Events are queued and nothing has drained for 10m.

A stalled queue publishes **no** lag observations, so the lag histogram looks
healthy — this is why the alert watches the pending gauge instead. Check the
relay:

```bash
kubectl -n noetl logs deploy/noetl-server --tail=200 \
  | grep -E 'event-log tier mirror relay failed|mirror queue'
```

If the drain task itself is gone (the log line `async mirror queue closed; drain
task exiting` with no restart), restart the server — the queue is per-process
and re-arms at startup.

### EhdbMirrorInlineFallback

The queue stayed full past the enqueue timeout, so batches are being delivered
on the event-write path.

Nothing is lost. Two consequences: the latency this change removed is back, and
this is the one path that can deliver **out of order** relative to batches still
queued for the same execution — which reports as an `order` divergence and
demotes the tier. Raise `..._QUEUE_CAPACITY`, or find out why the tier is slow.

### EhdbMirrorShutdownAbandoned

A server exited with events still queued and the flush deadline passed.

Those events are permanently absent from the tier — nothing retries a mirror.
**They will produce a `missing_event` divergence later.** Record this against
the restart so that divergence is not investigated as tier corruption. If it
recurs on ordinary rolls, raise `..._FLUSH_TIMEOUT_MS`.

### EhdbParityComparesNothing

More than half of parity samples returned `pending_mirror` — every event in them
was inside the window, so no comparison happened.

This is the anti-vacuity check on the window itself. A clean
`divergence_total == 0` under this condition is evidence of nothing: a tolerance
that forgives everything is indistinguishable from a comparator that was
deleted. Narrow `..._LAG_TOLERANCE_SECS` toward the observed
`noetl:ehdb_mirror_lag_p99`, or lengthen
`NOETL_EHDB_CROSSSTORE_PARITY_SETTLE_SECS` so sampled executions have outlived
the window.

### EhdbParityControlFailed

An in-binary parity control returned `unexpected`.

The controls drive synthetic fixtures through the same comparator the live path
uses. A failure voids every verdict it has published, including every
`divergence_total == 0`.

```bash
kubectl -n noetl exec deploy/noetl-server -- \
  wget -qO- 127.0.0.1:8082/api/ehdb/parity/self-test | jq '.controls[] | select(.expected == false)'
```

If the failing control is **`lag_beyond_window`**, the tolerance is swallowing a
real divergence. Set `..._LAG_TOLERANCE_SECS=0` immediately; the comparator is
the tier's only protection and it is currently not providing it.

## ⚠ These alerts currently page nobody

Prod has **zero notificationChannels** ([noetl/ai-meta#238](https://github.com/noetl/ai-meta/issues/238)).
A firing rule is visible in Metrics Explorer and reaches no human. ops#258
tracks the fix. Until it lands, treat the async flag as requiring an operator
watching the metrics rather than as covered by alerting.
