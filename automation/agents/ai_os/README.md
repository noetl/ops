# AI-OS lifecycle agent

NoETL playbooks that deploy + manage the AI infrastructure for the
NoETL-as-AI-OS spike — Ollama backend + ollama-bridge sidecar +
catalog hooks.

**Disabled by default.** A noetl deployment without these playbooks
running keeps working unchanged (the optional-dependency contract).
Operators run `lifecycle/deploy` to opt the cluster into AI features.

## Layout

```
automation/agents/ai_os/
  README.md                  # this file
  runtime.yaml               # terminal wrapper (`ai-os deploy|undeploy|status`)
  lifecycle/
    deploy.yaml              # bring up Ollama + bridge sidecar
    undeploy.yaml            # tear down (preserves PVC by default)
    status.yaml              # read-only state report
```

## Workflow

```
$ noetl run automation/agents/ai_os/lifecycle/deploy --runtime distributed --json

  apply_ollama_manifests    → kubectl apply (Deployment + Service + PVC)
        │
        ▼
  wait_ollama_ready         → kubectl wait --for=condition=ready
        │
        ▼
  pull_model                → ollama pull gemma2:2b (skip if present)
        │
        ▼
  enable_bridge             → helm upgrade --set ollamaBridge.enabled=true
        │
        ▼
  wait_bridge_ready         → kubectl wait for ollama-bridge pod
        │
        ▼
  verify_reachability       → bridge /jsonrpc tools/list smoke
        │
        ▼
  end
```

## Once-time registration

```bash
noetl catalog register repos/ops/automation/agents/ai_os/lifecycle/deploy.yaml
noetl catalog register repos/ops/automation/agents/ai_os/lifecycle/undeploy.yaml
noetl catalog register repos/ops/automation/agents/ai_os/lifecycle/status.yaml
noetl catalog register repos/ops/automation/agents/ai_os/runtime.yaml
```

## Bring up the AI subsystem

```bash
# Deploy
noetl run automation/agents/ai_os/lifecycle/deploy \
  --runtime distributed --json

# Watch progress
noetl status <execution_id> --json | jq '.completed_steps,.current_step'

# Verify
noetl run automation/agents/ai_os/lifecycle/status \
  --runtime distributed --json
```

After deploy completes, the spike e2e smoke should run GREEN with a
real diagnosis attached (see
`ai-meta/playbooks/ai_os_spike_e2e_smoke.md`).

## Tear it down

```bash
noetl run automation/agents/ai_os/lifecycle/undeploy \
  --runtime distributed \
  --payload '{"ollama":{"preserve_data":true}}' \
  --json
```

`preserve_data: true` (default) keeps the PVC so a re-deploy
doesn't have to re-pull multi-GB model files. Set to `false` to
also drop the PVC.

## Workload knobs

### `lifecycle/deploy`

| Path                              | Default                         | What it controls                          |
|-----------------------------------|---------------------------------|-------------------------------------------|
| `namespace`                       | `noetl`                         | namespace for Ollama + bridge             |
| `ollama.image`                    | `ollama/ollama:latest`          | Ollama image tag                          |
| `ollama.storage_size`             | `20Gi`                          | PVC size for the model store              |
| `ollama.storage_class`            | `""` (cluster default)          | StorageClass for the PVC                  |
| `ollama.service_name`             | `ollama`                        | Service name (matches bridge's URL)       |
| `ollama.service_port`             | `11434`                         | Service port                              |
| `ollama.model`                    | `gemma2:2b`                     | Model to pre-pull (empty to skip)         |
| `ollama.cpu_request` / `_limit`   | `500m` / `2`                    | CPU resources                             |
| `ollama.memory_request` / `_limit`| `2Gi` / `4Gi`                   | Memory resources                          |
| `ollama.ready_timeout_seconds`    | `300`                           | wait timeout for pod readiness            |
| `bridge.helm_release`             | `noetl`                         | Helm release name                         |
| `bridge.helm_chart`               | `repos/ops/automation/helm/noetl`| Path to chart                            |
| `expected_kube_context`           | `kind-noetl`                    | Local-terminal context guard              |

### `lifecycle/undeploy`

| Path                              | Default     | What it controls                                       |
|-----------------------------------|-------------|--------------------------------------------------------|
| `namespace`                       | `noetl`     |                                                        |
| `ollama.preserve_data`            | `true`      | Set to `false` to also delete the model-store PVC      |
| `bridge.helm_release`             | `noetl`     |                                                        |
| `expected_kube_context`           | `kind-noetl`|                                                        |

### `lifecycle/status`

No knobs beyond `namespace` and `noetl_url`. Read-only.

## Idempotency

All three lifecycle verbs are safe to re-run:

- `deploy` — `kubectl apply` reconciles, helm upgrade reuses the
  release, `pull_model` skips if the model is already cached.
- `undeploy` — uses `--ignore-not-found` everywhere; running on a
  cluster that's already torn down is a no-op.
- `status` — pure read.

## Optional-dependency contract

The deploy playbook *adds* the AI subsystem to a cluster that didn't
have it. It doesn't change anything about how noetl core runs without
it. If `lifecycle/deploy` fails partway through, noetl core keeps
running — only the AI features won't be available until the deploy
completes successfully.

## See also

- [Spike e2e smoke runbook](../../../../ai-meta/playbooks/ai_os_spike_e2e_smoke.md)
- [Self-troubleshoot agent](../troubleshoot/README.md)
- [NoETL-as-AI-OS architecture spike](../../../../ai-meta/sync/issues/2026-05-03-noetl-as-ai-os-architecture-spike.md)
