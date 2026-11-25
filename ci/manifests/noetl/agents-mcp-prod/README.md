# MCP + agents on prod: enablement record (2026-11-11)

**Status: APPLIED to noetl-prod on 2026-11-11, about 01:13–01:23 UTC.** It went one change at a time, with the smokes in `ci/prod-smoke/` (server health, ranch concierge turn, travel itinerary, gateway guest turn) green before and after every step.

| Step | Change | Restart |
|---|---|---|
| 1 | `deploy/noetl-worker-rust` image → worker **6.12.0** `sha256:ac7cc50f41045df3c46e1b7b9edb5bb096c7653915890c51515253223478dbc6` | rolling, 2 replicas |
| 2 | `deploy/noetl-worker-rust` `NOETL_WORKER_AGENT_TOOL=true` | rolling |
| 3 | `sts/noetl-server-rust-embedded` `NOETL_TOOL_KIND_MCP=true` | one restart (server v3.156.2, image unchanged) |
| 4 | `sts/noetl-server-rust-embedded` `NOETL_TOOL_KIND_AGENT=true` | one restart |

What stayed as found: `noetl-worker-system-pool`, `noetl-worker-system-pool-shard1` and `sts/noetl-cmdbus-writer` remain on worker 6.11.9 `sha256:f866f6140476…`. User tool steps (`kind: mcp` / `kind: agent`) run on `noetl-worker-rust`. The server's tool-kind gates are server-side only; the orchestrate drive opens them by design (orchestrate-core `ToolKindGates::current`).

Validation before prod: `ci/kind/e2e_agents_mcp_runtimes.sh` **32/32** on the real `ghcr.io/noetl/worker:6.12.0-arm64` with `ghcr.io/noetl/server:3.156.2-arm64`.

Prod check (write-free): `noetl.dsl.describe` at `https://noetl.ai/mcp` reports `NOETL_TOOL_KIND_MCP: true, NOETL_TOOL_KIND_AGENT: true` on 3.156.2. `noetl.dsl.validate` of a playbook with a `kind: agent` (`framework: remote`) and a `kind: mcp` step returns `register_verdict: accept`, `execute_verdict: accept` as a dry run. No prod execution was made for the check, because an execution writes to the append-only event log.

## Rollback (each is one restart; run the smokes after)

```bash
K="kubectl --context noetl-prod -n noetl"
# flags, newest first
$K set env sts/noetl-server-rust-embedded NOETL_TOOL_KIND_AGENT-
$K set env sts/noetl-server-rust-embedded NOETL_TOOL_KIND_MCP-
$K set env deploy/noetl-worker-rust NOETL_WORKER_AGENT_TOOL-
# worker image back to 6.11.9
$K set image deploy/noetl-worker-rust noetl-worker=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:f866f6140476c1ab9e17be888a9bbae8bb792ea0cbaa6666c4b89be1560a3081
```

## What a playbook still needs

- Credentials for `kind: mcp` / agent sources come from the keychain (`auth: <alias>` or `{type, credential}`). There is no env fallback.
- Model keys for `framework: claude` come from the keychain as well. `framework: claude-code` is refused on the pool.
- Playbook-bound agent `tools:` are refused on the cluster (build plan item 8).
