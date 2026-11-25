# log-analytics manifests (desired state)

These files are the desired state of the kind log-analytics stack. It is a **business-data**
store: business and network logs such as qnetmon's. It is not a NoETL core component
(ADR-0004). They are applied **only**
by `automation/iap/kind/log_analytics.yaml`, which uses server-side apply with field manager
`noetl-iac` and applies them in dependency order with readiness gates. Don't
`kubectl apply -f .` by hand: the playbook also generates the credentials Secret, converges
the schema and records state, one `provider_fact` per resource (ADR-0002).

| File | Contents |
|---|---|
| `00-namespace.yaml` | namespace `log-analytics`, opted in to business-log capture (`noetl.io/log-analytics=capture`) |
| `10-clickhouse.yaml` | ClickHouse 26.8 LTS StatefulSet + PVC, headless + NodePort 30123 Services, config (logging, system-log TTLs, users) |
| `20-vector.yaml` | Vector DaemonSet + RBAC: pod logs → `logs.events`, only from namespaces labelled `noetl.io/log-analytics=capture` (core namespaces never are, ADR-0005) |
| `30-mcp.yaml` | ClickHouse MCP server (streamable HTTP, bearer auth, read-only user), NodePort 30124 |
| `schema/logs.sql` | idempotent DDL: `logs.events`, `logs.events_per_minute` + MV |

Every object must carry `noetl.io/stack: log-analytics` and
`app.kubernetes.io/managed-by: noetl`, and pod templates too. The IaC state (the fact log)
says what the stack owns. The labels are the cross-check: drift reports a labelled object the
state doesn't own as *untracked*, and destroy refuses to finish while one remains. `python3 ci/checks/validate.py` (check `iap-labels`) fails a PR that adds an
unlabelled object.

Spec: [docs/specs/noetl-iac-log-analytics.md](../../../docs/specs/noetl-iac-log-analytics.md).
