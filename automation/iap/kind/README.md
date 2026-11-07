# Infrastructure as Playbook: kind

NoETL playbooks that provision infrastructure on the local kind cluster. They are an
alternative to Terraform and Crossplane: plan, apply, wait-for-ready, drift and destroy
are steps of one playbook, and the cluster itself holds the state.

| Playbook | Stack | Spec |
|---|---|---|
| `log_analytics.yaml` | ClickHouse (community) + Vector + ClickHouse MCP, namespace `log-analytics` | [docs/specs/noetl-iac-log-analytics.md](../../../docs/specs/noetl-iac-log-analytics.md) |

```bash
# from the ops repo root, noetl CLI >= 5.4.0
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=plan    --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=apply   --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=verify  --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=drift   --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=status  --json | jq -r .final_result
noetl run automation/iap/kind/log_analytics.yaml -r local --set action=destroy --set confirm=log-analytics --json | jq -r .final_result
```

`noetl iap apply automation/iap/kind/log_analytics.yaml --auto-approve --var action=<action>` is
equivalent. The cluster is the state store here (labels, managedFields, namespace annotations),
not `.noetl/state.duckdb`.

Guard rails:
- Only `kind-*` contexts are allowed.
- Plan, apply and verify refuse to run while the host 1-minute load is above `max_load` (6).
- Destroy needs `confirm=<namespace>`.
- Every run writes `.noetl/log-analytics/latest.log`.

The GCP counterpart (GKE, Artifact Registry, state bucket) is in [`../gcp/`](../gcp/README.md).
