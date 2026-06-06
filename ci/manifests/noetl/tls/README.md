# mTLS for the Rust noetl stack (kind)

Secrets Wallet **Phase 4c** ([noetl/ai-meta#61](https://github.com/noetl/ai-meta/issues/61)).
Brings the Rust `noetl-server-rust` + `noetl-worker-rust` up with mutual TLS on
the control-plane API — the transport that authenticates + encrypts the
worker→server credential channel (`GET /api/credentials/<alias>`) so a resolved
secret no longer travels plaintext on the wire.

The certs are issued **in-cluster by cert-manager** — no manual `openssl` or
`kubectl create secret`, nothing secret in git.

- Server listener: Phase 4a, [noetl/server#103](https://github.com/noetl/server/pull/103) (v2.30.0) — `NOETL_TLS_CERT` / `NOETL_TLS_KEY` / `NOETL_TLS_CLIENT_CA`.
- Worker client: Phase 4b, [noetl/worker#56](https://github.com/noetl/worker/pull/56) (v5.12.0) — `NOETL_TLS_CLIENT_CERT` / `NOETL_TLS_CLIENT_KEY` / `NOETL_TLS_CA`.

## Files

| File | What |
| :-- | :-- |
| `certificates.yaml` | cert-manager chain: self-signed Issuer → CA `Certificate` → CA Issuer → `noetl-server-tls` (serverAuth, SAN = service DNS) + `noetl-worker-tls` (clientAuth) leaf certs. cert-manager materializes the two Secrets (keys `tls.crt` / `tls.key` / `ca.crt`). |
| `server-rust-mtls-patch.yaml` | Strategic-merge patch: mounts `noetl-server-tls`, sets the `NOETL_TLS_*` env + `https` public URL, swaps probes to `tcpSocket` (an httpGet/HTTPS probe can't present a client cert, so mTLS fails it). |
| `worker-rust-mtls-patch.yaml` | Strategic-merge patch: mounts `noetl-worker-tls`, sets the `NOETL_TLS_CLIENT_*` env + `https` `NOETL_SERVER_URL`, rewrites the `wait-for-api` init container to curl the server's mTLS endpoint **with** the client cert. |

## Enable

```bash
# 1. cert-manager (once per cluster)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s

# 2. issue the certs (cert-manager creates noetl-server-tls + noetl-worker-tls)
kubectl apply -f ci/manifests/noetl/tls/certificates.yaml
kubectl -n noetl wait --for=condition=Ready certificate/noetl-server-tls certificate/noetl-worker-tls --timeout=120s

# 3. flip the rust deployments to mTLS
kubectl -n noetl patch deploy noetl-server-rust --type strategic \
  --patch-file ci/manifests/noetl/tls/server-rust-mtls-patch.yaml
kubectl -n noetl patch deploy noetl-worker-rust --type strategic \
  --patch-file ci/manifests/noetl/tls/worker-rust-mtls-patch.yaml
kubectl -n noetl rollout status deploy/noetl-server-rust deploy/noetl-worker-rust
```

## Verify

```bash
# server is in mTLS mode
kubectl -n noetl logs deploy/noetl-server-rust | grep 'Server listening'
#   → Server listening (TLS) ... tls=true mtls=true

# worker presents its client cert + registers
kubectl -n noetl logs deploy/noetl-worker-rust -c worker | grep -E 'TLS enabled|Worker registered'
#   → control-plane HTTP client: TLS enabled mtls=true ca=true
#   → Worker registered pool_name=worker-rust-pool

# a playbook runs end-to-end over mTLS (port-forward, use the issued certs)
kubectl -n noetl get secret noetl-worker-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/c.crt
kubectl -n noetl get secret noetl-worker-tls -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/c.key
kubectl -n noetl get secret noetl-worker-tls -o jsonpath='{.data.ca\.crt}'  | base64 -d > /tmp/ca.crt
kubectl -n noetl port-forward deploy/noetl-server-rust 18082:8082 &
curl -sS --cacert /tmp/ca.crt --cert /tmp/c.crt --key /tmp/c.key \
  -X POST https://localhost:18082/api/execute -H 'content-type: application/json' \
  -d '{"path":"fixtures/playbooks/hello_world","version":"11"}'
```

## Revert to plain HTTP

```bash
kubectl -n noetl set env deploy/noetl-server-rust NOETL_TLS_CERT- NOETL_TLS_KEY- NOETL_TLS_CLIENT_CA- \
  NOETL_PUBLIC_SERVER_URL=http://noetl-server-rust.noetl.svc.cluster.local:8082
kubectl -n noetl set env deploy/noetl-worker-rust NOETL_TLS_CLIENT_CERT- NOETL_TLS_CLIENT_KEY- NOETL_TLS_CA- \
  NOETL_SERVER_URL=http://noetl.noetl.svc.cluster.local:8082
```

## Notes

- **Opt-in today.** These patches are applied on top of the base
  `server-rust-deployment.yaml` / `worker-rust-deployment.yaml`. Folding mTLS
  into the Helm chart (`automation/helm/noetl`) as a values-gated default is the
  follow-up that makes it the deployed default for GKE.
- **Probes + mTLS.** A client-cert-requiring listener rejects the K8s probe's
  certless handshake, so the server uses a `tcpSocket` probe and the worker's
  init container curls with the client cert. A separate non-mTLS health port is
  the production-grade alternative.
- **GKE.** Prefer the cert-manager Kubernetes/GCP issuers (or SPIFFE/SPIRE) over
  the self-signed root here; this self-signed chain is for kind / non-prod.
