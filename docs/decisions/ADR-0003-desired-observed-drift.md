# ADR-0003: Desired, observed, and drift

- **Date:** 2026-11-07
- **Status:** Accepted. Implemented in `automation/iap/kind/log_analytics.yaml`.

## Decision

- **Desired state** is the versioned playbook plus the manifests it applies, today in git
  (`ci/manifests/log-analytics/`, `schema/logs.sql`). In Phase 1 they are registered in the
  NoETL **catalog**, which is versioned and event-sourced (`/api/catalog/register`,
  `catalog-log`). Each declared resource gets a URN and a digest:
  - Kubernetes objects: `k8s://<context>/<namespace|_cluster>/<group>/<Kind>/<name>`
  - the ClickHouse schema, as a data-plane resource: `clickhouse://<context>/<ns>/clickhouse-0/schema/logs`
- **Observed state** is the append-only `provider_fact` log (ADR-0002), together with the
  current-state **fold** derived from it. The fold is rebuildable at any time, and has the
  semantics of `noetl-tools` `provider_state::fold_facts`:
  - an applied `ensure` (changed or noop) or `adopt` owns a URN;
  - `delete` (deleted or absent) tombstones it;
  - `planned` is intent only;
  - the fold is scoped to one stack.
- **Drift** compares three things: declared, state and live.

| Drift class | Check |
|---|---|
| unapplied | declared digest ≠ the state's `last_desired.digest` (or not in state) |
| missing | owned in state, absent in the cluster (deleted out of band) |
| fields / conflict | server-side diff as field manager `noetl-iac`; a conflict means another manager took a field |
| untracked | labelled `noetl.io/stack=…` in the cluster but not owned by the state |
| orphan | owned in state, no longer declared (`apply` prunes it when `prune=true`) |

- **Destroy is driven by state.** It deletes exactly what the state owns, in reverse
  dependency order, and appends a `delete` fact per resource. A labelled object the state
  doesn't own makes destroy fail loudly instead of being swept silently.

## Rationale

- Reading state back is what turns `kubectl apply` into IaC. Without a state you can't
  prune a resource removed from config, or find one deleted out of band, or know what
  destroy should remove.
- Using digests of the declared object means state stays small and secret-free. That is the
  same property the `ProviderFact` design requires.

## Alternatives considered

- **Label sweep only** (round 1). It can't tell "deleted from config" from "never existed",
  and can't track non-k8s resources.
- **Storing full objects in state.** That bloats the log and risks secrets. The digest is
  enough, because the desired object is always reproducible from git or the catalog at that
  revision.
