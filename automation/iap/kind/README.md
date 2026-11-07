# Infrastructure as Playbook: kind

NoETL playbooks that provision infrastructure on the local kind cluster, in place of
Terraform and Crossplane. Plan, apply, wait-for-ready, drift and destroy are steps of one
playbook.

**State** is NoETL's own `provider_fact` log, the same fact schema and fold as `kind: provider`
and `noetl provider`, in two phases (ADR-0002):
- **Phase 0 (bootstrap):** a local append-only file, copied to object storage after every
  write.
- **Phase 1 (steady state):** the EHDB event log, KV, projections and ehgraph, once the core
  is up.

Decisions: [docs/decisions/](../../../docs/decisions/README.md).

| Playbook | Stack | Spec |
|---|---|---|
| `log_analytics.yaml` | business-data stack: ClickHouse (community) + Vector + ClickHouse MCP, namespace `log-analytics`. Not a NoETL core component (ADR-0004) | [docs/specs/noetl-iac-log-analytics.md](../../../docs/specs/noetl-iac-log-analytics.md) |

```bash
# from the ops repo root, noetl CLI >= 5.4.0
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=plan    --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=apply   --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=verify  --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=drift   --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=state   --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=status  --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=destroy --set confirm=log-analytics --json | jq -r .final_result
```

`noetl iap apply automation/iap/kind/log_analytics.yaml --auto-approve --var action=<action>` is
equivalent. State lives in `.noetl/iac/log-analytics/facts.jsonl`; set
`--set state_backup=gs://…/facts.jsonl` for the object-store copy. It does not use the older
`noetl iap` DuckDB store (`.noetl/state.duckdb`).

Guard rails:
- Only `kind-*` contexts are allowed.
- Plan, apply and verify refuse to run while the host 1-minute load is above `max_load` (6).
- Destroy needs `confirm=<namespace>`.
- Every run writes `.noetl/log-analytics/latest.log`.

The GCP counterpart (GKE, Artifact Registry, state bucket) is in [`../gcp/`](../gcp/README.md).
