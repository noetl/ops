# BUILD_LOG

Append-only progress log for builds done in this repo. Newest entries go at the bottom.

## 2026-11-07: NoETL-as-IaC log-analytics stack on kind (+ qnetmon #13)

**Goal.** Provision ClickHouse community edition, Vector and the ClickHouse MCP server on
the local kind cluster, using NoETL playbooks only, as a concrete replacement for Terraform
and Crossplane. Rotate and capture logs, including the qnetmon edge daemon's logs (#13),
into ClickHouse, queryable over MCP. Spec: `docs/specs/noetl-iac-log-analytics.md`.

**Placement.**
- noetl/ops (branch `feat/log-analytics-iac`): provisioner playbook, manifests, kind config, CI checks, spec, docs.
- shastaranch/qnetmon (branch `013-edge-log-rotation`): edge rotation + shipper playbook, launchd agent, test, spec-kit feature `specs/003-edge-logs/`.
- noetl/ai-meta and its worktrees were not touched, because another session is using that tree.

**Built (ops).**
- `automation/iap/kind/log_analytics.yaml`, with actions plan, apply, verify, drift, status and destroy.
  It uses `kind: shell` + `kubectl --server-side --field-manager=noetl-iac` and hard readiness gates.
  The `kind: http` steps write and read a verify row with the keychain credential.
  The MCP JSON-RPC check runs from a shell step. Guard rails: kind-only context, host-load limit,
  NodePort ownership check, and confirm-gated destroy.
- `ci/manifests/log-analytics/`: namespace, ClickHouse 26.8.36.3 (StatefulSet + PVC, users in config),
  Vector 0.60.0 DaemonSet + RBAC, mcp-clickhouse 0.7.0 (bearer auth, read-only user), and `schema/logs.sql`.
- `ci/kind/config.yaml`: explicit kubelet log rotation (`containerLogMaxSize 10Mi`, `containerLogMaxFiles 5`)
  and the hostPort 30124 mapping for MCP (loopback only). Both take effect when the cluster is recreated.
- `ci/checks/validate.py`: new `iap-shell` check (bash -n of every templated shell block plus the
  step-graph integrity of every IaP playbook) and `iap-labels` check (ownership labels on every stack object).
- Docs: README (kind workflow step 5), automation/README tree, `automation/iap/kind/README.md`,
  `ci/manifests/log-analytics/README.md`, and pointers from the legacy `clickhouse.yaml` and `ci/manifests/clickhouse/README.md`.

**Findings that shaped the design.**
1. The PATH `noetl` is 2.17.0 and has no `credential` command. The playbooks need CLI ≥ 5.4.0
   (qnetmon's `.bin/noetl`).
2. CLI 5.4.0 local runtime hides shell stdout unless `--json` is passed, and never shows a failing step's
   stdout/stderr. Every step therefore tees to `.noetl/log-analytics/latest.log`, and `report` prints it as
   `final_result`.
3. The local `http` step has no timeout field and returns `{status, body}` without headers. It can't carry
   an MCP session id, so the MCP check uses curl.
4. `kind: mcp` is distributed-only and sends no auth headers, so it can't call a bearer-protected server.
5. `noetl subscribe --events` opens the sink with `truncate(true)`, not `O_APPEND`. #13 option B
   (truncate in place) would leave NUL-filled sparse files. qnetmon therefore rotates by rename + daemon restart.
6. The live kind node (44 days old) maps hostPort 30123 but not 30124, so verify falls back to a
   port-forward for MCP.

**Tests (offline, no cluster).**
- `python3 ci/checks/validate.py`: all checks pass (iap-shell 19 blocks, iap-labels 12 objects).
  Negative tests showed that an injected shell syntax error and an unlabelled ConfigMap each fail the gate.
- The playbook's guard rails ran under CLI 5.4.0: non-kind context REFUSED (exit 2); destroy without
  confirm REFUSED (exit 11); status against kind = "stack not applied" (read-only).
- `noetl iap apply automation/iap/kind/log_analytics.yaml --auto-approve --var action=help` works.
- Local `http` semantics were probed against an echo server: URL-encoded params, the `api_key` credential
  header, raw bodies (quotes, `{{ }}`, backticks) passed byte for byte, a 500 passed through as status,
  and connection refused fails the step.
- qnetmon `tests/run_logs.sh`: ALL PASS (SC-301..305). A mutation (commit without the 200 check) is
  caught. A dry run on a copy of the live `var/runs` shipped 123 event rows + 127 stderr rows to the stub.

**Follow-ups drafted, not filed** (`gh issue create` was refused by the session's permission policy;
the text is in spec §9):
- cli: failing shell step output hidden
- cli: subscribe sink truncates on open
- tools: `kind: mcp` auth/headers
- tools: `provider: kubernetes` family

**Kind status at build time.** At 05:21 PST, host load was 9–11 and the scheme-2 release cycle
(another session) was using kind. Its API was intermittently refusing connections earlier. Nothing was
applied. Everything is staged and ready to apply.

**To run when kind is free (load in the low single digits):**
```bash
N=/Volumes/X10/projects/shastaranch/qnetmon/.bin/noetl   # CLI 5.4.0
$N run automation/iap/kind/log_analytics.yaml -r local --set action=plan   --set noetl_bin=$N --json | jq -r .final_result
$N run automation/iap/kind/log_analytics.yaml -r local --set action=apply  --set noetl_bin=$N --json | jq -r .final_result
$N run automation/iap/kind/log_analytics.yaml -r local --set action=verify --set noetl_bin=$N --json | jq -r .final_result
$N run automation/iap/kind/log_analytics.yaml -r local --set action=drift  --set noetl_bin=$N --json | jq -r .final_result
$N run automation/iap/kind/log_analytics.yaml -r local --set action=destroy --set confirm=log-analytics --set noetl_bin=$N --json | jq -r .final_result
```

## 2026-11-07 (round 2): two-phase IaC state, business-data boundary, decision record

**User direction.** IaC must keep state on NoETL's own substrate, found in the code rather than
invented:
- Phase 0 (bootstrap): the CLI writes events and state to Feather files, backed up to object
  storage.
- Phase 1: the control loop holds state in the EHDB log, KV, projections and ehgraph.

ClickHouse is a business-data store only. Record every decision as an ADR.

**Found in the code.**
- **Shipped:**
  - `provider_fact`: noetl-tools `provider.rs` `pub mod state`, `ProviderFact`, `fold_facts`,
    orphans, conflicts.
  - Its event-log read-back: `/api/ehdb/tiers/eventlog`.
  - `noetl provider --facts-out/--facts-file`: the "EHDB-less git-backed state sink", JSONL.
  - The older `noetl iap` DuckDB `.noetl/state.duckdb`, with `gsutil` sync to GCS.
  - EHDB KV engine (`ehdb-reference` `kv.rs`): platform state, LWW, CAS, tombstones.
  - Projection refold and recovery routes.
  - ehgraph tool API.
  - Catalog register/resource, and catalog-log.
- **Designed, not shipped:** the CLI Feather local buffer (blueprint § H.11:
  `~/.noetl/local/<eid>/events.feather`, `noetl push`, `POST /api/events/batch`). It is
  deferred to R-1.4: CLI 5.4.0 has no `push` subcommand, and nothing in cli, server or worker
  writes or ingests it. Feather elsewhere is EHDB's execution-state and result tiers in
  object storage, not IaC state.

**Built.**
- **Playbook state:**
  - `state_load` folds the Phase 0 log, restoring it from `state_backup` if missing.
  - `record_state` appends one `ProviderFact` per declared resource (14 URNs: 12 manifest
    objects, the generated Secret, the ClickHouse schema), `changed` or `noop` by digest. It
    prunes owned-but-undeclared resources and copies the log to object storage.
  - `plan` and `drift` work from state, with five drift classes.
  - `destroy` deletes what the state owns and records `delete` facts.
  - New `state` action.
  - `state_phase: control-plane` is refused with the list of missing pieces.
  - The namespace digest annotation from round 1 is removed: the fact log is the one state.
- **CI:** `validate.py` `iap-state` extracts the fold from the playbook and checks it against
  9 `fold_facts` cases. A mutation (counting `planned` as owned) fails the check. `iap-shell`
  now reports YAML errors instead of crashing; it caught unquoted `desc:` values containing `: `.
- **Verified offline:**
  - The lib functions (`fact`, `kref`, fold, URN) were run. Facts match `ProviderFact` field
    for field.
  - `declared()` ran via a client-side dry-run (read-only discovery against kind). It lists
    14 resources.
- **Boundary:**
  - Vector captures only namespaces labelled `noetl.io/log-analytics=capture`.
  - The core bootstrap's ClickHouse deploy is now opt-in (`deploy_clickhouse: false`).
- **Decisions:** `docs/decisions/` ADR-0001 … ADR-0006, linked from the spec, the READMEs and
  the ops wiki.

**Still pending:**
- the Feather encoding of Phase 0 (CLI R-1.4)
- the Phase 1 handoff (event-log import path, `provider: kubernetes`, KV HTTP surface,
  ehgraph writer)
- kind validation: the cluster is still busy

## 2026-11-07 (round 3): Phase 0 on the real Feather buffer (R-1.4), push and ingest

**User direction.** Build the Feather path for real, rewire Phase 0 onto it (the encoding
changes; the facts and the fold do not), cut the releases, then validate on kind and merge.

**Built.**
- **noetl/cli#102** (merged), branch `feat/r1-4-feather-local-buffer`:
  - `src/local_buffer.rs`: § H.11.3 `events.feather` (Feather V2) + `metadata.json` under
    `$NOETL_LOCAL_DIR` or `~/.noetl/local`. Flushes are rewrite-and-rename chunks, guarded by
    a directory lock; a closed execution is immutable.
  - `noetl buffer init|append|close|list|cat`, `noetl push`, `noetl run --event-buffer`.
  - `--facts-file` accepts Feather.
  - 14 new tests: wiremock checks push headers, ordering, exactly-once and stop-on-failure;
    the JSONL and Feather encodings fold identically. pyarrow reads the files.
- **noetl/server#559**, branch `feat/events-batch-arrow-ingest`, rebased on v3.151.4:
  - `/api/events/batch` dispatches on Content-Type. JSON → the unchanged handler. Arrow →
    `handlers::events_arrow`, which answers 501 unless `NOETL_EVENTS_ARROW_INGEST=enabled`.
  - It appends to the EHDB event-log tier only, via the mirror's worker hop, tagged
    `mirror_source=local_push`. No `noetl.event`, no orchestrator; a source guard enforces
    this.
  - 11 tests, including a CLI-written fixture and HTTP tests against a stand-in worker.
- **ops** (`log_analytics.yaml`):
  - `state_file` → `state_dir`. Each `record_state`/`destroy` is one buffer execution
    (`state_begin` → `provider.fact` events → `state_commit`: close + backup).
  - The fold reads the closed executions of the stack. A read failure exits 15 rather than
    folding as empty. An uncommitted (RUNNING) write is ignored and reported.
  - Backup and restore are per execution (`<state_backup>/<eid>/`).
  - Preflight refuses a CLI without `buffer` (exit 14).
  - ADR-0007 is added; the ADR-0002 status, the spec §2/§3/§4.4/§5/§8/§9 and the READMEs
    are updated.

**Verified offline (CLI dev build, fake `gsutil`).**
- Commit → fold → prune → tombstone.
- A RUNNING write is ignored, and `last_execution_id` names the buffer execution.
- Backup holds one directory per execution. After the local state is deleted, a restore
  gives the same owned set.
- A corrupt `events.feather` stops the fold (exit 15).
- `validate.py`: all checks pass.

## 2026-11-07 (round 3, continued): releases, merges, pins; kind validation staged

**Merged and released.**
- noetl/cli#102 → **v5.5.0**.
- noetl/server#559 → **v3.152.0**. The release builds images only; nothing is deployed, and
  the Arrow ingest is off unless `NOETL_EVENTS_ARROW_INGEST=enabled`.
- noetl/ops#361 → `c49803e`.
- shastaranch/qnetmon#14 → `8b010a9`.
- ops wiki → `0c0bfb5`.
- noetl/ai-meta#535 pins cli v5.5.0, server v3.152.0, ops `c49803e` and the ops wiki. It was
  made from a separate clone; the shared ai-meta tree was not touched.

**Kind end-to-end: staged, not run.** At 10:00–10:10 PST the host 1-min load was 10–15,
from Adobe Creative Cloud processes, not kind. The kind VM (`podman machine noetl-dev`) was
stopped by the scheme-2 session, which has since gone idle.
`ci/kind/e2e_log_analytics.sh` is the one-shot run:
- plan, apply, verify;
- qnetmon `logs.yaml` shipping a copy of the live edge logs, then SQL and MCP counts;
- Phase 0 Feather state: second apply is a no-op, backup, loss, restore;
- drift: clean, then a foreign field manager (exit 10), then `reconcile=enforce`, clean;
- destroy and teardown checks.

The script uses a private credential store, state dir and a local object-store stand-in.
It refuses unless load < 5, and it stops the VM again if it started it. A dry check
refused at load 10.1 and touched nothing.

```bash
NOETL_BIN=<noetl >= 5.5.0> QNETMON=<qnetmon checkout> LIVE_RUNS=<qnetmon>/var/runs ci/kind/e2e_log_analytics.sh
```
