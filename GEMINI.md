# NoETL Ops Project Instructions (Gemini CLI)

## Operational Commands

**Always use the `noetl` binary** for running automation playbooks.

### Infrastructure & Local Kind

```bash
# Create Kind cluster
noetl run automation/infrastructure/kind.yaml --runtime local --set action=create

# Delete Kind cluster
noetl run automation/infrastructure/kind.yaml --runtime local --set action=delete

# Prepare workspace links
noetl run automation/setup/prepare_workspace_links.yaml --runtime local --set action=create
```

### Development & Build

```bash
# Build NoETL Docker image (from sibling repo)
noetl run automation/development/docker.yaml --runtime local --set action=build --set noetl_repo_dir=../noetl

# Deploy/Redeploy NoETL
noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl

# Deploy Gateway
noetl run automation/infrastructure/gateway.yaml --runtime local --set action=deploy-all --set gateway_repo_dir=../gateway
```

### GKE Management

```bash
# Deploy to GKE
noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml 
  --runtime local 
  --set action=deploy 
  --set project_id=<project_id> 
  --set region=<region> 
  --set cluster_name=<cluster_name>
```

### Distribution & Release

```bash
# Publish CLI/Homebrew/APT
noetl run automation/release/publish_distribution_repos.yaml --runtime local 
  --set action=publish 
  --set version=<version>
```

## Project Structure

- `automation/` - Playbook definitions for various workflows
- `ci/` - Kubernetes manifests and CI configurations
- `scripts/` - Operational shell scripts
- `vendor/` - Submodules for CLI, Homebrew-tap, and APT repos
- `README.md` - Operational guide and workflow documentation
