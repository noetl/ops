# Embedded-state server: persistent volume prerequisite (#419, ai-meta#332)

**INERT. Nothing here is applied to prod.** It stages the storage prerequisite
for the serve-from-embedded flip so the flip itself is a small, reviewable step.

## Why a volume is needed at all

The embedded `ehdb-l0` engine currently runs on prod **in shadow**, writing to
`/data/ehdb-embedded` with **no volume mounted**. That path lands on the
container's ephemeral writable layer, under a hard `ephemeral-storage: 1Gi`
limit whose breach **evicts the pod**.

That is tolerable for a shadow — measured ~500 events/day, appends buffered
until `should_seal()` at 1024 records / 8 MiB, manifest retain 32, so single-MB
per day against 1 GiB, and the pod is recycled by the cluster-autoscaler far
more often than the budget could fill (observed: a 41-minute pod lifetime).

It is **not** tolerable once the engine serves reads. Serving means the data
must survive a pod restart, and on the ephemeral layer it does not: every
Autopilot node consolidation starts the engine from nothing.

⚠ The code's own comment on `DEFAULT_EMBEDDED_DIR` claims `/data` "fails loudly
at open when [no volume] exists". It does not — `LocalFsSubstrate::new` calls
`create_dir_all`, so a missing volume is silently substituted by ephemeral
storage. Tracked as [noetl/server#419](https://github.com/noetl/server/issues/419).

## ⚠ Why this is a StatefulSet and not a volume bolted onto the Deployment

The prod server is a `Deployment`, `replicas: 1`, with
`strategy.rollingUpdate: {maxSurge: 1, maxUnavailable: 0}`. Three options were
considered and two of them are traps:

| option | outcome |
| :-- | :-- |
| **Deployment + RWO PVC** | ❌ **Every rollout deadlocks.** `maxSurge: 1` starts the new pod *before* the old terminates, and a ReadWriteOnce disk cannot be mounted by both. The new pod sits `Pending` on the volume until `progressDeadlineSeconds` (600s) fails the rollout — the [ai-meta#323](https://github.com/noetl/ai-meta/issues/323) shape exactly: a manifest that reads fine and cannot schedule. |
| **Deployment + RWX PVC** (`standard-rwx`, Filestore — available on this cluster) | ❌ **Corruption risk.** It removes the deadlock precisely by letting *both* pods mount the volume at once, so during every rollout two `L0Engine` processes hold the same directory. The engine is single-writer by construction. This is the tempting option — smallest diff, keeps zero-downtime rolls — and it is the wrong one. |
| **StatefulSet + `volumeClaimTemplate`** | ✅ One volume per pod identity, `OrderedReady` so the old pod releases before the new one binds, and it is the shape the per-shard architecture needs anyway. |

The StatefulSet also gives the ordinal→`NOETL_SHARD_INDEX` derivation
(`NOETL_SHARD_INDEX_FROM_HOSTNAME`) that N>1 routing needs, so this is not a
detour — it is the same migration.

## Validated in kind (2026-09-09), not assumed

Against `ghcr.io/noetl/server:3.106.1` on the kind cluster:

- PVC bound; engine opened at the **prod default path** `/data/ehdb-embedded`
  on a real device (`/dev/vda4`), not the overlay;
- 40 events appended → `substrate/FORMAT_VERSION` + an active part written;
- **pod deleted** (simulating the Autopilot eviction that wipes ephemeral);
- **md5 of every file identical before and after**, same PV rebound;
- engine **reopened on pre-existing data** — the `FORMAT_VERSION` gate passed
  against state it did not create — and a second 40-event round gave
  `opened=1 agreed=40 diverged=0 append_failed=0`.

That last point is the one that matters for the flip: recovery, not just
persistence.

## What is deliberately NOT here

- **No apply.** These files have never been applied to prod.
- **No serve flip.** Mounting a volume does not make the engine authoritative;
  that is a separate, owner-gated change.
- **No Deployment→StatefulSet cutover plan for prod.** Converting the running
  server is its own change set with its own gate; this directory only proves the
  target shape works and records why the alternatives do not.
