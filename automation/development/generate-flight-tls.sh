#!/usr/bin/env bash
# Generate a fresh self-signed CA + server cert + client cert + bearer
# token for the Arrow Flight gRPC endpoint, create the corresponding
# k8s Secrets in the `noetl` namespace, and patch the noetl-server +
# noetl-worker-rust deployments to mount the certs + read the auth
# env vars (R-2.3 Phase C2.5 — kind-targeted bootstrap).
#
# Lifecycle:
#
#     ./automation/development/generate-flight-tls.sh        # turn on
#     ./automation/development/generate-flight-tls.sh --off  # turn off
#
# The "on" path is idempotent: re-running rotates the certs + token
# but the deployments stay patched.  The "off" path removes the
# Secrets + reverts the deployments to the no-auth state.
#
# Output lands in the noetl namespace as three Secrets:
#
#     noetl-flight-tls           server cert + key + client CA
#     noetl-flight-bearer        NOETL_FLIGHT_BEARER_TOKENS env var
#     noetl-flight-client        worker client cert + key + server CA
#
# Generated certs / tokens never touch this repo — they're created in
# a private tmpdir, uploaded to k8s, and the tmpdir is wiped on exit.
# See `agents/rules/safety.md` for the public-repo discipline.
#
# Production guidance: replace the openssl-based generator with
# cert-manager.  The Secret shape this script writes is the same
# shape the C2.6 validation rig expects, so the rig works against
# either bootstrap path.

set -euo pipefail

CONTEXT="${KUBE_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_NS:-noetl}"
MODE="${1:-on}"

remove_tls() {
    echo "==> Removing Flight TLS Secrets + reverting deployments"
    kubectl --context "$CONTEXT" -n "$NAMESPACE" delete secret \
        noetl-flight-tls noetl-flight-bearer noetl-flight-client \
        --ignore-not-found
    # Strip the auth env vars + volume mounts via JSON-patch.  When
    # the patch path doesn't exist (deployment never patched) the
    # `--ignore-not-found` style of `kubectl patch` is unsupported,
    # so we tolerate failures (deployment is already clean).
    for dep in noetl-server noetl-worker-rust; do
        kubectl --context "$CONTEXT" -n "$NAMESPACE" patch deployment "$dep" \
            --type=json \
            -p '[
                {"op":"remove","path":"/spec/template/spec/containers/0/envFrom/2"},
                {"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts/2"},
                {"op":"remove","path":"/spec/template/spec/volumes/2"}
            ]' 2>/dev/null || echo "    $dep: already unpatched (ok)"
    done
    echo "==> Done.  Deployments roll automatically on the next image refresh."
    exit 0
}

if [[ "$MODE" == "--off" || "$MODE" == "off" ]]; then
    remove_tls
fi

# ---- "on" path -------------------------------------------------------

WORK=$(mktemp -d -t noetl-flight-tls.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating CA + server + client certs in $WORK"

# Self-signed CA.
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj "/CN=noetl-flight-ca/O=noetl-dev" \
    -keyout "$WORK/ca.key" -out "$WORK/ca.crt" >/dev/null 2>&1

# Server cert — SAN covers the in-cluster DNS + localhost (for the
# kind extraPortMappings).  Issued by the CA above.
cat > "$WORK/server.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
req_extensions = ext
[dn]
CN = noetl.noetl.svc.cluster.local
O = noetl-dev
[ext]
subjectAltName = DNS:noetl.noetl.svc.cluster.local,DNS:localhost
EOF
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$WORK/server.key" -out "$WORK/server.csr" \
    -config "$WORK/server.cnf" >/dev/null 2>&1
openssl x509 -req -in "$WORK/server.csr" \
    -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial \
    -out "$WORK/server.crt" -days 30 \
    -extensions ext -extfile "$WORK/server.cnf" >/dev/null 2>&1

# Client cert — same CA chain.  The CN identifies the worker;
# operators with a stronger identity story (per-worker certs,
# cluster issuer, etc.) replace this in production.
cat > "$WORK/client.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
[dn]
CN = noetl-worker-rust
O = noetl-dev
EOF
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$WORK/client.key" -out "$WORK/client.csr" \
    -config "$WORK/client.cnf" >/dev/null 2>&1
openssl x509 -req -in "$WORK/client.csr" \
    -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial \
    -out "$WORK/client.crt" -days 30 >/dev/null 2>&1

# Random bearer token — 32 bytes base64 (~43 chars).
TOKEN=$(openssl rand -base64 32 | tr -d '\n')

echo "==> Creating k8s Secrets in $NAMESPACE/$CONTEXT"

# Secret 1: server cert + key + client CA (mTLS trust root).
kubectl --context "$CONTEXT" -n "$NAMESPACE" create secret generic noetl-flight-tls \
    --from-file=server.crt="$WORK/server.crt" \
    --from-file=server.key="$WORK/server.key" \
    --from-file=client-ca.crt="$WORK/ca.crt" \
    --dry-run=client -o yaml | kubectl --context "$CONTEXT" -n "$NAMESPACE" apply -f -

# Secret 2: bearer-token env var.
kubectl --context "$CONTEXT" -n "$NAMESPACE" create secret generic noetl-flight-bearer \
    --from-literal=NOETL_FLIGHT_BEARER_TOKENS="$TOKEN" \
    --dry-run=client -o yaml | kubectl --context "$CONTEXT" -n "$NAMESPACE" apply -f -

# Secret 3: worker client cert + key + the server CA so the worker
# trusts the server cert.
kubectl --context "$CONTEXT" -n "$NAMESPACE" create secret generic noetl-flight-client \
    --from-file=client.crt="$WORK/client.crt" \
    --from-file=client.key="$WORK/client.key" \
    --from-file=server-ca.crt="$WORK/ca.crt" \
    --from-literal=NOETL_FLIGHT_BEARER_TOKEN="$TOKEN" \
    --dry-run=client -o yaml | kubectl --context "$CONTEXT" -n "$NAMESPACE" apply -f -

echo "==> Patching deployments to mount the certs + read the env"

# Strategic-merge patch on the server deployment — adds an envFrom
# pointing at the bearer Secret, env entries for the cert paths
# (the configmap doesn't carry them by default), a volumeMount, and
# the corresponding volume.
SERVER_PATCH=$(cat <<'EOF'
spec:
  template:
    spec:
      containers:
        - name: noetl-server
          env:
            - name: NOETL_FLIGHT_TLS_CERT
              value: /etc/noetl/flight/server.crt
            - name: NOETL_FLIGHT_TLS_KEY
              value: /etc/noetl/flight/server.key
            - name: NOETL_FLIGHT_CLIENT_CA
              value: /etc/noetl/flight/client-ca.crt
          envFrom:
            - secretRef:
                name: noetl-flight-bearer
          volumeMounts:
            - name: flight-tls
              mountPath: /etc/noetl/flight
              readOnly: true
      volumes:
        - name: flight-tls
          secret:
            secretName: noetl-flight-tls
EOF
)
kubectl --context "$CONTEXT" -n "$NAMESPACE" patch deployment noetl-server \
    --type=strategic --patch "$SERVER_PATCH"

# Worker patch — the worker's auth knobs flow through the
# `result_fetch` tool config; the deployment only needs to mount the
# client cert + key + server CA + bearer token.  The validation
# playbook (C2.6) references these paths from the playbook config.
WORKER_PATCH=$(cat <<'EOF'
spec:
  template:
    spec:
      containers:
        - name: worker
          envFrom:
            - secretRef:
                name: noetl-flight-client
          volumeMounts:
            - name: flight-client
              mountPath: /etc/noetl/flight
              readOnly: true
      volumes:
        - name: flight-client
          secret:
            secretName: noetl-flight-client
EOF
)
kubectl --context "$CONTEXT" -n "$NAMESPACE" patch deployment noetl-worker-rust \
    --type=strategic --patch "$WORKER_PATCH"

echo "==> Done.  Rolling deployments..."
kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout restart deployment noetl-server noetl-worker-rust
kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout status deployment noetl-server --timeout=120s
kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout status deployment noetl-worker-rust --timeout=120s

echo
echo "Flight TLS+mTLS+bearer auth is now ACTIVE on $NAMESPACE."
echo "Bearer token (in noetl-flight-client Secret + noetl-flight-bearer Secret):"
echo "    $TOKEN"
echo
echo "To roll back: $0 --off"
