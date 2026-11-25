# Latency plan — prod rollout (noetl/ai-meta#556, #558, #559, #283)

Owner-authorized 2026-11-14 (full autonomy, strict prod discipline). One component at a
time, smoke after each, flags enabled incrementally with a prod before/after at each step.

## Pins (by digest, AR `us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl`)

| Component | Before (rollback) | After |
|---|---|---|
| `sts/noetl-server-rust-embedded` | server-rust v3.161.2 `sha256:e4e49e787baf3927cd7ff7cfa17721f135bd7efef2e985c4838c648faea39cfd` | v3.163.0 `sha256:f850267dc3aaea63f179f186f5e4cf1425f5aadfffbac860fb2fb42f7d024e28` |
| `deploy/noetl-worker-rust` (user pool) | noetl-worker-rust 6.12.0 `sha256:ac7cc50f41045df3c46e1b7b9edb5bb096c7653915890c51515253223478dbc6` | 6.17.0 `sha256:70c2b675948372d3e943b15b623be9d9c1d09bc14bb8717ef63e86b99a0acc21` (noetl-tools =4.7.0) |
| system pools + `sts/noetl-cmdbus-writer` | 6.11.9 `sha256:f866f614…` | unchanged |

Prod topology precondition (verified 2026-11-14): `NOETL_STATE_BUILDER=offserver` on the
server and on `deploy/noetl-worker-system-pool` (`NOETL_STATE_BUILDER_SOURCE=ehdb`). #559's
flags require it (noetl/ai-meta#570).

## Rollback

```bash
# flags (fastest): remove the env, the pod restarts on the previous behaviour
kubectl -n noetl set env deploy/noetl-worker-rust NOETL_WORKER_LOCAL_DRIVE- NOETL_EXECUTION_WAIT- NOETL_PLAYBOOK_AWAIT_PARK-
kubectl -n noetl set env sts/noetl-server-rust-embedded NOETL_SERVER_ADVANCE_API- NOETL_EXECUTION_WAIT- NOETL_PLAYBOOK_AWAIT_PARK-
# images
kubectl -n noetl set image deploy/noetl-worker-rust noetl-worker=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:ac7cc50f41045df3c46e1b7b9edb5bb096c7653915890c51515253223478dbc6
kubectl -n noetl set image sts/noetl-server-rust-embedded noetl-server=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:e4e49e787baf3927cd7ff7cfa17721f135bd7efef2e985c4838c648faea39cfd
# #283 index
#   DROP INDEX noetl.idx_command_event_id;   -- as postgres; brief ACCESS EXCLUSIVE on noetl.command, quiet window
```

## Measurements

Harness: `ci/kind/latency/` playbooks (`bench/*`, registered in prod) driven against prod
over a port-forward; prod variant of bench.sh/auth.sh in this directory's log.

All prod, 2026-11-15 UTC, p50 / p95. Serial runs unless noted. "Overhead" is per-step
orchestration (step wall minus tool). Each column is one cumulative change.

| Measure | 0. pre (v3.161.2 / 6.12.0) | 1. + #283 index | 2. + new images, flags off | 3. + #558 | 4. + #559 WAIT+PARK |
|---|---|---|---|---|---|
| seq10 noop: overhead/step | 712 / 1483 ms | 397 / 915 | 343 / 627 | **200 / 401** | 217 / 546 |
| seq10 noop: wall (n=12) | 10.41 / 11.39 s | 6.14 / 7.55 | 4.97 / 6.75 | **3.06 / 4.05** | 3.39 / 7.47 |
| seq10 python: wall (n=12) | 11.53 / 12.89 s | — | 6.22 / 7.41 | 4.38 / 5.96 | 4.51 / 6.29 |
| awaited child hop (n=30) | 2468 / 4942 ms | — | 2398 / 3665 | 2364 / 3433 | **1024 / 1456** |
| await3 (3 awaited calls): wall (n=10) | 13.71 / 15.65 s | — | 10.31 / 12.17 | 8.51 / 14.43 | **5.23 / 7.45** |
| load seq10 noop, 16 runs C=4: wall | 23.76 / 39.20 s | — | 6.66 / 8.28 | 4.55 / 6.36 | 4.51 / 5.82 |
| auth sync (gateway path) validate / check-access | 214 / 216 ms | — | 216 / 215 | 208 / 205 | 216 / 215 |
| auth playbook fallback (n=10), max | 5.68 s, max 7.26 | — | 3.35, max 4.50 | 2.28, max 2.96 | 2.87, max 4.73 |
| real travel turn (itinerary-planner) | — | — | 11.52 / 12.23 s (n=4) | 9.26 / 10.08 (n=5) | 9.57 / 11.57 (n=15) |

Claim lookup (#283): 72–106 ms, 77,769 buffers (seq scan of 16 partitions) → 0.25 ms, 33 buffers.

Notes:
- Auth stays far inside the 15 s gateway budget at every step (worst 7.26 s, before any change).
- The travel turn's one awaited child (`persist_all_atomically`) already returns in ~0.5 s,
  so #559 does not move it. In the first 5 turns after the #559 enable, 2 stalled ~4 s
  between a step's `command.completed` and the next `step.enter` (not parked; next-step
  drive). 25 following turns: none (max 13.3 s). Watch for recurrence.
- Local drive share (server metrics, first 14 min): 806 of 976 applied drives were local;
  22 `fallback_in_flight`; parks 33 parked / 33 resumed.
- `NOETL_CATALOG_REMOTE_PUSH`: NOT enabled. Prod has no `NOETL_CATALOG_REMOTE_*` set, so
  cross-instance calls are not in use and push has nothing to speed up.
- The server manifest already drifted from the live env before this rollout (env set
  directly by earlier sessions: EHDB_BLOOM_SCHEME, NOETL_AGENT_ENDPOINT, NOETL_EHGRAPH_*, …).
  This change adds only this rollout's lines; reconciling the rest is separate.
- `harness/`: the prod variants of the kind harness used here (bench playbooks are
  registered in prod under `bench/`).

## Follow-up 2026-11-15 (08:57–10:05Z): #559 rolled back, root-caused, re-enabled

- 08:57Z #559 rolled back after ~4 s next-step stalls (2 of the first 5 turns, then 1/30
  noop, 1/10 turns). Controls: flags-off steady had them too (3/30 turns); every stall sat
  near a pod restart or KEDA scale event.
- Cause 1: a fresh local-drive user-pool pod compiled `system/orchestrate` on its FIRST drive
  (`plugin_load_seconds{phase="compile"}` 4.75 s). Fix: `NOETL_WARM_ORCHESTRATE_PLUGIN=true`
  on `deploy/noetl-worker-rust` (10:05Z; default-on in noetl/worker#405). Verified: both new
  pods `plugin_warm_total{outcome="warmed"} 1`; 0 stalls after the restart.
- Cause 2: a completion claimed for local drive by a pod that then exits waits for the
  claim TTL + an 8 s reconcile tick (kind churn: 11/400 stalled with local drive on, 0/400
  off). Fix in review: server claim sweeper + worker stops local drive on drain.
- Interleaved prod A/B, 2 reps/side, A = #558 only, B = #558 + #559 (p50 / p95):

| | A | B |
|---|---|---|
| await3 wall (n=20) | 11.9 / 33.4 s | 6.2 / 8.4 s |
| awaited hop (n=60) | 2.71 / 9.66 s | 0.96 / 2.08 s |
| real travel turn (n=30) | 13.5 / 32.3 s | 11.1 / 21.6 s |

- 10:05Z #559 re-enabled (server + worker) with the warm-up. Smoke: noop 12/12, auth fallback
  max 4.41 s, 5 turns, 0 stalls.

Rollback of the warm-up: `kubectl -n noetl set env deploy/noetl-worker-rust NOETL_WARM_ORCHESTRATE_PLUGIN-`.

## #561 slice 1 (2026-11-15 12:05–13:00Z): server v3.163.1, worker 6.18.0, resolve TTL

- server v3.163.1 `c280c2c5…` (noetl/server#587, abandoned-claim sweeper) — rollback v3.163.0 `f850267d…`.
- worker 6.18.0 `e5b1d72c…` (noetl/worker#405: warm on local-drive pools, resolve TTL, unlocked flush, stop
  local drive on drain) — rollback 6.17.0 `70c2b675…`.
- `NOETL_WASM_RESOLVE_TTL_MS=30000` on the user pool. Each drive had re-fetched the whole module to learn its
  digest (`plugin_load_seconds{phase="fetch"}` 22.4 s / 367 = 61 ms); after, 7–8 fetches per pod.

| prod p50 / p95 | TTL off | TTL 30 s |
|---|---|---|
| drive segment, serial noop | 65.7 / 225 ms | 34.3 / 227 ms |
| drive segment, load C=4 | 91.9 / 536 ms | 46.5 / 290 ms |
| overhead per step, serial | 216 ms | 182 ms |
| seq10 noop wall | 3.65 s | 3.45 s |
| load wall | 5.63 / 8.05 s | 5.19 / 6.70 s |
| auth fallback max | 4.84 s | 4.64 s |

- `NOETL_WASM_FLUSH_UNLOCKED` left OFF: local drives return their result through `apply`, not plug-in
  intents, so it does not touch the prod path (only `kind: wasm` tool steps).
- Kind churn (3 lat workers, a pod deleted every 15 s, 400 × seq10 noop): stalls >2 s 11/400 → 0/400 with the fix.
- Note: one auth fallback run read 15.0 s at 11:45Z during a KEDA scale-out while `GET /api/executions` (a
  ~5 s list query, polled every ~5 s by an unidentified client) loaded the DB; 20 reruns max 4.55 s. Tracked
  separately.

## 2026-11-16: archive keyset fix (server v3.163.2) and #561 slice 2 (server v3.163.3)

- **v3.163.2 `a6cb6408…`** (noetl/server#589), rolled 05:32:02Z; rollback v3.163.1 `c280c2c5…`.
  - Root cause of the slow `GET /api/executions`-shaped query: the server's own archive pass paged its
    candidate listing by `offset`. That was quadratic: 137 pages climbing to ~4 s each, back to back, for
    4–5 min of every 300 s interval.
  - Listing query active: 120/120 one-second samples → 0/120.
  - Pass time: 4–5 min → 7 s, examining all 13,616 executions.
  - Slow list statements: 376/h (1,133 s of DB time per hour) → 0.
- **v3.163.3 `ee418620…`** (noetl/server#590), rolled 05:58:02Z with flags off; rollback v3.163.2 `a6cb6408…`,
  or unset the env vars.
  - `NOETL_INGEST_CATALOG_FROM_DESCRIPTOR=true`, on 06:08:46Z: `catalog_id` ingest phase 14.56 → 0.04 ms per event.
  - `NOETL_PLAYBOOK_PARSE_CACHE=true`, on 06:21:45Z: worker local-drive `apply` 171.5 → 109.0 ms.

| prod p50 (p95) | v3.163.3 flags off | + descriptor | + parse cache (final) |
|---|---|---|---|
| seq10 noop wall | 3.46 s | 2.73 / 2.50 s | 2.39 / 2.22 s |
| overhead per step, noop | 181 ms | 155 / 152 ms | 145 / 143 ms |
| seq10 py wall | 4.95 s | 4.51 s | 3.47 s |
| await3 wall | 6.87 s | 5.65 / 7.68 s | 4.94 / 4.46 s |
| awaited hop | 1.21 s | 1.10 / 1.16 s | 0.83 / 0.89 s |
| load C=4 wall | 4.15 (4.91) s | 2.62 / 3.92 s (a first run read 6.03 s during KEDA churn) | 3.20 (4.95) s |
| auth fallback max | 22.4 s (in the suite, queued behind load) / 4.42 s (standalone, n=20) | 6.35 s | 2.89 s |
| travel turn | — | — | 7.6 s p50, 10/10 COMPLETED |

- Auth: the sync path stayed ~211–219 ms throughout. The fallback playbook exceeds 15 s only when it queues
  behind a saturated user pool (the auth arm starts right after the load arm, and KEDA was scaling 2→3).
  Standalone it is ≤4.4 s.
- Kind could not show slice 2: kind's catalog lookup is sub-millisecond on a local DB. The A/B was flat
  per segment and wall times were host-noise dominated. Judged on the prod per-event metrics above.
- #562: nothing applied. Autopilot's own balloon pods already absorb a 16-pod burst (scheduled ≤9 s).
  See ai-meta#562.

## 2026-11-16 (21:28–23:05Z): server v3.164.0, dedicated auth pool, fused step events (flag left off), and an incident

Release: noetl/server#591, released as **v3.164.0** `898313da` (rollback v3.163.3 `ee418620`). Both new flags are off by default.

### Auth pool (ai-meta#562): LIVE
- `deploy/noetl-worker-auth-pool` (`worker-auth-pool-deployment-prod.yaml`):
  - 2 fixed replicas, same image and env as the user pool;
  - `NOETL_FEED_FILTER_SUBJECT=noetl.commands.auth.>`;
  - applied 21:38Z.
- The server sets `NOETL_POOL_ROUTES=api_integration/auth0/=auth`, on since 21:57:36Z. Every `api_integration/auth0/*` execution is routed to `noetl.commands.auth.<eid>` for its whole life.
- Verified: the auth pods' pickup counters equal the auth runs, and later steps drive locally on those pods.
- Auth fallback under a concurrent shared-pool load (`seq10_noop` ×32 at concurrency 8, `harness authload.sh`):

| | Load wall, p50 | Auth p50 | Auth max |
|---|---|---|---|
| Off (v3.164.0) | 6.6 s | 2.38 s | 8.13 s |
| On, run 1 (fresh auth pods) | 9.5 s | 3.81 s | 9.45 s |
| On, run 2 (pool saturated, KEDA 2→3 waiting on a node) | **14.5 s** | 3.44 s | **7.62 s** |
| On, standalone | — | 2.21 s | 3.39 s |
| On, after recovery | — | 2.31 s | 4.41 s |

- The isolation shows in on-run 2: the shared pool's load wall doubled while auth stayed under 8 s.
- In kind (6 vCPU, one server), routing removed the claim queue (issued→claimed 4.3 s → 0.8 s mean), but end-to-end auth was capped by server CPU there.
- Rollback: unset `NOETL_POOL_ROUTES` first (`set env NOETL_POOL_ROUTES-`), let in-flight auth runs drain, then delete the deployment.
- Cost: 2 × (250m CPU / 256Mi) requests. The pool takes a little of Autopilot's burst headroom (a later user-pool scale-up hit `Insufficient memory` and waited for a node).

### Fused step events (ai-meta#561): built, measured, LEFT OFF
- Finding: every `emit_events` call carried one row, in kind (6,656 / 6,656) and in prod (4,545 / 4,534). So a per-call burst alone never engages.
- The fix fuses `step.enter` / `step.skipped` with the `command.issued` rows into one `emit_events` call, sent as one pipelined burst. The writer already group-commits, so **no ehdb or cmdbus-writer change** was needed and the writer was not rolled.
- Prod phase metrics, flag on: 419 fused bursts at **6.59 ms** each vs 12.53 ms per single row. That is about 18 ms saved per fused pair, roughly one per step.
- Wall time was inconclusive against prod noise:

| | noop | py | await |
|---|---|---|---|
| Off | 2.32 s | 3.56 s | 5.26 s |
| On, run 1 | 2.26 s | 4.63 s | 5.11 s |
| On, run 2 | 3.05 s | 3.54 s | — |

- Left OFF pending a clean interleaved A/B.
- Under the load runs, the per-row publish rose to 35 ms. The writer is the contended resource, and that is where fusion helps most.

### INCIDENT 22:12–22:57Z: server down ~45 min (self-inflicted)
- **Cause:** the A/B script turned the flag "off" with `kubectl set env … NOETL_EVENT_PUBLISH_BATCH=` (an empty value). envy rejected `''` for a bool, the server logged `Failed to load app config, using defaults`, `NOETL_COMMAND_BUS` was then unset, and the server refused to start (CrashLoopBackOff).
- **Why it stayed down:** the StatefulSet (OrderedReady) does not replace a pod that never becomes Ready, so the following "on" flips never applied.
- **Recovered** 22:57:48Z: removed the var (`set env NOETL_EVENT_PUBLISH_BATCH-`) and deleted the stuck pod.
- **Impact:** server API unavailable for ~45 min. The `hotelbeds-content-sync` run at 22:17 failed (hourly, next run 23:17). No stranded executions found afterwards.
- **Post-recovery smoke:** noop 12/12 p50 2.19 s, auth max 4.41 s, 5/5 real travel turns (p50 8.1 s).
- **Rule:** turn a bool flag off by REMOVING the variable (`NAME-`), never `NAME=`. Watch every prod flip to Ready, and never script flips unattended.

## 2026-11-17 (03:16–07:00Z): batch flag decided ON, worker lifecycle fusion ON, await-park fix

All flag changes went through a guarded setter (`harness/prodchg.sh`, `harness/ab_batch.sh` in the session scratch, logic recorded here): **off = remove the variable**; after every change the spec must match, the rollout finish, every pod be Ready with 0 restarts, the server log carry no `Failed to load app config`, `/api/health` answer and a smoke execution COMPLETE — else remove the flag / restore the pinned image and stop. No restarts were made in :14–:21 (hourly `hotelbeds-content-sync` at :17). 14 guarded changes, 0 aborts, 0 restarts.

### 1. `NOETL_EVENT_PUBLISH_BATCH` (server, step.enter fused with command.issued) — ON

Interleaved A/B on v3.164.0, 3 blocks per side (on/off/on/off/on/off), each block noop×12, py×12, await3×10 (102 executions per side, all COMPLETED):

| p50 / p95 | off | on |
|---|---|---|
| seq10_noop | 2.34 / 5.27 s | 2.25 / 3.34 s |
| seq10_py | 3.09 / 10.87 s | 3.16 / 4.48 s |
| await3 | 4.95 / 9.21 s | 5.15 / 8.70 s |

Server publish time 69.0 s → 54.2 s for the same work (−21%; ~1,000 per-row publishes became bursts, 7.2 ms/burst vs 8.5–8.9 ms/row). p50 deltas within block-to-block spread, p95 better on every arm → **ON since 2026-11-17T04:08Z**.

### 2. Worker lifecycle fusion (`NOETL_WORKER_FUSE_LIFECYCLE`, worker 6.19.0 + server ≥ 3.165.0) — ON

A command's `call.done` is held and sent with its `command.completed` in one `POST /api/events/seq`, **only** for exactly one in-process tool (noop/python/http/postgres/duckdb/rhai/shell/script/wasm), no `cases`, no sink, no task_sequence `do:` verb, a completing success, never the orchestrate drive. A step with an ordered tool list of several tools (any runtimes), conditional jumps, failures and parked/callback steps keep per-event writes. `command.started` is never fused.

**Correctness (kind, byte-compare of `noetl.event` rows, ids/timestamps normalized):** `bench/fuse_multitool` (single python → [python, rhai, noop] list → a `do: jump` loop list → single rhai), `bench/fuse_goto` (guarded back-edge loop ×3 with arc `set:`, exclusive branch with one arm never taken, a skipped step) and `seq10_py`: 5 on/off pairs each, then 20 pairs each of goto + seq10_py — every pair identical except (a) the `__context_bytes__` of a command whose rendered context embeds a prior step's `duration_ms` (off-vs-off differs identically) and (b) 5/40 runs where the `step.enter` parent link points at an orchestrate drive instead of the completion — a pre-existing local-drive/reconcile race (2/40 flag off vs 3/40 on), identical once that link is ignored. Fused writes 115, per-event fallback exactly 10 (the two multi-tool steps × 5).

**Prod A/B #1** (v3.165.0): p50 better on all arms but await p95 +1.75 s. Root cause: `await-park` `try_resolve` saw the child terminal, then the child detail read answered NotFound and the error fell to the 5 s sweep — pre-existing (4× flag off) but hit 9× once children got faster. Fixed in **v3.165.1** (noetl/server#593: settle like the missing-call.done wait). **A/B #2** (v3.165.1, noisier hour): resolve failures 0 vs 0.

Pooled, both A/Bs (6 blocks per side; ~70 runs/arm/side, all COMPLETED):

| p50 / p95 | off | on |
|---|---|---|
| seq10_noop | 2.36 / 4.38 s | 2.23 / 5.19 s |
| seq10_py | 3.70 / 5.85 s | 3.26 / 4.89 s |
| await3 | 5.84 / 17.7 s | 5.47 / 8.33 s |

Per step one critical-path write fewer (fused 11.6–13.9 ms vs `call.done` 7–30 ms + `command.completed` 9–15 ms). The noop p95 rise comes from one environmentally slow on-block (whole-block p50 3.86 s) whose gaps are queue pickup / pre-dispatch / drive, not the fused write; no emit failures or refusals were logged. **ON since 2026-11-17T06:53:37Z.** After enabling: auth fallback 10/10, max 4.69 s (budget 15 s); 5/5 real travel turns (overhead/step p50 351 ms vs 359 ms before); real traffic fused 22, per-event 2 (multi-tool fallback live).

Rollback: `kubectl -n noetl set env deploy/noetl-worker-rust NOETL_WORKER_FUSE_LIFECYCLE-` (then image 6.18.0 `e5b1d72c` if needed); server `NOETL_EVENT_PUBLISH_BATCH-`; server image v3.165.0 `0709d7c2` / v3.164.0 `898313da`.

Known, not fixed here: the shadow chain populator logs `dangling_prev` a few times an hour (await3 resume links, and one read-race on a fused pair) — it refuses and falls back to Postgres by design; on/off counts 6 vs 11 (A/B #1), even in A/B #2.
