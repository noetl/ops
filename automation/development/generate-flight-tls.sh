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

    # Name-based revert: look up the array indices of our additions
    # via jq (rather than hard-coded indices that depend on order),
    # then emit a JSON-patch removing each one.  Indices are computed
    # in **descending order** within each list because each remove
    # shifts subsequent indices down.
    for dep in noetl-server noetl-worker-rust; do
        # Names we added per deployment.
        case "$dep" in
            noetl-server)
                env_names='NOETL_FLIGHT_TLS_CERT NOETL_FLIGHT_TLS_KEY NOETL_FLIGHT_CLIENT_CA'
                envfrom_name='noetl-flight-bearer'
                mount_name='flight-tls'
                volume_name='flight-tls'
                ;;
            noetl-worker-rust)
                env_names=''
                envfrom_name='noetl-flight-client'
                mount_name='flight-client'
                volume_name='flight-client'
                ;;
        esac

        # Pipe the deployment JSON to python so the JSON content
        # itself doesn't get inlined into the heredoc (which is
        # fragile with embedded quotes / multi-line strings).
        # Variables flow via env, not shell substitution.
        OPS=$(kubectl --context "$CONTEXT" -n "$NAMESPACE" \
                get deployment "$dep" -o json 2>/dev/null \
            | EN="$env_names" EF="$envfrom_name" \
              MN="$mount_name" VN="$volume_name" \
              python3 -c '
import json, os, sys
d = json.load(sys.stdin)
spec = d["spec"]["template"]["spec"]
c = spec["containers"][0]
ops = []
env_list = c.get("env", [])
for nm in os.environ.get("EN", "").split():
    for i, e in enumerate(env_list):
        if e.get("name") == nm:
            ops.append((i, f"/spec/template/spec/containers/0/env/{i}"))
            break
for i, e in enumerate(c.get("envFrom", [])):
    if e.get("secretRef", {}).get("name") == os.environ.get("EF"):
        ops.append((i, f"/spec/template/spec/containers/0/envFrom/{i}"))
        break
for i, m in enumerate(c.get("volumeMounts", [])):
    if m.get("name") == os.environ.get("MN"):
        ops.append((i, f"/spec/template/spec/containers/0/volumeMounts/{i}"))
        break
for i, v in enumerate(spec.get("volumes", [])):
    if v.get("name") == os.environ.get("VN"):
        ops.append((i, f"/spec/template/spec/volumes/{i}"))
        break
sorted_ops = sorted(ops, key=lambda x: -x[0])
print(json.dumps([{"op": "remove", "path": p} for _, p in sorted_ops]))
') || {
            echo "    $dep: not present (ok)"
            continue
        }

        if [[ -z "$OPS" || "$OPS" == "[]" ]]; then
            echo "    $dep: already unpatched (ok)"
            continue
        fi
        kubectl --context "$CONTEXT" -n "$NAMESPACE" patch deployment "$dep" \
            --type=json -p "$OPS" >/dev/null
        echo "    $dep: reverted"
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

# JSON-patch (RFC 6902) instead of strategic-merge — strategic-merge
# on `envFrom` and `volumes` without a patchMergeKey REPLACES the
# entire list, which would drop the existing configmap + Secret
# refs the base manifest depends on (`noetl-server-config`,
# `noetl-secret`, `noetl-data` PVC, etc.).  JSON-patch `add` at
# `/-` appends without touching siblings.
SERVER_PATCH='[
  {"op":"add","path":"/spec/template/spec/containers/0/envFrom/-","value":{"secretRef":{"name":"noetl-flight-bearer"}}},
  {"op":"add","path":"/spec/template/spec/containers/0/env","value":[]},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"NOETL_FLIGHT_TLS_CERT","value":"/etc/noetl/flight/server.crt"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"NOETL_FLIGHT_TLS_KEY","value":"/etc/noetl/flight/server.key"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"NOETL_FLIGHT_CLIENT_CA","value":"/etc/noetl/flight/client-ca.crt"}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"flight-tls","mountPath":"/etc/noetl/flight","readOnly":true}},
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"flight-tls","secret":{"secretName":"noetl-flight-tls"}}}
]'
# Some deployments may already have `env: []` set; if the second
# JSON-patch op fails because the key already exists, fall back to
# appending without the create-array op.  We try both orderings.
if ! kubectl --context "$CONTEXT" -n "$NAMESPACE" patch deployment noetl-server \
        --type=json -p "$SERVER_PATCH" 2>/dev/null; then
    # Fallback: env array already exists; skip the create-array op.
    SERVER_PATCH_FALLBACK='[
      {"op":"add","path":"/spec/template/spec/containers/0/envFrom/-","value":{"secretRef":{"name":"noetl-flight-bearer"}}},
      {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"NOETL_FLIGHT_TLS_CERT","value":"/etc/noetl/flight/server.crt"}},
      {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"NOETL_FLIGHT_TLS_KEY","value":"/etc/noetl/flight/server.key"}},
      {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"NOETL_FLIGHT_CLIENT_CA","value":"/etc/noetl/flight/client-ca.crt"}},
      {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"flight-tls","mountPath":"/etc/noetl/flight","readOnly":true}},
      {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"flight-tls","secret":{"secretName":"noetl-flight-tls"}}}
    ]'
    kubectl --context "$CONTEXT" -n "$NAMESPACE" patch deployment noetl-server \
        --type=json -p "$SERVER_PATCH_FALLBACK"
fi

# Worker patch — strategic-merge.  The worker's `envFrom` is
# empty in the base manifest (no configmap to preserve), so
# strategic-merge replacement is safe — unlike the noetl-server
# case where the base envFrom carries `noetl-server-config` +
# `noetl-secret` that we MUST keep.  Volumes + volumeMounts merge
# by name on strategic-merge so the existing entries stay.
#
# Strategic-merge is used here instead of JSON-patch because the
# kind cluster's admission stack (KEDA + others) intermittently
# rejects JSON-patch on the worker-rust deployment with a generic
# 422.  Strategic-merge passes the same validation cleanly.
#
# `NOETL_KEYCHAIN_ENV_VARS` (noetl/worker#35) tells the worker's
# `CommandExecutor::new` to lift the named env vars into the
# per-executor keychain map, so playbook fields like
# `result_fetch.bearer_token: NOETL_FLIGHT_BEARER_TOKEN` resolve
# via `ctx.get_secret(alias)` against the envFrom-mounted Secret
# value.  Without this, the playbook would see the literal alias
# string instead of the token — that's the gap the rig's previous
# sed workaround papered over.
WORKER_PATCH=$(cat <<'EOF'
spec:
  template:
    spec:
      containers:
        - name: worker
          env:
            - name: NOETL_KEYCHAIN_ENV_VARS
              value: NOETL_FLIGHT_BEARER_TOKEN
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
