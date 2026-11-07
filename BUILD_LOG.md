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
