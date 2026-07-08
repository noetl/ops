# GCP metadata bridge (KIND-DEV ONLY)

> **Do not apply any of this to GKE or prod.** On GKE the real metadata
> server + Workload Identity mint tokens. This bridge exists only so a
> **local kind** cluster (podman provider) can reach Google Secret
> Manager during full-functionality validation.

kind has no GKE metadata server, so both GSM resolution paths in the
NoETL stack fail out of the box:

| Path | Who | What it needs |
| :-- | :-- | :-- |
| Server keychain `provider: gcp` | `noetl-server` `GcpSecretManager` | mint a token from `NOETL_GCP_METADATA_TOKEN_URL`, then call Secret Manager REST |
| Worker in-python provider MCP | duffel / hotelbeds / google-places / firestore `kind: python` steps | `GET http://metadata.google.internal/.../token` (URL hard-coded) |

The bridge has two halves:

1. **Host ADC-token shim** (`gcp-token-shim.py`) — a tiny HTTP server on
   the host `0.0.0.0:48710` that returns
   `{access_token, expires_in, token_type}` from
   `gcloud auth application-default print-access-token`. The host ADC
   must hold `secretmanager.secretAccessor` on the project. **No token is
   ever logged.**
2. **In-cluster relay** (`gcp-metadata-bridge.yaml`) — an alpine pod
   running `socat` that forwards `:80` to
   `host.containers.internal:48710`, exposed by a Service pinned to the
   fixed clusterIP **10.96.0.53**. Worker pools get a `hostAliases`
   entry `metadata.google.internal -> 10.96.0.53`.

This is the **durable** variant of the Phase-2 session bridge
(noetl/ai-meta#151 workstream B): the pinned Service IP + the
deployment-spec `hostAliases` + the launchd-managed shim all survive
pod, cluster, and host restarts, so GSM keeps resolving without
re-establishing anything by hand.

## One-time host setup (restart-safe shim)

```bash
mkdir -p ~/.noetl
cp gcp-token-shim.py ~/.noetl/gcp-token-shim.py

# Edit the plist: replace REPLACE_WITH_HOME with your $HOME, then:
sed "s#REPLACE_WITH_HOME#$HOME#g" com.noetl.gcp-token-shim.plist \
  > ~/Library/LaunchAgents/com.noetl.gcp-token-shim.plist
launchctl load ~/Library/LaunchAgents/com.noetl.gcp-token-shim.plist

# Verify (200 + a token prefix, never the whole token in scripts):
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:48710/token
```

`KeepAlive` relaunches the shim if it crashes or after a reboot. To run
it ad-hoc instead of via launchd: `python3 ~/.noetl/gcp-token-shim.py &`.

## Apply the in-cluster half

```bash
./apply-bridge.sh          # applies the relay + hostAliases + server env
```

`apply-bridge.sh` is idempotent. If an older relay Service exists on a
different clusterIP it is recreated on the pinned IP (clusterIP is
immutable).

## Pod-restart durability proof

Because `hostAliases` live in each worker deployment's pod template and
the relay Service IP is fixed, a rescheduled worker pod still resolves
GSM:

```bash
# before
kubectl --context kind-noetl -n noetl exec deploy/noetl-worker-rust -- \
  sh -c 'wget -qO- http://metadata.google.internal/token | head -c 20'

kubectl --context kind-noetl -n noetl delete pod -l app=noetl-worker-rust
kubectl --context kind-noetl -n noetl rollout status deploy/noetl-worker-rust

# after reschedule — still resolves (hostAliases inherited from the spec)
kubectl --context kind-noetl -n noetl exec deploy/noetl-worker-rust -- \
  sh -c 'wget -qO- http://metadata.google.internal/token | head -c 20'
```

## Security notes

- No secret value is committed here or logged. The shim mints from the
  developer's own `gcloud` ADC; the relay only forwards bytes.
- The `noetl.io/kind-dev-only: "true"` label on the manifest marks it as
  never-for-prod. The GKE deploy path (Helm chart under `../noetl`) does
  not reference this directory.
