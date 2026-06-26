# `automation/mlops/slm` — generic SLM MLOps template pack

The domain-agnostic template pack from the Domain-Specific SLM platform RFC
([noetl/ai-meta#139](https://github.com/noetl/ai-meta/issues/139)). Every stage
of an org's small-language-model lifecycle runs **as a NoETL playbook**
(MLOps-as-playbooks dogfooding), driven entirely by one org
`slm.config.yaml` — no per-domain pipeline code.

Phase A ([#140](https://github.com/noetl/ai-meta/issues/140) /
[noetl/travel#64](https://github.com/noetl/travel/issues/64)) ships the two
stages that run on existing tool kinds (not gated on platform foundations
G1/G2/G3):

| Playbook | Role |
| :-- | :-- |
| `dataset_build.yaml` | Seed corpus → labels (deterministic oracle floor + optional schema-constrained teacher ceiling) → schema-validate → train/eval split → versioned JSONL + manifest (registry stub). `-r local` only (kind:shell against on-disk files). |
| `dataset_build_distributed.yaml` | **Generated**, `-r distributed`-capable form of the above — packs the lib + config + schemas + seed as a base64 file tree in one `kind:python` step so it runs on a worker pod with no repos on disk. Regenerate with `build_distributed_playbook.py`. |
| `eval.yaml` | Eval split + candidate producer → match/validity/latency metrics vs floor + (deferred) ceiling → gate vs config targets → `eval_report.json`. |

`lib/` holds the generic engines (`slm_dataset_build.py`, `slm_eval.py`,
`slm_teacher.py` — the pluggable teacher providers, `slm_schema.py` — draft-07 →
Vertex `responseSchema` converter, `slm_common.py` — config load, config-relative
path resolution, JSONL IO, and a stdlib draft-07 JSON-Schema validator because the
runtime has no `jsonschema`).

## Schema-constrained teacher (the Phase 1 finding)

The first on-cluster ceiling run (raw `gemini-2.5-pro`, no output-schema
enforcement) scored **0% valid widget envelopes / 49% valid extractions** —
*below* the deterministic oracle floor — because the model picked valid widget
*types* but emitted the wrong tool-request keys (`tool_id` instead of `tool`) and
empty payloads. The lever is **not a bigger model**; it is
**schema-constrained decoding**. `slm_teacher.py` now hands the teacher a Vertex
`generationConfig.responseSchema` derived from the contract schemas
(`slm_schema.py`), so extract output and per-turn widget payloads are schema-valid
by construction; the cheaper `gemini-2.5-flash` is the label source. The
authoritative training target stays the deterministic oracle; the constrained
teacher is augmentation, validated + repaired toward the oracle contract before
inclusion (`dataset_build` `labels_teacher_repaired`).

## Distributed run (`-r distributed`)

```bash
# 1. regenerate the self-contained playbook from the org config
python3 automation/mlops/slm/build_distributed_playbook.py \
  --config ../travel/automation/mlops/slm/travel/slm.config.yaml \
  --out automation/mlops/slm/dataset_build_distributed.yaml \
  --path muno/slm/dataset-build-constrained
# 2. register it to the catalog, then run on the worker pool
noetl exec muno/slm/dataset-build-constrained -r distributed \
  --set version=v1_constrained            # add --set limit=N to cap teacher spend
```

The worker mints its Vertex Workload-Identity token in-python from the pod
metadata server (no API key, no Secret Manager). The worker image has **no
PyYAML**, so the generator packs the config as pre-parsed JSON and
`slm_common.load_config` reads it without `yaml`.

## Run

```bash
# from the ai-meta root (or any cwd whose relative paths resolve)
noetl exec repos/ops/automation/mlops/slm/dataset_build.yaml -r local \
  --set config=repos/travel/automation/mlops/slm/travel/slm.config.yaml
noetl exec repos/ops/automation/mlops/slm/eval.yaml -r local \
  --set config=repos/travel/automation/mlops/slm/travel/slm.config.yaml
```

`-r local` runs via the embedded NoETL Rust interpreter (no server). The
distributed shape (`kind: python` steps on the kind cluster via `-r
distributed`) is the production form — the engine logic is identical and lives
in `lib/`, so the swap is mechanical.

## Config-only per domain (proven)

`examples/support_triage/` is a deliberately different toy domain (support-ticket
triage — no tools, no widgets). It stands up dataset_build + eval by supplying
only its own `slm.config.yaml` + `oracle.py` + corpus + schema, running the
**same** two playbooks with **zero** framework edits:

```bash
noetl exec repos/ops/automation/mlops/slm/dataset_build.yaml -r local \
  --set config=repos/ops/automation/mlops/slm/examples/support_triage/slm.config.yaml
noetl exec repos/ops/automation/mlops/slm/eval.yaml -r local \
  --set config=repos/ops/automation/mlops/slm/examples/support_triage/slm.config.yaml
```

That is the RFC §2.2 "second domain" extraction test, passing in Phase A.

## What the org config supplies

See the platform RFC §2.2 for the full surface. The blocks Phase A consumes:
`roles[]` (I/O contract schemas + the deterministic oracle module), `data`
(seed corpus + split), `dataset_build`, and `eval` (metrics + targets). The
`teachers` / `model` / `serving` / `improvement` blocks are present-but-gated
(teacher budget → RFC decision #6; finetune/package → G1/G2/G3;
loop → Phase C).

## Not in Phase A (gated)

`finetune` / `package` (G1 GPU-job dispatch + G2 long-async + G3 registry),
`deploy` / `shadow_eval`, `traffic_capture` / `drift_monitor` /
`retrain_orchestrator` (Phase C loop). The model-choice decision is **deferred
until this baseline** informs it.
