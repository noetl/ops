#!/usr/bin/env bash
# Apply the durable KIND-DEV GCP metadata bridge (noetl/ai-meta#151 wkstream B).
# Idempotent.  DO NOT run against GKE / prod.
#
#   1. Verify the host ADC-token shim is listening on :48710 (see README.md
#      for the launchd install that makes it restart-safe).
#   2. Apply the in-cluster relay (Deployment + fixed-clusterIP Service).
#   3. Patch hostAliases (metadata.google.internal -> the relay's fixed
#      clusterIP) onto every worker pool, and point the server's GSM env at
#      the host shim.  Both survive pod restarts because they live in the
#      deployment spec + a stable Service IP.
set -euo pipefail

CTX="${KIND_CONTEXT:-kind-noetl}"
NS="${NOETL_NAMESPACE:-noetl}"
BRIDGE_IP="10.96.0.53"
SHIM_PORT="48710"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GCP_PROJECT="${GOOGLE_CLOUD_PROJECT:-noetl-demo-19700101}"

echo "=== [1/4] host ADC-token shim on :${SHIM_PORT} ==="
if curl -s -m 5 -o /dev/null -w '%{http_code}' "http://localhost:${SHIM_PORT}/token" | grep -q 200; then
  echo "  ok — shim responding 200"
else
  echo "  ERROR: shim not reachable on localhost:${SHIM_PORT}."
  echo "  Start it (see README.md):"
  echo "    python3 ${HERE}/gcp-token-shim.py &"
  echo "  or install the launchd unit for restart-safety."
  exit 1
fi

echo "=== [2/4] in-cluster relay (fixed clusterIP ${BRIDGE_IP}) ==="
# clusterIP is immutable — if an old relay Service exists on a different IP,
# recreate it so the pinned IP takes effect.
CUR_IP="$(kubectl --context "$CTX" -n "$NS" get svc gcp-metadata -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [ -n "$CUR_IP" ] && [ "$CUR_IP" != "$BRIDGE_IP" ]; then
  echo "  existing Service on $CUR_IP != $BRIDGE_IP — deleting to re-pin"
  kubectl --context "$CTX" -n "$NS" delete svc gcp-metadata --ignore-not-found
fi
kubectl --context "$CTX" apply -f "${HERE}/gcp-metadata-bridge.yaml"
kubectl --context "$CTX" -n "$NS" rollout status deploy/gcp-metadata-bridge --timeout=120s

echo "=== [3/4] worker hostAliases -> ${BRIDGE_IP} ==="
for d in noetl-worker-rust noetl-worker-system-pool noetl-worker-rust-subscription-pool noetl-subscription-runtime; do
  if kubectl --context "$CTX" -n "$NS" get deploy "$d" >/dev/null 2>&1; then
    kubectl --context "$CTX" -n "$NS" patch deploy "$d" --type merge -p \
      "{\"spec\":{\"template\":{\"spec\":{\"hostAliases\":[{\"ip\":\"${BRIDGE_IP}\",\"hostnames\":[\"metadata.google.internal\"]}]}}}}"
    echo "  patched $d"
  fi
done

echo "=== [4/4] server GSM env -> host shim ==="
kubectl --context "$CTX" -n "$NS" set env deploy/noetl-server-rust \
  "NOETL_GCP_METADATA_TOKEN_URL=http://host.containers.internal:${SHIM_PORT}/token" \
  "GOOGLE_CLOUD_PROJECT=${GCP_PROJECT}" \
  "GCP_PROJECT=${GCP_PROJECT}"

echo "=== DONE — bridge applied.  Verify a worker pod resolves GSM:"
echo "  kubectl --context $CTX -n $NS exec deploy/noetl-worker-rust -- \\"
echo "    sh -c 'wget -qO- http://metadata.google.internal/token | head -c 40'"
