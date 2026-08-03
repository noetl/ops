# EHDB-only platform topology, as NoETL playbooks

NATS was deleted from the NoETL platform on 2026-08-01. Command dispatch, the
events feed, the SSE fan-out and the KV store behind the gateway's sessions and
requests are all served by the EHDB writer now.

**None of that shape existed as IaC.** `origin/main` carried zero occurrences of
`NOETL_COMMAND_BUS`: the prod topology was produced with `kubectl set env` and
`kubectl patch` during the cutover and never written back, so there was nothing
to redeploy from and no file to read to find out what prod actually runs. The
EHDB-only kind soak had to reconstruct the whole topology from the worker source
before it could test anything.

This directory is that reconstruction, declared as playbooks and run through the
`noetl` CLI in local mode — the same way the rest of `automation/` works.

## The playbooks

| Playbook | Reconciles |
| :-- | :-- |
| `ehdb_platform.yaml` | **Entry point.** Guards the target cluster, then drives the other four. |
| `ehdb_writer.yaml` | The writer StatefulSet, its per-shard PVCs, the headless Service and one ClusterIP per shard. All nine bus faces. |
| `ehdb_runtime.yaml` | Server, user pool, system pool and gateway pointed at those faces, with the NATS-era env stripped off. |
| `ehdb_autoscaler.yaml` | The user pool's KEDA ScaledObject on EHDB per-subject lag, plus the writer's scrape (GMP `PodMonitoring` or VictoriaMetrics `VMPodScrape`, whichever the cluster has). |
| `ehdb_verify.yaml` | The functional proof. Paired evidence, not a green execution count. |

Each playbook has a header comment carrying the reasoning behind its shape —
why a StatefulSet, why a patch instead of a full manifest, why `metrics-api`
instead of `prometheus`. Read those before changing values.

## Running it

```bash
# from repos/ops
noetl run automation/ehdb/ehdb_platform.yaml --runtime local \
  --set action=converge --set profile=kind --set context=kind-noetl
```

| `action` | Does |
| :-- | :-- |
| `plan` | Renders every object and server-side dry-runs it. Changes nothing. |
| `converge` | Reconciles the topology, then verifies it. |
| `status` | Reports what is deployed and asserts the EHDB-only invariants. |
| `verify` | The functional proof against an already-converged cluster. |
| `teardown` | Removes the ScaledObject and the writer. PVCs are kept. |

`profile` is `kind` or `prod`, and it is a guard as well as a set of defaults:
`kind` refuses any context that is not `kind-*`, and `prod` refuses one that is.
Everything a profile sets can be overridden with `--set`.

## The nine faces

```
9100 cmdbus ingest   9103 events ingest    9106 events lag/metrics
9101 cmdbus claim    9104 events claim     9107 KV
9102 cmdbus lag      9105 events SSE       9108 WAL fan-out
                     9090 worker metrics
```

`9107` and `9108` appear in no manifest anywhere else in this repo — the
events-writer patch that predates them never had them. Everything that reads
the KV store (the gateway's session cache and request store) or the WAL fan-out
(the off-server state builder) depends on them being bound.

Naming trap worth knowing before editing: `NOETL_COMMAND_SHARD_COUNT` and
`NOETL_EVENT_SHARD_COUNT` carry no `_BUS_`, while every bind does.

## Addressing, and why the writer is a StatefulSet

The writer is a singleton **per command shard** over an RWO volume. Prod ran
that as one hand-copied Deployment per shard, which is how a two-shard cluster
ended up with two manifests differing only in an index.

A StatefulSet says the same thing once: the pod ordinal *is* the shard, the
`volumeClaimTemplates` give each shard its own volumes, and the controller will
not run two pods with the same ordinal. Pod names come out as
`noetl-cmdbus-writer-0`, `-1` — the names prod already resolves — so this is a
drop-in for the per-shard Deployments rather than a re-address.

Services:

- `noetl-cmdbus-writer-headless` — the governing service.
- `noetl-cmdbus-writer-<N>` — a ClusterIP per shard, selecting one pod by
  `statefulset.kubernetes.io/pod-name`. This is the address the server, the
  pools, the gateway and KEDA all use.

There is deliberately **no** aggregate ClusterIP across shards. At
`shard_count > 1` it would round-robin claim and ingest traffic across shards,
which is silent mis-routing of the class tracked as
[noetl/ai-meta#218](https://github.com/noetl/ai-meta/issues/218).

The container `ENTRYPOINT` is exec-form (`./noetl-worker`, no shell), so the
ordinal is turned into `NOETL_COMMAND_BUS_SHARD` / `NOETL_EVENT_BUS_SHARD` by a
one-line `sh -c` wrapper in `command:`. That wrapper is the only reason one
manifest covers N shards.

### Storage modes

| `writer_storage_mode` | Shape |
| :-- | :-- |
| `template` (default) | `volumeClaimTemplates`. PVCs named `<vct>-<sts>-<ordinal>`. For a fresh cluster and for `shard_count > 1`. |
| `claim` | Mounts pre-existing, explicitly named PVCs. `shard_count=1` only. |

`claim` is the **adoption path**. A cluster already running the writer as a
Deployment with hand-named PVCs — which is prod today — converts to a
StatefulSet without moving a byte of the durable log. Without it, adopting the
StatefulSet on prod would mean provisioning fresh volumes and abandoning the
command and event logs on the old ones.

## Multi-shard

`shard_count` sizes the StatefulSet and renders the server's `N@host:port`
address lists from the same number. The two must not drift: the server's
publish router keeps one client per shard and errors on a missing one, at
publish time rather than at boot.

Two things do **not** follow automatically from `shard_count` and need a shape
change rather than a value change:

- **Per-pool claim addresses.** The pools are pointed at shard 0's claim face.
  A genuinely multi-shard cluster needs per-pool claim addressing, which lives
  on the pool Deployments in `ci/manifests/noetl/`.
- **The ScaledObject.** One object reads one shard's `:9102`. N shards need N
  objects, one per (pool, shard) pair.

## What this does not do

It does not install KEDA, create the namespace, deploy Postgres, or build
images. Those belong to `automation/development/noetl.yaml` (kind) and
`automation/gcp_gke/noetl_gke_fresh_stack.yaml` (GKE). These playbooks take a
cluster that already runs NoETL and reconcile the **bus topology** on it.

## Two `noetl` local-runtime quirks these playbooks are shaped around

Both were found while building this set, and both are worth knowing before
editing it.

**Conditional arcs do not work.** A `when:` on a `next.arcs` entry does not
reliably take its arc. On `noetl` 2.17.0 a true condition takes it roughly half
the time — measured over repeated identical runs of the same file, with no
input varying. On a build of 4.19.0 it never takes it: a true condition falls
through to the unconditional arc every time.

For IaC that failure mode is the worst possible one — the playbook reports
success and silently reconciles nothing, which is the same silent-no-op class
the EHDB cutover has already been bitten by twice. So there is **no `when:`
anywhere in this directory**. The chain is linear, every child receives the
action, and each step guards itself in shell with a `case`. A step that does
not own the current action prints `skip (action=…)` and exits 0.

**Templating is plain substitution.** `{{ workload.x }}` works; `{{ 'a' if x
else y }}`, `{% if %}` and filters are passed through as literal text. That is
why every child speaks the same action vocabulary as the parent — there is
nowhere to translate one into another.

One more, cosmetic: the 4.19.0 build runs these playbooks correctly (rc 0,
steps in order) but does not print shell stdout, so the plan renderings and the
verify verdict are invisible there. Run them on 2.17.0 until that is fixed.

## Why the verification is not an execution count

Every defect the NATS deletion produced failed *silently while executions still
completed*:

- `should_publish` required a NATS connection. Removing `NOETL_NATS_URL` made
  the gate false for every event, so the server quietly fell back to a
  synchronous insert. Nothing errored, executions completed, the durable log was
  written — and the whole CQRS publish path was inert with the feed cursor flat.
- The off-server state builder turned out to be an uninventoried fourth consumer
  of the events feed. With NATS gone, every orchestrate returned `WAL chain
  incomplete`, executions stalled at RUNNING, and no error appeared anywhere.

A green execution count would have signed off on both. So `ehdb_verify.yaml`
pairs the counters against each other instead:

```
published == projected
  AND every materializer group's cursor advanced by that same delta, ending at lag 0
  AND ehdb_events_cursor_errors == 0
  AND ehdb_l0_out_of_order_appends == 0
  AND 0 publish errors, 0 duplicate execution ids
  AND every SSE subscriber saw frames
```

`noetl_events_materialized_total` is **not** a substitute for
`noetl_events_projected_total` — it counts an `events/materialize` sink this
deployment does not use, and reads 0 forever.

An unreadable metric counts as a **failure**, never as a zero. A poll that
coerces `NA` to 0 "drains" instantly and passes; that false pass has already
been produced once by a harness against this topology.

### Never connect to :9104, :9107 or :9108 to check them

Those faces speak the ehdb-feed wire protocol (4-byte BE length + JSON), not
HTTP, and `ehdb_feed::serve` handshakes *inside* its accept loop — so a
connection that does not complete the handshake escapes the whole function and
drops the listener. The face is then dead for the life of the process, with one
ERROR line and nothing else
([noetl/ehdb#311](https://github.com/noetl/ehdb/issues/311)).

**It is not only a malformed frame that does this. A connect that sends nothing
and closes is enough** — `read_frame` returns `early eof` and takes the same
path. `ehdb_verify.yaml`'s preflight was originally `nc -z` and it killed :9108
on its first run against a freshly converged writer; the ERROR line was the only
trace. A kubernetes `tcpSocket` probe pointed at any events face would do the
same thing on every period, forever.

So face liveness is read from the pod's own listening sockets (`netstat -ltn`)
and nothing is ever connected to. For the same reason the writer's readiness and
liveness probes point at the command-bus claim face :9101, which does not share
that shape, and must not be repointed.

## Fail-loud env that must never become optional

`NOETL_MATERIALIZER_SOURCE`, `NOETL_RESULT_MATERIALIZER_SOURCE`,
`NOETL_STATE_MATERIALIZER_SOURCE` and `NOETL_STATE_BUILDER_SOURCE` are rendered
unconditionally on the system pool. Unset used to fall through to the deleted
NATS transport, so a materializer would sit on a flat cursor while executions
kept completing and nothing errored
([noetl/ai-meta#221](https://github.com/noetl/ai-meta/issues/221)).

`NOETL_STATE_BUILDER=shadow` is **not** how shadow is spelled. `builder_mode()`
only recognises `offserver` on that variable and otherwise falls through to a
separate flag, so a sensible-looking `shadow` silently means Off and the WAL
fan-out face never gets a client. Shadow is `state_builder_shadow=true`.

## Prod

Validated in kind only. Applying to prod is a separate, deliberate step —
`plan` first, and read the output.

```bash
noetl run automation/ehdb/ehdb_platform.yaml -r local \
  --set action=plan --set profile=prod \
  --set context=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot \
  --set writer_storage_mode=claim \
  --set writer_storage_class=premium-rwo \
  --set writer_image=ghcr.io/noetl/worker@sha256:<digest> \
  --set writer_image_pull_policy=IfNotPresent \
  --set state_builder_shadow=false \
  --set gateway_reconcile=true
```

Things to know before that run:

- **`writer_storage_mode=claim` is not optional on prod.** The existing PVCs
  hold the live command and event logs. `template` would provision new ones and
  strand the old.
- **`premium-rwo`.** The writer's durability posture is fsync-per-append, so
  disk sync latency *is* the append-latency budget. On PD-standard a synced
  append is tens of ms and the bus falls outside the envelope NATS set.
- **`state_builder_shadow=false`.** Prod runs `NOETL_STATE_BUILDER=server`; the
  off-server subsystem is off there, and enabling the shadow drain would put a
  new client on `:9108` in production
  ([noetl/ai-meta#217](https://github.com/noetl/ai-meta/issues/217)).
- **The Deployment→StatefulSet conversion drops the writer pod once.** The
  `drain_legacy_deployment` step scales and deletes the old Deployment before
  the StatefulSet can attach the RWO volumes. Commands issued in that window are
  re-issued by the orphaned-command guardrail
  ([noetl/ai-meta#171](https://github.com/noetl/ai-meta/issues/171)) roughly 30s
  later, so it is survivable — but it is a real interruption, not a no-op.
- **Prod's gateway must be reconciled explicitly** (`gateway_reconcile=true`).
  The kind rig has no gateway, so `auto` skips it there and says so loudly.

## A re-apply reports the StatefulSet as `configured`

`kubectl apply` prints `configured` whenever the server accepts a patch, and
the writer StatefulSet's `volumeClaimTemplates` get server-side defaults that
differ from what is sent, so the patch is never byte-empty. It is still a no-op:
`.metadata.generation` does not move and no pod restarts. The Services, the
ScaledObject and the Deployment patches all report `unchanged` / `patched (no
change)` outright.

Generation is the thing to check if you want to be sure a converge changed
nothing:

```bash
kubectl -n noetl get sts,deploy \
  -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} gen={.metadata.generation}{"\n"}{end}'
```
