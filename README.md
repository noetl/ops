# NoETL Ops Repository

This repository is the operational control-plane for NoETL environments.
It contains copied `ci/` manifests and `automation/` playbooks so you can run local Kind and GKE workflows from one place.

## Prerequisite

Use `noetl` CLI `>= 2.8.7` (older binaries may not support current playbook routing syntax).

## Run location

Run commands from this repo root:

```bash
cd /Volumes/X10/projects/noetl/ops
```

## Supported source layouts

### 1) Ops submodules (default)

This repo now tracks release/dependency repos as submodules:

- `vendor/cli`
- `vendor/homebrew-tap`
- `vendor/apt`

Initialize/update:

```bash
git submodule sync --recursive
git submodule update --init --recursive
```

### 2) External sibling repos (optional override)

You can still override playbook inputs with explicit paths (`--set cli_repo_dir=...`, etc.) when needed.

## One-time compatibility links

Some legacy playbooks still expect `docker/`, `tests/`, and `crates/` paths.
Create compatibility symlinks:

```bash
noetl run automation/setup/prepare_workspace_links.yaml --runtime local --set action=create
```

Verify:

```bash
noetl run automation/setup/prepare_workspace_links.yaml --runtime local --set action=check
```

## Local Kind workflow

1. Create cluster:

```bash
noetl run automation/infrastructure/kind.yaml --runtime local --set action=create
```

2. Build NoETL image (from sibling repo):

```bash
noetl run automation/development/docker.yaml --runtime local --set action=build --set noetl_repo_dir=../noetl
```

3. Deploy/redeploy NoETL:

```bash
noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl
```

4. Build/deploy gateway (optional):

```bash
noetl run automation/infrastructure/gateway.yaml --runtime local --set action=deploy-all --set gateway_repo_dir=../gateway
```

## GKE workflow

Use `automation/gcp_gke/noetl_gke_fresh_stack.yaml` from this repo.
The playbook now supports split-repo source directories:

- `ops_repo_dir` (default `.`)
- `noetl_repo_dir` (default `../noetl`)
- `gateway_repo_dir` (default `../gateway`)
- `gui_repo_dir` (default `../gui`)
- `auth_playbooks_dir` (default `../noetl/tests/fixtures/playbooks/api_integration/auth0`)

Example deploy:

```bash
noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml \
  --runtime local \
  --set action=deploy \
  --set project_id=noetl-demo-19700101 \
  --set region=us-central1 \
  --set cluster_name=noetl-cluster \
  --set build_images=false \
  --set noetl_image_repository=ghcr.io/noetl/noetl \
  --set noetl_image_tag=v2.8.9 \
  --set deploy_ingress=false \
  --set gateway_service_type=LoadBalancer \
  --set gateway_load_balancer_ip=34.46.180.136 \
  --set gui_service_type=LoadBalancer \
  --set gui_load_balancer_ip=35.226.162.30 \
  --set pgbouncer_default_pool_size=4 \
  --set pgbouncer_min_pool_size=1 \
  --set pgbouncer_reserve_pool_size=1 \
  --set pgbouncer_max_db_connections=8 \
  --set pgbouncer_server_idle_timeout=120
```

## Post-deploy checks

```bash
kubectl get svc -n gateway gateway
kubectl get svc -n gui gui
curl -i https://gateway.mestumre.dev/health
curl -i https://mestumre.dev/
```

## Distribution publishing (CLI/Homebrew/APT)

Run release publishing from this repo using submodule defaults:

```bash
noetl run automation/release/publish_distribution_repos.yaml --runtime local \
  --set action=publish \
  --set version=2.8.7
```

By default this uses:

- `cli_repo_dir=./vendor/cli`
- `homebrew_repo=./vendor/homebrew-tap`
- `apt_repo=./vendor/apt`
- `artifacts_dir=./build/release`
