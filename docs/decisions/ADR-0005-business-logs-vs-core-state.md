# ADR-0005: Business logs go to ClickHouse; core events and state stay in EHDB

- **Date:** 2026-11-07
- **Status:** Accepted. Implemented.

## Decision

- **Business and network logs** go into ClickHouse `logs.events`:
  - qnetmon's edge daemon event log and stderr (`source = 'qnetmon'`);
  - business workloads' pod logs (`source = 'k8s'`).
- **NoETL core operational events and state** (executions, commands, facts, catalog) stay
  in **EHDB**: the event log, KV and projections.

## What enforces it

- Vector ships pod logs only from namespaces that opt in with the label
  `noetl.io/log-analytics=capture` (`extra_namespace_label_selector` in
  `ci/manifests/log-analytics/20-vector.yaml`).
- NoETL core namespaces (`noetl`, `postgres`, `kube-system`, …) are never labelled. Only the
  business stack's own namespace is labelled, in `00-namespace.yaml`.
- The qnetmon shipper (`playbooks/housekeeping/logs.yaml`) ships only qnetmon's own files.

## Rationale

- Keep the boundary crisp:
  - EHDB is the authoritative, replayable record of what the platform did.
  - ClickHouse is where a business analyses its own data.
- Mixing them would make core look like it depends on an optional store. It would also
  duplicate core events outside the secret-free projection guarantees.

## Alternatives considered

- **Ship every pod log** (round 1 of the Vector config). Rejected: it routed core logs into a
  business store.
- **Exclude core namespaces by list** (deny-list). Rejected in favour of opt-in: a new core
  namespace would leak by default.
