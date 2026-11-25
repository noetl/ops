# ADR-0006: The spec maps NoETL IaC to Terraform and Crossplane explicitly

- **Date:** 2026-11-07
- **Status:** Accepted. The mapping is in [spec §5](../specs/noetl-iac-log-analytics.md#5-terraform--crossplane-mapping).

## Decision

The spec carries a concern-by-concern mapping:
- **Terraform:** a single state file, a remote backend and a lock.
- **Crossplane:** status of custom resources in the control plane, and a resident reconcile
  loop.
- **NoETL:** two-phase self-hosted state (ADR-0002).

The spec also says plainly where Terraform and Crossplane are still stronger.

## The core of the mapping

| | Terraform | Crossplane | NoETL |
|---|---|---|---|
| State | one mutable `tfstate`, overwritten per apply | CR `status` in etcd, overwritten per reconcile | an append-only `provider_fact` log. Current state is a rebuildable fold |
| Backend | external (S3/GCS + DynamoDB, TFC) | the cluster's etcd | Phase 0: local files + object-store copy (CLI). Phase 1: NoETL's own EHDB log + KV + projections + ehgraph |
| Concurrency | a lock file/table; stale locks need force-unlock | the controller is the single writer | append-only, so writers never overwrite each other. Phase 1: EHDB affinity single-writer (`exercise_affinity_single_writer`, `ShardOwnership` in `ehdb-reference`) and KV CAS give a fenced single writer per stack |
| History / audit | none (state versions, if the backend keeps them) | events, short retention | every apply/create/delete is a fact, kept |
| Recovery | restore a state backup; `terraform import` | re-observe | replay the log (Phase 1 projections can be refolded: `/api/ehdb/projection-refold`) |

## Rationale

The replacement argument has to be concrete and honest to be credible. NoETL's
differentiator is the **state model**: there is no single lockable file to corrupt, no
external backend, and history is the state.

## Alternatives considered

- **A feature list without a mapping.** Rejected: it doesn't let an evaluator check the claim.
