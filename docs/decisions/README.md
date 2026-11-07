# Decision records (noetl/ops)

Each record has a date, a decision, the rationale and the alternatives considered. Records
are append-only: a decision changes by adding a new record that supersedes the old one, not
by editing history.

| ADR | Date | Decision | Status |
|---|---|---|---|
| [0001](ADR-0001-noetl-as-iac.md) | 2026-11-07 | NoETL playbooks provision infrastructure in place of Terraform/Crossplane | Accepted, implemented (kind) |
| [0002](ADR-0002-two-phase-iac-state.md) | 2026-11-07 | IaC state is two-phase: Phase 0 CLI bootstrap files with an object-store backup → Phase 1 EHDB log + KV + projections + ehgraph | Accepted. Phase 0 implemented; its interim JSONL encoding is superseded by 0007; Phase 1 pending |
| [0003](ADR-0003-desired-observed-drift.md) | 2026-11-07 | Desired = catalog + versioned playbooks; observed = append-only fact log + rebuildable fold; drift = declared vs state vs live | Accepted, implemented |
| [0004](ADR-0004-clickhouse-business-data-only.md) | 2026-11-07 | ClickHouse is a business-data store, never a NoETL core component | Accepted, implemented |
| [0005](ADR-0005-business-logs-vs-core-state.md) | 2026-11-07 | Business and network logs go to ClickHouse; NoETL core operational events and state stay in EHDB | Accepted, implemented |
| [0006](ADR-0006-terraform-crossplane-mapping.md) | 2026-11-07 | The spec maps NoETL IaC to Terraform and Crossplane explicitly | Accepted |
| [0007](ADR-0007-phase0-feather-state.md) | 2026-11-07 | Phase 0 state is the CLI's Arrow Feather event buffer (R-1.4); `noetl push` imports it onto the EHDB event log | Accepted, implemented (cli#102, server#559). Supersedes 0002's interim JSONL encoding |

Spec: [../specs/noetl-iac-log-analytics.md](../specs/noetl-iac-log-analytics.md).
