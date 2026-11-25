# ADR-0004: ClickHouse is a business-data store, never a NoETL core component

- **Date:** 2026-11-07
- **Status:** Accepted. Implemented.

## Decision

ClickHouse community edition is a **business-data analytical store**. It holds business and
application data: qnetmon network logs first, and other business-task outputs later.

NoETL **provisions and feeds** it as an example workload: the IaC showcase (ADR-0001) and a
log sink. NoETL core never depends on it and never stores its own operational state there.
It is optional and cleanly removable.

## What enforces it

- `automation/setup/bootstrap.yaml` has `deploy_clickhouse: false` by default. Until
  2026-11-07 the core bootstrap deployed the legacy ClickHouse stack unconditionally; it now
  sits behind a `when:` arc.
- The log-analytics stack lives in its own namespace, owned by its own IaC state (stack
  `log-analytics`). `action=destroy` removes it completely, leaving no labelled object or PV.
- IaC state is in the provider-fact log and EHDB (ADR-0002), never in ClickHouse.
- Every producer degrades on its own:
  - The qnetmon shipper skips shipping when ClickHouse doesn't answer `/ping` (`ship: auto`),
    and its rotation keeps running.
  - Vector buffers to disk.

## Rationale

The NoETL core (server, workers, EHDB, catalog) must run with a minimal footprint. An
analytical database is a business choice per tenant and use case, not a platform
requirement.

## Alternatives considered

- **ClickHouse as the platform observability store.** This was the implicit position of the
  legacy `observability` schema in `ci/manifests/clickhouse/`. Rejected: core operational
  events already have a durable, replayable home in EHDB (ADR-0005).
