# ADR-0001: NoETL playbooks provision infrastructure in place of Terraform/Crossplane

- **Date:** 2026-11-07
- **Status:** Accepted. Implemented for local kind: `automation/iap/kind/log_analytics.yaml`.

## Decision

Infrastructure is provisioned by NoETL playbooks: on local kind for the demo, and as the
pattern elsewhere. One playbook owns the whole lifecycle of a stack. Its `action` selects one of:

| action | what it does |
|---|---|
| `plan` | the state-aware diff |
| `apply` | server-side apply in dependency order, hard readiness gates, data-plane convergence, state written, outputs published |
| `verify` | end-to-end data-path proof |
| `drift` | compare declared, state and live |
| `state` | list what the state owns |
| `destroy` | confirm-gated, driven by state |

No Terraform state, no Crossplane controller, no hand-run helm.

## Rationale

- NoETL already has the primitives. `kind: shell` and `kind: http` are in the local
  runtime (CLI 5.4.0 supports `shell, http, playbook, duckdb, auth, sink`). `kind: provider`
  is the typed cloud provider tool in `noetl-tools` `src/tools/provider.rs`, with plan/apply,
  `report | enforce | adopt` reconcile and confirm-gated destroy/adopt. `noetl provider`
  (`cli/src/provider_cli.rs`) exposes it Terraform-style: plan / drift / orphans / adopt.
  The kind stack applies the same contract to Kubernetes.
- One runtime runs the whole thing: provisioning, data-plane setup (the ClickHouse schema),
  verification and the workloads that use the stack (the qnetmon shipper). It uses one
  credential model (`noetl credential` aliases) and one state model (ADR-0002).
- The DAG is the dependency graph, readable in one file. Each readiness wait is a hard gate
  with no `|| true`. That replaces the legacy `automation/infrastructure/clickhouse.yaml`,
  whose waits ended in `|| true`.

## Alternatives considered

- **Terraform `kubernetes`/`helm` providers.** Adds a second state system outside NoETL, plus
  a lock/backend to operate. Data-plane setup would need a separate provider or `local-exec`.
- **Crossplane.** Needs a resident controller and provider pods in the cluster, which is more
  moving parts than the stack itself on a laptop kind. It has no plan step.
- **Helm alone.** Has release state, but no drift detection, no data-plane convergence and no
  verification.

## Consequences

- Round 1 runs `kubectl --server-side` from `shell` steps. A typed `provider: kubernetes` family
  is the follow-up that makes the steps declarative and kubectl-free (spec §9). Each playbook
  step was cut to map onto one provider action.
