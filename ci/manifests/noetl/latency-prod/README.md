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
