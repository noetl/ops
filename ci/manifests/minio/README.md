# MinIO dev broker (S3 spool backend)

S3-compatible object store for live-validating the NoETL subscription
spool **`s3` backend** (noetl/ai-meta#94) and the **cross-restart drain**
proof (noetl/ai-meta#93) on the local kind cluster.

## Apply

```bash
kubectl --context kind-noetl apply -f ci/manifests/minio/namespace.yaml
kubectl --context kind-noetl apply -f ci/manifests/minio/deployment.yaml
kubectl --context kind-noetl -n minio rollout status deploy/minio
kubectl --context kind-noetl -n minio wait --for=condition=complete job/minio-make-bucket --timeout=120s
```

## Reach it

- In-cluster S3 endpoint: `http://minio.minio.svc.cluster.local:9000`
- Bucket: `noetl-spool`
- Dev creds (throwaway): `minioadmin` / `minioadmin`, region `us-east-1`
- Console: `kubectl -n minio port-forward svc/minio 9001:9001` → http://localhost:9001

## Keychain credential for the spool

The worker resolves `spool.credential` from the NoETL keychain. Register an
`aws`-typed alias whose `data` carries the endpoint + keys:

```bash
curl -sf -X POST "$NOETL/api/credentials" -H 'content-type: application/json' -d '{
  "name": "s3_spool_minio",
  "type": "aws",
  "data": {
    "access_key_id": "minioadmin",
    "secret_access_key": "minioadmin",
    "region": "us-east-1",
    "endpoint": "http://minio.minio.svc.cluster.local:9000"
  }
}'
```

A subscription then declares:

```yaml
spool:
  mode: buffer_and_ack
  backend: s3
  bucket: noetl-spool
  credential: s3_spool_minio
  ordering: global
```

## Backend unit round-trip (no worker needed)

The `s3` backend's put/list/get/delete can be proven directly against a
port-forwarded MinIO:

```bash
kubectl --context kind-noetl -n minio port-forward svc/minio 9000:9000 &
NOETL_S3_TEST_BUCKET=noetl-spool \
NOETL_S3_ENDPOINT=http://localhost:9000 \
NOETL_S3_ACCESS_KEY=minioadmin \
NOETL_S3_SECRET_KEY=minioadmin \
  cargo test -p noetl-tools --features s3 s3_live -- --ignored --nocapture
```
