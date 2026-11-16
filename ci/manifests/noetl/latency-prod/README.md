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
