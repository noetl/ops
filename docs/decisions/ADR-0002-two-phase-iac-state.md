# ADR-0002: IaC state is two-phase — CLI bootstrap files, then the NoETL control plane

- **Date:** 2026-11-07
- **Status:** Accepted.
  - Phase 0 is implemented for the kind stack, using the shipped fact format (JSONL).
  - The Arrow Feather encoding of Phase 0 waits on CLI phase R-1.4.
  - The Phase 1 handoff is designed but not wired (see "Implementation status").

## Context: how NoETL stores state today (from the code, 2026-11-07)

| Mechanism | Where | What it holds | Status |
|---|---|---|---|
| **`provider_fact` on the EHDB event log** | `noetl-tools` `src/tools/provider.rs`, `pub mod state`: `ProviderFact {urn, provider, service, resource_type, verb, stack, desired, execution_id, outcome}`, `fold_facts` → `OwnershipModel {owned, tombstoned}`, `detect_orphans_scoped`, `detect_stack_conflicts` | IaC ownership/desired facts. They ride inside step results, and are read back from the raw event-log tier `/api/ehdb/tiers/eventlog`. The `/api/ehdb/events` projection is secret-free and excludes result bodies, so the fold reads the raw tier. | **shipped** (GCP provider) |
| **`noetl provider --facts-out / --facts-file`** | `cli/src/provider_cli.rs` | "the EHDB-less git-backed state sink": an append-only file of provider facts, one per line, read back with `--facts-file`. `--server` instead reads the EHDB event-log tier. | **shipped** (JSONL) |
| `noetl iap` DuckDB state | `cli/src/lib.rs` `IapCommand`: `.noetl/state.duckdb`, `noetl iap sync push/pull` to `gs://<bucket>/workspaces/<ws>/state.duckdb` via `gsutil` | the earlier IaP state store for the GCP playbooks, with object-store backup | shipped, older |
| **CLI local Arrow Feather buffer** | blueprint § H.11 (noetl/docs `noetl_global_hybrid_cloud_grid_distributed_architecture_blueprint.md`): `~/.noetl/local/<execution_id>/events.feather` + `commands.feather` + `metadata.json`, pushed with `POST /api/events/batch` (`application/vnd.apache.arrow.file`), `noetl push`, `--offline` | the local-mode event + command stream as Feather V2 | **designed, deferred to phase R-1.4.** No `noetl push` (CLI 5.4.0: `unrecognized subcommand 'push'`), no `LocalEventBuffer`, no server batch ingestion. The codec exists: `noetl_tools::arrow_codec::{encode_record_batch, decode_record_batches}` |
| Feather in EHDB's object tier | `ehdb-reference` `object.rs`; worker `state_materializer` / `result_materializer` | execution state shards `…/execution=<eid>/state/{open,sealed}.feather` and the result tier `…/results/…/<attempt>.feather` in object storage | shipped (execution state, not IaC) |
| EHDB KV | `ehdb-reference` `src/kv.rs` | the platform-state tier: every write is an append to one canonical stream, last-writer-wins per key, tombstone deletes, CAS on expected version, TTL, clock-free and replayable. "business data never flows through it" | engine shipped. No `/api/` KV route on noetl/server yet |
| EHDB projections | noetl/server `/api/ehdb/projection-fold/*`, `projection-refold`, `projection-recovery` | read models folded from the log, rebuildable and checked for determinism | shipped |
| ehgraph | noetl/ehgraph: `/v1/tools/{tool}`, `/mcp`, node/edge upsert (`ehgraph-store`) | topology and relationships | shipped (qnetmon uses it) |
| Catalog | noetl/server `/api/catalog/register`, `/api/catalog/resource`, `/api/catalog-log/*`; noetl/catalog ("event-sourced catalog … persisted through EHDB") | versioned playbooks and resources | shipped |

## Decision

IaC state uses NoETL's own substrate in two phases. It has no external backend and no lock
file.

**Phase 0 — bootstrap (before EHDB and noetl-server exist).**
- The **noetl CLI** writes the provisioning events and state to the **local filesystem**, and
  copies them to **object storage** (GCS/S3) after every write.
- This is the chicken-and-egg answer: the steps that stand up the NoETL core, EHDB included,
  can't keep their state in EHDB.
- The record format is the shipped `ProviderFact` (one fact per resource per apply or
  delete), so the same `fold_facts` semantics apply in both phases.
- The target encoding is **Apache Arrow Feather V2**, per blueprint § H.11. Facts become
  rows of `events.feather`, with the fact in the `result` column.

**Phase 1 — steady state (once the NoETL core is up).**
- Ownership **hands off to the NoETL control loop**. Provisioning runs on the distributed
  runtime, so its facts land on the **EHDB event log** natively, inside step results.
- Current state is the **fold/projection** of that log: `/api/ehdb/tiers/eventlog` plus the
  `provider_state` fold, the same path as `noetl provider --server`.
- An **EHDB KV** bucket (`iac.<stack>`, key = URN) holds the fast current-state view. CAS
  writes give a **fenced single writer per stack**.
- **ehgraph** holds the topology: resources as nodes, DAG dependencies and stack ownership as
  edges.
- The Phase 0 log is imported once as the genesis segment and archived in object storage.

## Implementation status (2026-11-07)

**Built, for the kind stack (`state_phase: bootstrap`):**
- `record_state` appends one `ProviderFact` per declared resource (changed or noop) and per
  pruned resource to `.noetl/iac/log-analytics/facts.jsonl`. Its format is identical to
  `noetl provider --facts-out`.
- After every write, `state_backup` (`gs://…` via `gsutil`, the `noetl iap sync` pattern, or
  `s3://…` via `aws`) copies the log to object storage.
- `state_load` restores from the backup when the local log is missing.
- `plan`, `drift`, `state` and `destroy` fold the log, using the same rules as `fold_facts`,
  and act on it.
- `ci/checks/validate.py` `iap-state` pins the fold to the `fold_facts` rules: 9 cases, plus
  a negative test.

**Pending:**
1. **Feather encoding of Phase 0.** This needs CLI R-1.4: a `LocalEventBuffer` (Feather V2
   writer on `arrow_codec`) plus `noetl push`. Until then Phase 0 uses the shipped JSONL fact
   format. Moving to Feather changes the encoding only, not the schema or the fold.
2. **Phase 1 handoff.** `state_phase: control-plane` is refused today with an explanation. It
   needs:
   - (a) a way to put the Phase 0 log onto the EHDB event log: R-1.4's
     `POST /api/events/batch`, or an import playbook run on the distributed runtime that emits
     each fact as a step result;
   - (b) provisioning steps that run on workers: `provider: kubernetes`, or a kubectl-capable
     pool;
   - (c) a KV HTTP surface;
   - (d) the ehgraph topology writer.

## Rationale

- **The state is the event log**, not a mutable file. It is append-only, so every
  apply/create/delete is an audited fact. It can be replayed (the fold is deterministic) and
  rebuilt (the current state is derived, never primary).
- A torn write in Phase 0 loses at most the last line, and the log stays foldable. Nothing
  overwrites state in place.
- Phase 0 answers a bootstrap problem Terraform pushes onto an external backend: portable
  files plus an object-store copy, owned by the CLI. Phase 1 makes NoETL self-hosting: the
  platform's own log, KV, projections and graph hold its infrastructure state.
- Reusing `ProviderFact`/`fold_facts` means the kind stack, the GCP provider and
  `noetl provider` all share one state model and one fold.

## Alternatives considered

- **A bespoke state file**, Terraform-style, mutable, with a lock. Rejected: it's an opaque
  thing to corrupt and lock, and it duplicates what the fact log already is.
- **Kubernetes-only state** (labels, managedFields, annotations), which was round 1 of this
  stack. Rejected as the source of truth: it has no history, it can't represent deleted
  resources (no tombstones) or non-Kubernetes resources (the ClickHouse schema), and it dies
  with the cluster. Labels stay as a cross-check: drift reports labelled objects the state
  doesn't own.
- **`noetl iap` DuckDB (`.noetl/state.duckdb`).** This is a mutable database file synced
  whole to GCS. Rejected: it is last-writer-wins on the whole file, and the platform has
  moved to the fact log.
- **ClickHouse.** Rejected: it is a business-data store (ADR-0004), and core state must not
  depend on it.
