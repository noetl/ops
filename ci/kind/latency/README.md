# Latency benchmark harness (noetl/ai-meta#557)

Stage 0b of the latency-reduction plan (ai-meta `docs/rfc/latency-reduction-plan.md`, RFC #556). Every later stage
(#558 worker-local drive, #559 push completion, #561 fused segments) is accepted only on a before/after from this
harness: n ≥ 10 per arm, p50 and p95, and two repetitions.

## What it is

| File | Role |
|---|---|
| `stack.sh` | An **isolated** NoETL runtime inside the shared kind cluster: database `noetl_lat`, `sts/noetl-cmdbus-writer-lat`, `deploy/noetl-server-lat`, `deploy/noetl-worker-lat` (user pool, 4 slots), `deploy/noetl-worker-system-lat` (system pool, 2 slots). Specs are derived from the live A stack, so other sessions' stack is never touched. The server env is overlaid with **prod's dispatch path**: offserver state builder, publish-only ingest, retrigger-on-clear, shard-subject routing. Kind A does not run the offserver builder, so measuring on A would measure a path prod does not take. |
| `bench.sh` | `register`; `run PLAYBOOK N [C] OUT` (one warm-up discarded, then N executions C at a time; collects `GET /api/executions/{id}` per run, awaited children, and metric scrapes of the server and every lat worker before and after). |
| `report.py` | Per-transition p50 / p95 / mean from event timestamps; histogram means from the scrapes; `report.py A B` prints the deltas. |
| `auth.sh` | The **auth arm**: the real `api_integration/auth0/check_playbook_access` (vendored from noetl/e2e) against a provisioned auth schema, a seeded session and grant, the `pg_auth` credential and a callback sink. Must stay under the 15 s gateway budget (the #156 lesson). |
| `suite.sh` | The full matrix into one directory; `suite.sh --compare BEFORE AFTER` prints every arm's deltas. |
| `playbooks/` | `bench/seq10_noop`, `bench/seq10_py` (the #155 probe shape), `bench/child` + `bench/await3` (three awaited child hops), `bench/toollist` (one step with a 4-tool list). |

## Segments

Per step `s`, driven by the completion of its predecessor `p`:

| Segment | From → to | What it is today |
|---|---|---|
| `drive` | `command.completed(p)` → `step.enter(s)` | hand-off #1: completion → publish → materializer → trigger → `__orchestrate__` dispatched to the system pool → claimed → state built from the WAL spine → WASM → `call.done` → apply |
| `issue` | `step.enter(s)` → `command.issued(s)` | apply writing the command |
| `pickup` | `command.issued(s)` → `command.claimed(s)` | hand-off #2: feed delivery + server claim (the `noetl.command` event_id lookup, #283) |
| `start`, `tool`, `report` | claimed → started → `call.done` → `command.completed` | worker-local |
| `step` / `overhead` | `command.completed(p)` → `command.completed(s)`; `step − tool` | wall per step; orchestration per step |
| `hop.spawn` / `hop.child` / `hop.notice` / `hop.total` | awaited child: parent started → child started → child terminal → parent `call.done` | `hop.notice` is how long the parent took to *see* the child finish |

## Running it

```bash
# images must already be loaded into the kind node
SERVER_IMAGE=ghcr.io/noetl/server:3.161.2 WORKER_IMAGE=ghcr.io/noetl/worker:6.15.0 ci/kind/latency/stack.sh up
ci/kind/latency/suite.sh runs/before
ci/kind/latency/stack.sh set --server-env NOETL_SERVER_ADVANCE_API=true --worker-env NOETL_WORKER_LOCAL_DRIVE=true
ci/kind/latency/suite.sh runs/after
ci/kind/latency/suite.sh --compare runs/before runs/after
ci/kind/latency/stack.sh down
```

`stack.sh set` flips flags or swaps images on the lat stack only and waits for the rollout. An empty value (`K=`)
removes a variable.

## Baseline, 2026-11-14 (server 3.161.2, worker 6.15.0, kind, prod dispatch path)

Two repetitions, n = 20 (noop, py), 10 (await, auth), 32 at concurrency 8 (load). Milliseconds.

| Arm | Metric | rep 1 p50 / p95 | rep 2 p50 / p95 |
|---|---|---|---|
| noop | orchestration per step | 32.3 / 39.8 | 35.5 / 47.3 |
| noop | `drive` / `pickup` | 18.8 / 23.3 · 6.4 / 9.7 | 20.9 / 25.8 · 7.3 / 12.2 |
| py | orchestration per step | 39.2 / 49.8 | 35.9 / 45.7 |
| await | `hop.notice` (child done → parent sees it) | 1949.9 / 1977.3 | 1941.6 / 1983.8 |
| await | `hop.total` per awaited hop | 2037.8 / 2073.4 | 2040.6 / 2079.0 |
| load (C=8) | orchestration per step | 147.9 / 276.8 | 252.7 / 888.6 |
| load (C=8) | `drive` / `pickup` | 125.1 / 249.8 · 10.9 / 17.2 | 125.8 / 785.5 · 12.2 / 39.1 |
| auth | client-observed execute → terminal | 761 / 940 (max 965, budget 15 000) | 738 / 772 (max 774) |

Rep 2's load arm ran with the host at a 1-minute load average of 6–8 on the 6-CPU podman VM, and its p95 tail
(785 ms drive, five drives over 1 s) is host noise rather than a property of the stack; rep 1 ran on a quieter host.
`run.json` now records the host load at the start and end of every arm, and stage comparisons interleave before and
after arms rather than running them back to back.

**What it shows.**
- Kind idle is not prod. Prod measured ~0.95 s per step (2026-11-02, n = 4); kind idle is ~32–40 ms, because every
  round trip is in-node and the claim lookup is fast on a small table. Stages are judged on kind by their
  *relative* effect on the segment they target, and the absolute prod figure is re-measured read-only.
- **The drive hand-off is the segment that grows with load**: 19 ms idle → 125 ms p50 / 250 ms p95 at 8 concurrent
  executions, while pickup stays ~11 ms. Every drive queues on the 2-slot system pool, rebuilds state from the full
  event spine (`run/from_events`, ~17 M WASM fuel per drive) and runs behind a per-process WASM mutex. This is
  Stage 1's target.
- **An awaited child hop costs ~2.04 s, of which ~1.95 s is the parent not yet looking**: the child finishes in
  ~70 ms; `kind: playbook` sleeps `poll_interval` (default 2 s) *before* its first poll. This is Stage 2's target.
- A step's ordered tool list is already one command (`bench/toollist`: one `command.issued` / `command.claimed` for
  a 4-tool step, executed in-process by `task_sequence`).
