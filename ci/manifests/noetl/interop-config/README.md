# Interop wiring for prod: trust, callbacks, opt-in, gateway MCP

**Status: staged, NOT applied.** Since 2026-11-10 prod runs server v3.156.0 with
`NOETL_MCP_SERVER`, `NOETL_AGENT_ENDPOINT` and `NOETL_INSTANCE_REGISTRY` on, and gateway v3.21.0
with `GATEWAY_MCP_PROXY` off. All three features are live but inert:

| feature | why it does nothing yet | the switch below |
|---|---|---|
| `/api/mcp` (item 5) | no playbook declares `metadata.expose.mcp` | **C** opt-in playbooks |
| `/api/agents` (item 7) | no playbook declares `expose.agent`, and `NOETL_AGENT_CALLBACK_ORIGINS` is unset, so every `callback_url` is refused | **B** callback origins, **C** |
| `/api/instances` (item 9) | `NOETL_INSTANCE_TRUSTED_IDS` is empty, so every identity gets 403 | **A** trust allowlist |
| gateway `/noetl/mcp` | `GATEWAY_MCP_PROXY` unset (admins only, through the generic proxy) | **D** |

Each switch is independent. Every server env change is one restart of the single replica.
Run the smokes after each one: `ci/prod-smoke/server_smoke.sh` (through a port-forward to
`svc/noetl-server-rust` on 18082) and `ci/prod-smoke/gateway_smoke.sh`. Kind coverage is
named per switch.

## A. Trust allowlist: let named instances register

Each instance proves its identity with an ML-DSA-87 key. Its id is `ni-` + 32 hex characters,
derived from the public key, so the id needs no secret handling.

```bash
# on the instance (laptop, edge box, another cluster):
noetl instance init            # once; key in ~/.noetl/instance/key.json (0600)
noetl instance id              # prints ni-…
# on prod (comma-separated; this REPLACES the list, so include the existing ids):
kubectl --context noetl-prod -n noetl set env sts/noetl-server-rust-embedded NOETL_INSTANCE_TRUSTED_IDS=ni-aaa…,ni-bbb…
kubectl --context noetl-prod -n noetl rollout status sts/noetl-server-rust-embedded --timeout=600s
# check from the instance:
noetl instance register --once --server <url> --runtime-kind daemon --site <site>
# rollback:
kubectl --context noetl-prod -n noetl set env sts/noetl-server-rust-embedded NOETL_INSTANCE_TRUSTED_IDS-
```

Kind: `ehgraph-topology/kind_validate.sh` step 3 checks that an allowlisted id registers, a
stranger gets 403, and the node lands in the graph. The enrollment-token slice (noetl/server,
`NOETL_INSTANCE_TRUST=enroll`) replaces hand-edited lists once it ships.

Reachability: `/api/instances/*` is on the server Service only. An instance outside the cluster
needs the gateway route (noetl/gateway, `GATEWAY_INSTANCE_PROXY`, a separate slice) or a
port-forward.

## B. Agent callback origins

```bash
kubectl --context noetl-prod -n noetl set env sts/noetl-server-rust-embedded \
  NOETL_AGENT_CALLBACK_ORIGINS=https://receiver.example.com,https://other.example.com
# rollback:
kubectl --context noetl-prod -n noetl set env sts/noetl-server-rust-embedded NOETL_AGENT_CALLBACK_ORIGINS-
```

Origins only (`scheme://host[:port]`). Redirects are not followed, and a URL with credentials
is refused. Every origin listed is a destination the server will POST results to, so list only
receivers you control. **Needs a decision: which receivers.** Kind:
`ci/kind/e2e_interop_items.sh` step 4 checks delivery with the per-task bearer, and that a
foreign origin gets 400.

## C. Opt-in playbooks

Nothing is exposed by default. A playbook opts in in its own metadata, and the input schema is
written by hand and is also the argument allowlist (see `example-expose.yaml`). Register it as
usual. The registration is the switch, and deleting or re-registering without `expose` is the
rollback. Kind: `ci/kind/interop/echo.yaml`, exercised by `e2e_interop_items.sh`.
**Needs a decision: which playbooks.** Candidates must be safe to start with only the
arguments the schema names, by anyone the gateway policy lets start them.

## D. Gateway MCP proxy

```bash
kubectl --context noetl-prod -n gateway set env deploy/gateway GATEWAY_MCP_PROXY=true
kubectl --context noetl-prod -n gateway rollout status deploy/gateway --timeout=300s
# rollback:
kubectl --context noetl-prod -n gateway set env deploy/gateway GATEWAY_MCP_PROXY-
```

Regular users then get `tools/list` filtered to the playbooks they may start
(`GATEWAY_USER_PLAYBOOKS` / policy), and every `tools/call` is bound to their identity and
recorded as theirs. Until C exposes something, the list holds only the three helpers.
**Not kind-validated**: the kind cluster runs no gateway. gateway#65's tests cover the route
(the policy filter, helper ownership, fail-closed on an unnamed playbook).
