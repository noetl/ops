# ADR-0007: Phase 0 IaC state is the CLI's Arrow Feather event buffer (R-1.4)

- **Date:** 2026-11-07
- **Status:** Accepted, implemented.
  - **Supersedes:** the interim JSONL encoding of Phase 0 in [ADR-0002](ADR-0002-two-phase-iac-state.md),
    pending item 1 (`.noetl/iac/<stack>/facts.jsonl`).
  - **Unchanged:** the two-phase model, the `ProviderFact` schema and the `fold_facts` rules
    from ADR-0002 and ADR-0003.
  - **Implemented in:** noetl/cli#102 (CLI buffer + `noetl push`), noetl/server#559 (Arrow
    ingest), and this repo's `automation/iap/kind/log_analytics.yaml`.

## Context

ADR-0002 set the target encoding of Phase 0 as Apache Arrow Feather V2 (blueprint § H.11),
but nothing in the code wrote or read it. Phase 0 therefore shipped on the `--facts-out` JSONL
format, with the note that moving to Feather "changes the encoding only".

The user then asked for the Feather path to be built for real:
- the CLI local buffer;
- `noetl push`;
- server-side batch ingest;
- Phase 0 moved onto it.

What existed to build on (2026-11-07):
- `noetl_tools::arrow_codec` (an IPC stream codec, used for result payloads);
- the arrow-rs 53 crates already linked by noetl-tools (CLI) and ehgraph (server);
- the `ExecutorEvent` / `EventSink` envelope in `noetl-events`. The local runner does not
  emit through it, so there was no sink to swap;
- the worker's `POST /ehdb/tiers/eventlog` append, which the server's event-log mirror
  already uses, and which `GET /api/ehdb/tiers/eventlog` and `noetl provider --server` read
  back;
- the existing worker JSON `POST /api/events/batch`. It writes `noetl.event` and triggers
  the orchestrator.

## Decision

**1. The CLI buffer (§ H.11.3).**
- Layout: `<root>/<execution_id>/events.feather` + `metadata.json`.
- `<root>` is `$NOETL_LOCAL_DIR` or `~/.noetl/local`; the playbook overrides it with
  `state_dir`.
- `events.feather` is a Feather V2 (Arrow IPC *file*) with the § H.11.3 schema, column for
  column: `event_id, execution_id, event_type, step, status, created_at, context, result,
  meta, parent_event_id, payload_ref`.
- One chunk per flush. Each flush writes the complete file to a temp path, fsyncs it and
  renames it into place.
- An execution is `RUNNING` until `close`, then `COMPLETED`/`FAILED`, and immutable.
- Ids are local snowflakes, time-ordered.
- Interface: `noetl buffer init|append|close|list|cat`, and `noetl run -r local
  --event-buffer`.

**2. IaC facts are `provider.fact` events.**
- The fact sits at `result.data.provider_fact`, the first path noetl-tools'
  `fact_in_record` probes.
- So the server's tier extractor, `noetl provider --facts-file <events.feather>` and the
  playbook's jq fold all read the same facts.
- The fold itself (`FOLD`, pinned by `validate.py iap-state`) is unchanged.

**3. One closed execution per state write.**
- `record_state` (apply) and `destroy` each open an execution (`state_begin`), append their
  facts, close it and back it up (`state_commit`).
- The facts' `execution_id` is that execution's id, so `last_execution_id` in the fold
  names a real buffer directory.
- State = the `provider.fact` events of every *closed* execution of the stack, oldest first.
- A write interrupted before `close` stays `RUNNING`. It is ignored by the fold and reported
  by `state_load` as uncommitted.

**4. Object-store backup is per execution.**
- After each commit, `events.feather` and `metadata.json` are copied to
  `<state_backup>/<execution_id>/` (`gsutil`, or `aws s3`).
- `state_load` restores every execution from the backup when the stack has none locally.

**5. `noetl push` is the bridge into Phase 1 (§ H.11.5).**
- It POSTs each closed buffer verbatim to `POST /api/events/batch` with
  `Content-Type: application/vnd.apache.arrow.file`, `X-NoETL-Execution-Id` and
  `X-NoETL-Event-Count`.
- It pushes oldest first, stops at the first failure, and records `pushed_at`.

**6. The server ingest is a separate, side-effect-free branch.** It is chosen by
Content-Type and off unless `NOETL_EVENTS_ARROW_INGEST=enabled`.
- It decodes and validates the file, then appends the events to the **EHDB event-log tier
  only**, through the mirror's worker hop, tagged `mirror_source: "local_push"`.
- It never writes `noetl.event` and never triggers orchestration or chain linkage. A local
  execution never existed on that server.
- The JSON batch path is unchanged.

## Rationale

- **The format the blueprint chose.** The file that is the bootstrap state is the same file
  `noetl push` sends and the server decodes. The hand-off needs no conversion step.
- **A real commit boundary.** A JSONL append can tear mid-line, and every appended line is
  live immediately. Here a write becomes state only when its execution closes, and the
  rename makes every file on disk complete. The fold reads committed writes only.
- **History for free.** Each apply or destroy is its own execution with its own metadata
  (action, run id, timestamps). That is Terraform's state *serials*, kept rather than
  overwritten, and individually backed up and pushable.
- **Columnar and inspectable.** `pyarrow.feather.read_table` reads it directly, and the
  same chunks are what EHDB's object tier and the Arrow cache speak.
- **No new state model.** `ProviderFact` and the fold are untouched. The CLI test
  `facts_file_accepts_a_feather_buffer_and_folds_identically` shows the same facts give the
  same owned and tombstoned sets whether they are encoded as JSONL or as Feather.

## Alternatives considered

- **Keep JSONL (`--facts-out`).** Rejected for Phase 0 state. It has no commit boundary,
  it isn't the § H.11 format, and pushing it would need a converter. `--facts-out` and
  JSONL `--facts-file` stay supported for `noetl provider`, so nothing is removed.
- **One stack-wide Feather file**, rewritten each apply. Rejected: each write would rewrite
  all of history, and it breaks the per-execution § H.11 layout that `noetl push` and the
  server contract are built on.
- **Arrow IPC *stream* format** (what `arrow_codec` emits). Rejected: § H.11.5 names the
  *file* media type. The file format has a footer for random access, and both ends can
  reject a truncated upload by its missing footer magic.
- **In-place append with "chunk-boundary footers"** (§ H.11.2's wording). Not possible as
  stated: an Arrow IPC file has exactly one footer. The rewrite-and-rename keeps both
  properties the text wanted, an always-readable file and chunk boundaries. It costs
  O(file) per flush, which is trivial at IaC sizes, and a multi-file layout is the upgrade
  path.
- **Ingest pushed events into `noetl.event` via the existing JSON batch logic.** Rejected:
  that path needs a catalog id, links the execution chain and triggers the orchestrator.
  The sweeps would see an execution the server never started.
- **A new route** (e.g. `/api/events/import`). Rejected: § H.11.5 specifies
  `/api/events/batch` with a content-type sniff. Dispatching on Content-Type keeps the
  contract while leaving the JSON handler byte-identical.

## Not done, on purpose

- `commands.feather` and the `payloads/` large-payload offload from § H.11.3 aren't
  written. Provisioning emits no commands, and no fact comes near the 4 MiB threshold.
  The schema reserves `payload_ref` for the offload.
- No migration of existing JSONL state. The kind stack had never been applied when this
  landed, so there was nothing to migrate. Another stack could import with
  `jq -c '{event_type:"provider.fact",result:{data:{provider_fact:.provider_fact}}}' facts.jsonl | noetl buffer append <eid> --jsonl -`.

## Effect on ADR-0002 "Pending"

- **Item 1** (Feather encoding) is done.
- **Item 2(a)** (an event-log import path) now exists: `noetl push` plus the server's Arrow
  branch. Using it needs both gates opened on the target cluster:
  - server `NOETL_EVENTS_ARROW_INGEST=enabled`;
  - worker `NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server`.
- `state_phase: control-plane` stays refused until 2(b)–(d) are done:
  - worker-side provisioning;
  - a KV HTTP surface;
  - the ehgraph writer.
