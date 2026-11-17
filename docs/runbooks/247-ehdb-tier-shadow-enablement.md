# Runbook — EHDB tier shadow enablement (noetl/ai-meta#247)

**Status: DRAFT. Applied to nothing. Prod is tier-off on all five tiers.**

This is the sequence for getting the phase 6–10 storage tiers into `shadow` and
collecting the parity evidence that the eventual `primary` cutover is gated on.
It stops before `primary`, which is a separate decision.

---

## 0. What this is waiting on

**A human decision about where the tiers live.** This runbook assumes the
answer is "a dedicated dispatching worker with its own volume" and ships the
manifest for it (`ci/manifests/noetl/ehdb-tiers/statefulset-tier-worker.yaml`),
but the decision is not made. Two other options were considered and are
documented in `docs/rfc/247-ehdb-tier-host-storage-decision.md` in ai-meta.

Do not apply the manifest until that is settled.

---

## 1. Why the obvious shortcuts do not work

Recorded because both look correct and neither is.

**"Just set the tier flags on the workers."** They have no persistent volume —
only `dshm` — and their KEDA ScaledObject is `min 2 / max 20`. A pod-local
mirror is discarded on every scale-down.

**"Then set them on `noetl-cmdbus-writer`; it has PVCs."** It does, and it
would mirror **nothing**. The mirror hook is in `emit_event`, so a process only
mirrors events it emits — and the writer was **measured** at zero pulls and zero
dispatches across a real execution while the user pool's dispatch counter moved.
It hosts the buses and emits nothing. The flags would read as enabled and
produce no evidence.

That combination — durable disk **and** on the event-emit path — is why the
draft is a new dispatching workload.

**"Shadow is free, just turn it on."** Shadow dual-writes and compares, and if
the mirror is lost the comparator keeps **passing**: its primary invariant is
the engine's own gapless-from-1 property, which a fresh mirror starting at
sequence 1 still satisfies. Shadow on ephemeral storage reports clean parity
while having lost history. That is worse than no evidence.

---

## 2. Enablement order

One tier at a time, cheapest signal first, event log **last** — it is the only
one whose primary cutover touches the append-only platform log.

| # | flag | why this position |
| :-- | :-- | :-- |
| 1 | `NOETL_EHDB_PROJECTION=shadow` | derived data, smallest blast radius |
| 2 | `NOETL_EHDB_KV=shadow` | |
| 3 | `NOETL_EHDB_OBJECT=shadow` | |
| 4 | `NOETL_EHDB_VECTOR=shadow` | |
| 5 | `NOETL_EHDB_EVENTLOG=shadow` | last; mirrors the source-of-truth log |

Each step:

```bash
kubectl -n noetl set env statefulset/noetl-worker-tier NOETL_EHDB_PROJECTION=shadow
kubectl -n noetl rollout status statefulset/noetl-worker-tier --timeout=300s
```

Rollback for any step is the same command with `off`. Shadow never serves a
read and never touches the incumbent, so each step is a pure add.

---

## 3. Evidence required before advancing a tier

Collect per tier and record on noetl/ai-meta#247. **Do not advance on a clean
reading taken in the first few minutes** — the failure mode this is guarding
against only appears across a pod lifecycle.

- [ ] `published == projected == cursors` for the tier
- [ ] zero duplicate / gap / out-of-order reports
- [ ] `ehdb_events_cursor_errors == 0`, group lag 0
- [ ] a real execution COMPLETES while the tier mirrors
- [ ] **a watch window spanning at least one pod restart**, and the mirror
      still reconciles afterwards

That last item is the one with teeth. Restart the tier pod deliberately:

```bash
kubectl -n noetl delete pod noetl-worker-tier-0
kubectl -n noetl rollout status statefulset/noetl-worker-tier --timeout=300s
```

then re-check parity. If parity is still clean **and** the mirror's sequence
continued rather than restarting at 1, the durability decision is validated
empirically rather than by argument. If the sequence restarted at 1 while
parity still reported clean, **stop** — that is the false-confidence failure
this whole design is arranged to prevent, and it means the evidence is not
trustworthy on any tier.

---

## 4. What is explicitly NOT in this runbook

- **`primary` on any tier.** Serving reads from EHDB is a separate gate. The
  code supports it (`PRIMARY_SERVE_ACTIVATED = true` in the released worker)
  and the rollback is documented as zero-data-loss, but it is not covered here.
- **Sizing.** The 10Gi in the manifest is a guess. Size from observed growth
  during shadow.
- **The feed subject.** As drafted the tier worker claims the same subject as
  the user pool, so it competes for work. That is deliberate for shadow — it
  must emit real events to mirror them — but wants revisiting before primary.

---

## 5. Pre-apply checklist

- [ ] host decision made and recorded on #247
- [ ] image pinned by **digest**, not tag
- [ ] storage size revisited
- [ ] feed-subject question answered
- [ ] `kubectl apply --dry-run=server` clean against the target cluster
- [ ] PodMonitoring applied with the workload, so parity is observable from the
      first shadow write — an unscraped tier produces no evidence at all
