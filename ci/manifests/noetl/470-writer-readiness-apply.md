# Applying the #470 writer readiness probe — the path, and why it is not `kubectl apply`

Staged, **not applied**. noetl/ai-meta#470 step 6 is gated on the owner.

## ⚠⚠ Do not apply this manifest with `kubectl apply -f`

Two independent reasons, both found by diffing the **full rendered object**
against live rather than the fields being changed
([`apply-safety.md`](https://github.com/noetl/ai-meta/blob/main/agents/rules/apply-safety.md)).
A targeted check of the probe fields reported clean.

### 1. Server-side apply cannot replace a probe handler

```
The StatefulSet "noetl-cmdbus-writer" is invalid:
spec.template.spec.containers[0].readinessProbe.tcpSocket:
Forbidden: may not specify more than 1 handler type
```

`readinessProbe` is a struct whose `tcpSocket` field is owned by a different
field manager (`noetl-iac`). An apply that declares `httpGet` **merges** it
alongside the `tcpSocket` nobody removed, producing an object with two handlers,
which the API server rejects. `--force-conflicts` does not help: this is not a
conflict, it is a field the apply never claims.

⚠ The first read of this was an **empty** `kubectl diff` output, which looked
like "no differences". It was the error being filtered away by a `grep -E '^[+-]'`.
A positive control — re-running the diff against a deliberately altered copy —
returned the identical 160 bytes, which is what proved the comparison was not
running at all. Assert the extraction before asserting about the result.

### 2. The committed memory limit was stale and would have OOMed the writer

Live has been **12Gi** since the OOM work (raised by `kubectl patch`, which
nothing wrote back here). This file said **4Gi**. The writer OOMs at 4Gi: ~3 GiB
baseline from the unsealed tier store plus an episodic spike on mass worker
reconnect, and 4Gi → 8Gi restored dispatch then OOMed again in 81 minutes.

So an apply whose stated purpose was a readiness probe would have reverted the
memory limit and OOMed the single-writer host — the
[noetl/ai-meta#323](https://github.com/noetl/ai-meta/issues/323) shape exactly.
The manifest is corrected to 12Gi in the same change set, so it now matches live
and the field is a no-op either way.

## The path that works

A strategic-merge patch, which touches only the fields it names — so it cannot
revert memory, replicas, or anything else the manifest's copy has drifted on.
`tcpSocket: null` is what removes the old handler.

**Dry-run first** (read-only; this exact command was run and its output is below):

```bash
PROD=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
kubectl --context "$PROD" -n noetl patch sts noetl-cmdbus-writer \
  --type=strategic --dry-run=server -o json -p '{"spec":{"template":{"spec":{"containers":[{"name":"noetl-worker","readinessProbe":{"tcpSocket":null,"initialDelaySeconds":null,"httpGet":{"path":"/readyz","port":"metrics"},"timeoutSeconds":2},"startupProbe":{"failureThreshold":60,"httpGet":{"path":"/readyz","port":"metrics"},"initialDelaySeconds":2,"periodSeconds":5,"successThreshold":1,"timeoutSeconds":2}}]}}}}'
```

Verified output — one handler each, liveness untouched, memory preserved:

```
startupProbe:   {"failureThreshold":60,"httpGet":{"path":"/readyz","port":"metrics","scheme":"HTTP"},"initialDelaySeconds":2,"periodSeconds":5,"successThreshold":1,"timeoutSeconds":2}
readinessProbe: {"failureThreshold":3,"httpGet":{"path":"/readyz","port":"metrics","scheme":"HTTP"},"periodSeconds":5,"successThreshold":1,"timeoutSeconds":2}
livenessProbe:  {"failureThreshold":3,"initialDelaySeconds":30,"periodSeconds":20,"successThreshold":1,"tcpSocket":{"port":"cmdbus-claim"},"timeoutSeconds":1}
resources.limits.memory: 12Gi
```

To apply, drop `--dry-run=server -o json`.

## ⚠⚠ The startup budget is 300 s, and 60 s was proven wrong

Sizing the `startupProbe` to the 2.6 s bind window was wrong, and kind validation
caught it. At `failureThreshold: 12` (62 s) the writer **crash-looped**: the
container was SIGTERMed at exactly 61 s with `exitCode 0`, and the events read

```
Warning  Unhealthy  Startup probe failed: HTTP probe failed with statuscode: 503
Normal   Killing    Container noetl-worker failed startup probe, will be restarted
```

`/readyz` gates on **boot warmup** as well as on the bus faces, and warmup is a
separate and much longer thing than binding — so a budget derived from bind
times measures the wrong quantity entirely.

⚠ Not fully isolated: the **first** container on a new image took > 62 s to
answer 200, while every subsequent fresh container answered within ~16 s, and
nothing at all was logged in the 61 s gap. No on-disk warmup cache was found, so
the obvious cold-start explanation is unconfirmed. The budget absorbs it either
way: 300 s is ~19x the ~16 s a fresh container actually takes, and startup ends
on the first success rather than at the budget, so a generous budget delays
nothing.

## ⚠⚠⚠ This patch ROLLS the writer

Anything under `spec.template` changes the pod-template hash, so the
StatefulSet recreates `noetl-cmdbus-writer-0`. That pod hosts **both** buses, so
the roll stops dispatch for the restart window.

Measured on the most recent restart (2026-10-16, `restarts=0`, container
`startedAt` 17:05:13Z), container-relative:

| face | bound at |
| :-- | --: |
| `:9090` metrics (serves `/readyz`) | 1.6 s |
| `:9100` command ingest | 2.6 s |
| `:9101` command claim | 2.6 s |
| `:9103` event ingest | 56.0 s |
| `:9110` tier service | 60.5 s |
| `:9104` event claim | **308.4 s** |

⚠ A note on those numbers: measured from the **pod's** `startTime` they read
73.6 s / 74.6 s / … because 72 s of that was image pull. Probes measure from
**container start**, so the container-relative column is the one that matters —
and the first framing overstated the startup window by ~28x on the fast faces.

With the default required set (command ingest + claim) the pod turns Ready at
~2.6 s, which is *before* the old probe's 5 s `initialDelaySeconds` elapsed. So
the probe change itself adds no restart cost; the roll is the cost.

⚠ A stale note worth correcting: the writer was previously recorded as unable to
restart (a prior attempt looped fatally). It restarted cleanly on 2026-10-16 with
`restarts=0`, so that no longer holds — but verify before rolling, do not assume
either way.

## Rollback

Same patch shape, inverted — restores the TCP handler and drops the startupProbe:

```bash
kubectl --context "$PROD" -n noetl patch sts noetl-cmdbus-writer \
  --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"noetl-worker","readinessProbe":{"httpGet":null,"tcpSocket":{"port":"cmdbus-claim"},"initialDelaySeconds":5,"timeoutSeconds":1},"startupProbe":null}]}}}}'
```

⚠ Rollback is also a `spec.template` change, so it rolls the writer a second
time. Budget for two restarts, not one.

## Prerequisite

The image must carry noetl/worker#360 — without it `/readyz` answers only the
boot-warmup boolean, which is what the old probe effectively already measured,
so the swap would buy nothing. Check:

```bash
kubectl --context "$PROD" -n noetl exec noetl-cmdbus-writer-0 -- \
  sh -c 'cat < /dev/tcp/127.0.0.1/9090' 2>/dev/null   # curl/wget are ABSENT from noetl images
```

or read `noetl_worker_serving_heartbeat` off a scrape — its presence is the
discriminator for "this build has #470".
