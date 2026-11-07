# log-analytics manifests (desired state)

These files are the desired state of the kind log-analytics stack. They are applied **only**
by `automation/iap/kind/log_analytics.yaml`, which uses server-side apply with field manager
`noetl-iac` and applies them in dependency order with readiness gates. Don't
`kubectl apply -f .` by hand: the playbook also generates the credentials Secret, converges
the schema and records the applied state.

| File | Contents |
|---|---|
| `00-namespace.yaml` | namespace `log-analytics` (carries the applied-state annotations) |
| `10-clickhouse.yaml` | ClickHouse 26.8 LTS StatefulSet + PVC, headless + NodePort 30123 Services, config (logging, system-log TTLs, users) |
| `20-vector.yaml` | Vector DaemonSet + RBAC: pod logs → `logs.events` |
| `30-mcp.yaml` | ClickHouse MCP server (streamable HTTP, bearer auth, read-only user), NodePort 30124 |
| `schema/logs.sql` | idempotent DDL: `logs.events`, `logs.events_per_minute` + MV |

Every object must carry `noetl.io/stack: log-analytics` and
`app.kubernetes.io/managed-by: noetl`, and pod templates too. Drift and destroy select on
these labels. `python3 ci/checks/validate.py` (check `iap-labels`) fails a PR that adds an
unlabelled object.

Spec: [docs/specs/noetl-iac-log-analytics.md](../../../docs/specs/noetl-iac-log-analytics.md).
