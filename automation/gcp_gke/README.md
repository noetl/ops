# NoETL GCP GKE Fresh Provisioning

This folder contains a **new, isolated** automation flow for provisioning GKE and deploying the full NoETL stack:

- PostgreSQL
- NATS
- ClickHouse (optional)
- NoETL server + workers
- NoETL Gateway
- NoETL GUI

It does **not** modify existing kind-based automation and does not use `ci/` assets.

## Playbook

- `automation/gcp_gke/noetl_gke_fresh_stack.yaml`
- `automation/gcp_gke/gke_cluster_recreate.yaml`

## Assets in this folder

- `automation/gcp_gke/helm/gui/*` - Helm chart for GUI deployment
- `automation/gcp_gke/assets/noetl/cloudbuild.yaml` - NoETL image build config (`docker/noetl/dev/Dockerfile`) for explicit build runs
- `automation/gcp_gke/assets/gui/Dockerfile` - GUI image build (gateway-only)
- `automation/gcp_gke/assets/gui/nginx.conf` - SPA nginx config

## Source repository paths

`noetl_gke_fresh_stack.yaml` supports split-repo paths:

- `ops_repo_dir` (default: `.`)
- `noetl_repo_dir` (default: `../noetl`)
- `gateway_repo_dir` (default: `../gateway`)
- `gui_repo_dir` (default: `../gui`)
- `e2e_repo_dir` (default: `../e2e`)
- `auth_playbooks_dir` (default: `../e2e/fixtures/playbooks/api_integration/auth0`)

If you use submodules, override these with `--set ..._repo_dir=<submodule-path>`.

## Published image defaults

`noetl_gke_fresh_stack.yaml` now deploys using published images by default:

- `build_images=false` (no on-the-fly image build)
- `noetl_image_repository=ghcr.io/noetl/noetl`
- `noetl_image_tag=v2.8.9`
- conservative rollout strategy for NoETL deployments on constrained clusters:
  - `noetl_server_rollout_max_surge=0`
  - `noetl_server_rollout_max_unavailable=1`
  - `noetl_worker_rollout_max_surge=0`
  - `noetl_worker_rollout_max_unavailable=1`

You can still override image repository/tag per deployment with `--set`.

## Quick start

```bash
noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml \
  --runtime local \
  --set action=provision-deploy \
  --set project_id=<gcp-project-id> \
  --set region=us-central1 \
  --set cluster_name=noetl-cluster \
  --set build_images=false \
  --set noetl_image_repository=ghcr.io/noetl/noetl \
  --set noetl_image_tag=v2.8.9 \
  --set gateway_service_type=LoadBalancer \
  --set gateway_load_balancer_ip=34.71.6.63 \
  --set gui_gateway_public_url=https://gateway.example.com \
  --set noetl_public_host=api.example.com \
  --set gateway_public_host=gateway.example.com \
  --set gui_public_host=gui.example.com
```

## Cloud SQL Private IP + Gateway LB + Cloudflare GUI (mestumre.dev)

Use this deploy profile for:
- existing cluster `noetl-cluster`
- Cloud SQL + PgBouncer (no in-cluster PostgreSQL)
- private-only Cloud SQL IP
- static public IP for the gateway only
- GUI hosted outside GKE, for example Cloudflare Pages at `mestumre.dev`

```bash
noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml \
  --runtime local \
  --set action=deploy \
  --set project_id=noetl-demo-19700101 \
  --set cluster_name=noetl-cluster \
  --set build_images=false \
  --set noetl_image_repository=ghcr.io/noetl/noetl \
  --set noetl_image_tag=v2.29.0 \
  --set gateway_image_repository=ghcr.io/noetl/gateway \
  --set gateway_image_tag=v2.10.0 \
  --set use_cloud_sql=true \
  --set cloud_sql_enable_private_ip=true \
  --set cloud_sql_enable_public_ip=false \
  --set pgbouncer_enabled=true \
  --set deploy_postgres=false \
  --set deploy_clickhouse=false \
  --set deploy_ingress=false \
  --set gateway_service_type=LoadBalancer \
  --set gateway_load_balancer_ip=34.46.180.136 \
  --set deploy_gui=false \
  --set gateway_public_host=gateway.mestumre.dev \
  --set gui_public_host=mestumre.dev \
  --set gateway_public_url=https://gateway.mestumre.dev \
  --set gui_gateway_public_url=https://gateway.mestumre.dev \
  --set pgbouncer_default_pool_size=6 \
  --set pgbouncer_min_pool_size=1 \
  --set pgbouncer_reserve_pool_size=2 \
  --set pgbouncer_max_db_connections=8 \
  --set pgbouncer_server_idle_timeout=300 \
  --set gateway_cors_allowed_domains='mestumre.dev,gateway.mestumre.dev,travel.mestumre.dev'
```

`gateway_cors_allowed_domains` is a single string. Each `--set` invocation
**replaces** the playbook default, so the comma-separated list above must
include every browser-facing host that calls the gateway (here:
`mestumre.dev` for the GUI on Cloudflare Pages, `gateway.mestumre.dev` for
the gateway tunnel itself, and `travel.mestumre.dev` for the travel app).
See the [Multi-domain CORS pitfall](#pitfall-set-on-the-allowed-domains-list-replaces-it-does-not-merge)
section below.

Worker autoscaling is enabled by default for this GKE shape:

- `noetl_worker_autoscaling_min_replicas=2`
- `noetl_worker_autoscaling_max_replicas=4`
- `noetl_worker_autoscaling_target_cpu=70`

The default cap is intentionally conservative for the demo Cloud SQL f1-micro
shape. PFT v2 can generate many frame heartbeats and commits, so allowing the
HPA to scale well beyond the PgBouncer/Cloud SQL backend budget causes pool
timeouts before it improves throughput. Increase the cap only when the database
tier and PgBouncer limits are raised together.

With `deploy_gui=false`, the playbook skips GUI static IP reservation,
skips the in-cluster GUI Helm deployment, and removes any existing
`noetl-gui` release/`gui` namespace. Deploy the GUI separately as a static
site that talks to `https://gateway.mestumre.dev`.

## Gateway Auth Bootstrap

By default the deploy playbook now auto-bootstraps gateway auth dependencies:

- registers credentials: `pg_auth`, `nats_credential`
- registers auth playbooks:
  - `api_integration/auth0/auth0_login`
  - `api_integration/auth0/auth0_validate_session`
  - `api_integration/auth0/check_playbook_access`
  - `api_integration/auth0/provision_auth_schema`
  - `api_integration/auth0/setup_admin_permissions`
- executes `api_integration/auth0/provision_auth_schema`

This is controlled by:

```bash
--set bootstrap_gateway_auth=true
```

Set it to `false` only if you manage auth catalog/credentials separately.

## Managed Google Cloud GKE MCP

The ops catalog includes a remote-managed GKE MCP resource and runtime agent:

- `automation/agents/gcp/runtime.yaml` registers the terminal-visible
  agent playbook at `mcp/gcp/gke`
- `automation/agents/gcp/templates/mcp_gke_managed.yaml` registers the
  `kind: Mcp` resource at `mcp/gcp`

Register them after NoETL is reachable:

```bash
cd repos/ops
noetl catalog register automation/agents/gcp/runtime.yaml
noetl catalog register automation/agents/gcp/templates/mcp_gke_managed.yaml
```

The runtime agent calls Google's managed read-only endpoint,
`https://container.googleapis.com/mcp/read-only`, from the NoETL worker.
On GKE, bind the `noetl/noetl-worker` Kubernetes service account to a
Google service account with:

- `roles/container.viewer` for read-only GKE inventory
- `roles/mcp.toolUser` for `mcp.tools.call` access to the managed MCP endpoint

Restart the worker deployment after adding or changing the IAM roles so
fresh metadata tokens pick up the new permissions. The GUI terminal then exposes:

```text
cd /mcp/gcp
status
tools
call list_clusters --set parent=projects/<project-id>/locations/-
```

Generic MCP tool invocation currently uses the `call` command prefix.
For example, type `call list_clusters ...`, not `list_clusters`.

## Multi-domain CORS

Gateway CORS is now assembled from multiple inputs so it is easier to manage multiple GUI domains:

- `gateway_cors_include_localhost=true` adds `http://localhost:3001`
- `gateway_cors_include_public_hosts=true` adds `https://<gui_public_host>` and `https://<gateway_public_host>`
- `gateway_cors_allowed_origins` accepts comma/space/newline-separated origins or bare domains
- `gateway_cors_allowed_domains` accepts additional bare domains

Every browser app that calls the gateway directly must be included here. Otherwise an identity provider can redirect back to the app, but the browser will block the app from exchanging the identity token with `/api/auth/login`. The browser surfaces this as `NetworkError when attempting to fetch resource` (Firefox) or `Failed to fetch` (Chrome) — the Gateway returns HTTP 200 on the preflight but omits the `access-control-allow-origin` header, so the browser blocks the response.

Example:

```bash
noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml \
  --runtime local \
  --set action=deploy \
  --set project_id=<gcp-project-id> \
  --set build_images=false \
  --set gateway_cors_allowed_domains='app.example.com,staging.example.com' \
  --set gateway_cors_allowed_origins='https://preview.example.com'
```

### Pitfall: `--set` on the allowed-domains list **replaces**, it does not merge

`gateway_cors_allowed_domains` is a single string. Passing
`--set gateway_cors_allowed_domains='new.example.com'` **overwrites** the
playbook default, dropping every domain that was there before (including the
production frontends already in the default like `travel.mestumre.dev`).

Whenever you add a new browser-callable domain to a deployed cluster:

1. Read the current default in
   [`automation/gcp_gke/noetl_gke_fresh_stack.yaml`](noetl_gke_fresh_stack.yaml)
   (`gateway_cors_allowed_domains:` workload variable) and copy every domain
   you want to keep.
2. Append the new domain to that list.
3. Pass the **full** list to `--set gateway_cors_allowed_domains=...`.
4. After the helm upgrade, verify the running deployment with:

   ```bash
   kubectl get deploy -n gateway gateway \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CORS_ALLOWED_ORIGINS")].value}'
   ```

   and confirm every browser-facing host appears as both `https://...` and
   (if applicable) `http://...`.

If a deployment has already shipped a regressed list, the in-cluster hotfix is:

```bash
kubectl set env -n gateway deployment/gateway \
  CORS_ALLOWED_ORIGINS="<full,comma,separated,list>"
kubectl rollout status -n gateway deployment/gateway
```

The hotfix lasts only until the next `helm upgrade`. Always follow it with a
playbook re-deploy that bakes the corrected list into the helm release.

## PostgreSQL Stability (Autopilot)

If you see `CrashLoopBackOff` / `OOMKilled` on `noetl-postgres-postgresql-0`, set explicit PostgreSQL resources:

```bash
noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml \
  --runtime local \
  --set action=deploy \
  --set project_id=<gcp-project-id> \
  --set build_images=false \
  --set postgres_primary_cpu_request=500m \
  --set postgres_primary_cpu_limit=1000m \
  --set postgres_primary_memory_request=512Mi \
  --set postgres_primary_memory_limit=1Gi
```

## TempStore Cache Limits

The playbook exposes TempStore in-memory cache controls and wires them to both
NoETL server and worker pods:

- `noetl_tempstore_max_ref_cache_entries` (default: `50000`)
- `noetl_tempstore_max_memory_cache_entries` (default: `20000`)

Example:

```bash
noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml \
  --runtime local \
  --set action=deploy \
  --set project_id=<gcp-project-id> \
  --set noetl_tempstore_max_ref_cache_entries=50000 \
  --set noetl_tempstore_max_memory_cache_entries=20000
```

## DB Access Notes

- `demo/demo` is intended for `demo_noetl` application schemas (`public`, `auth`).
- NoETL metadata tables (`noetl.catalog`, `noetl.event`, etc.) are in database `noetl`.
- To let `demo` read NoETL metadata, keep `demo_can_read_noetl_schema=true` (default in this playbook).

## Actions

- `provision` - enable APIs, optional Artifact Registry, create GKE cluster
- `deploy` - deploy full stack to existing cluster
- `provision-deploy` - provision cluster then deploy stack
- `status` - show stack status in cluster
- `destroy` - uninstall stack and optionally delete cluster

## Image refresh behavior

- When `build_noetl_image=true`, the deploy playbook now forces `kubectl rollout restart` for:
  - `deployment/noetl-server`
  - `deployment/noetl-worker`
- This guarantees fresh pulls when using mutable tags like `latest`.

## Quota safeguard

Both playbooks run a precheck for `CPUS_ALL_REGIONS` before cluster creation.

- `min_global_cpu_quota` (default `64`) - minimum required global CPU quota
- `enforce_cpu_quota_check` (default `true`) - fail fast if quota is below the minimum

## Cluster-only recreate playbook

Use this when you only want to snapshot/destroy/provision the cluster itself:

```bash
noetl run automation/gcp_gke/gke_cluster_recreate.yaml \
  --runtime local \
  --set action=recreate \
  --set project_id=<gcp-project-id> \
  --set region=us-central1 \
  --set cluster_name=noetl-cluster
```

Supported actions in `gke_cluster_recreate.yaml`:

- `snapshot` - capture current cluster settings and update blueprint file
- `status` - print current cluster summary
- `destroy` - delete cluster (optional pre-snapshot)
- `provision` - create cluster using blueprint/defaults
- `recreate` - snapshot, destroy, then provision
