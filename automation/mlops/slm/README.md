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

## Phase B — finetune / eval(SLM) / package (noetl/ai-meta#141)

Phase B adds the three stages that **train** and ship a model, built on the
G1/G2/G3 platform foundations:

| Playbook | Role |
| :-- | :-- |
| `finetune.yaml` | Train a SINGLE multitask LoRA (extract + render in one adapter) on the Phase-1 train split → write the adapter artifact → register a G3 model (lineage → dataset). `mode=local` runs the CPU **stub** backend (the validation path); `mode=container` dispatches the real qwen2.5-1.5b / llama-3.2-1b LoRA as a **G1** GPU k8s Job with **G2** poll-completion. |
| `eval.yaml` (`candidate=slm`) | Pull the registered model, score it on the eval split under the SAME schema-constrained decoding the ceiling used, report validity vs the oracle floor + per-field match gaps → register a G3 eval (lineage → model). |
| `package.yaml` | Export the model (peft: merge the adapter), write a model card with metrics, bundle, register a G3 release (lineage → model + eval). |

`lib/` Phase-B engines: `slm_finetune.py` (training), `slm_infer.py` (the
serving runner — stub retrieval + peft LoRA, both under constrained decoding),
`slm_package.py` (release), plus `slm_registry.py` now carries a **local
file-backed backend** (`NOETL_REGISTRY_BACKEND=local`) that mirrors the G3
server semantics so the whole spine runs offline.

### Two backends, one artifact contract

The Phase-1 finding — *the lever is schema-constrained decoding, not model
size* — is the design center. Both backends propose an output and the contract
schemas dispose:

- **`stub`** — pure-stdlib, CPU, zero heavy deps. A nearest-prototype retrieval
  "model" over the multitask examples. This is the **tiny/dummy model** the
  validation runs end-to-end so the orchestration (dataset → finetune →
  registry → eval → release) is demonstrably correct without a GPU. Every
  emitted output is schema-constrained, so widget-envelope + extract validity
  stay 100% by construction.
- **`peft`** — the real LoRA fine-tune via PEFT/transformers, generated under
  JSON-schema / grammar-constrained decoding. Import-guarded (absent
  torch/transformers/peft it raises a clear "GPU runtime not installed"), so it
  only runs inside the G1 GPU training/serving image.

### Offline CPU smoke (the reproducible validation)

```bash
# from automation/mlops/slm
NOETL_REGISTRY_BACKEND=local \
python3 lib/slm_pipeline_smoke.py \
  --config /abs/path/repos/travel/automation/mlops/slm/travel/slm.config.yaml \
  --dataset-version v1_constrained
# asserts the dataset->model->eval->release lineage DAG + that constrained
# decoding holds schema validity at 1.0.  Exits non-zero on any failure.
```

Or via the playbooks (`-r local`), with the same local registry backend:

```bash
export NOETL_REGISTRY_BACKEND=local NOETL_REGISTRY_LOCAL_DIR=/tmp/slm_registry
noetl run automation/mlops/slm/finetune.yaml -r local
noetl run automation/mlops/slm/eval.yaml -r local \
  --set candidate=slm --set register=true --set dataset_version=v1_constrained
noetl run automation/mlops/slm/package.yaml -r local
```

The validation outcome on the travel v1_constrained dataset: the stub model
holds **100% schema validity** (widget + extract + tool/intent vocab) — it
matches the oracle floor's validity target — while the per-field **match** gate
honestly FAILS (`tool_match≈0.69`, `widget_type_match≈0.50`, …) because a tiny
retrieval model over 29 train turns is not production-quality. That failing gate
is the signal a real LoRA must close; it is not faked to 1.0.

### Real GPU training — what the operator must provision (gated)

`finetune.yaml mode=container` and the `peft` backend are **gated** on infra the
user must approve + stand up. None of it is deployed to prod by this work:

1. **GPU node pool** — a GKE pool with GPUs (e.g. `nvidia-l4`), tainted
   `nvidia.com/gpu=present:NoSchedule`, labelled
   `cloud.google.com/gke-accelerator=nvidia-l4`, with the NVIDIA device-plugin
   DaemonSet.
2. **Training image** `ghcr.io/noetl/slm-trainer:<tag>` — python3 + CUDA torch +
   transformers + peft + datasets + accelerate + the `lib/` engine at
   `/opt/slm/lib`; base-model weights baked or runtime-pullable.
3. **Dataset PVC** `slm-data` — pre-populated with `slm.config.yaml` + the built
   dataset under `/data/datasets/build/<project>/<version>/`, writable for the
   `/data/models` output.
4. **ServiceAccount** `noetl-slm-trainer` — Workload-Identity-bound to a GSA with
   registry + GCS write, carrying the internal-API token Secret
   `noetl-internal-api`.
5. **Platform flags (review-only today, NOT on prod)** — server
   `NOETL_REGISTRY_ENABLED=true` (G3), worker `NOETL_CONTAINER_COMPLETION_POLL=true`
   (G2), G1 container tool (tools ≥ 3.19.0) on the worker image.
6. **Worker RBAC** — the worker SA needs `batch/jobs.create` in the Job namespace.

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
noetl run muno/slm/dataset-build-constrained -r distributed \
  --set version=v1_constrained            # add --set limit=N to cap teacher spend
```

The worker mints its Vertex Workload-Identity token in-python from the pod
metadata server (no API key, no Secret Manager). The worker image has **no
PyYAML**, so the generator packs the config as pre-parsed JSON and
`slm_common.load_config` reads it without `yaml`.

## Run

```bash
# from the ai-meta root (or any cwd whose relative paths resolve)
noetl run repos/ops/automation/mlops/slm/dataset_build.yaml -r local \
  --set config=repos/travel/automation/mlops/slm/travel/slm.config.yaml
noetl run repos/ops/automation/mlops/slm/eval.yaml -r local \
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
noetl run repos/ops/automation/mlops/slm/dataset_build.yaml -r local \
  --set config=repos/ops/automation/mlops/slm/examples/support_triage/slm.config.yaml
noetl run repos/ops/automation/mlops/slm/eval.yaml -r local \
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

`finetune` / `package` (G1 GPU-job dispatch + G2 long-async),
`deploy` / `shadow_eval`, `traffic_capture` / `drift_monitor` /
`retrain_orchestrator` (Phase C loop). The model-choice decision is **deferred
until this baseline** informs it.

## G3 registry (model / dataset / eval / release) — noetl/ai-meta#146

The registry is the versioned, queryable catalog index the stages write to:
`dataset_build` registers a dataset, `finetune` registers a model + lineage +
metrics, `eval` registers an eval run, `package` registers a serving-ready
release. Large artifact bytes (datasets, adapter weights, eval reports) live in
the object store (the noetl/ai-meta#104 result tier); a registry entry records
*where* they live (`artifact_uri`) + *how they were produced* (`metadata` +
`lineage`).

- **Client lib**: [`lib/slm_registry.py`](lib/slm_registry.py) — `put_artifact`
  / `get_artifact` (object store), `register` / `resolve` / `list`, and the
  store-then-register convenience `put_and_register`. Server-mediated: it calls
  `/api/internal/registry/*` + `/api/internal/objects/*` with the internal
  service-account token (data-access-boundary.md — never direct DB / object
  access).
- **URN scheme**: an entry is addressed by `registry://<kind>/<name>/<version>`
  (or the fully-qualified `registry://<tenant>/<project>/<kind>/<name>/<version>`);
  `<version>` is an integer or `latest`. Resolves like a result-tier `noetl://`
  URN.
- **Demo / smoke**: [`registry.yaml`](registry.yaml) runs
  [`lib/slm_registry_smoke.py`](lib/slm_registry_smoke.py) — the end-to-end
  register / list / resolve / lineage / artifact-put+get flow. The server must
  run with `NOETL_REGISTRY_ENABLED=true` (additive / default-off).

```bash
NOETL_SERVER_URL=http://localhost:8082 \
NOETL_INTERNAL_API_TOKEN=<token> \
python3 repos/ops/automation/mlops/slm/lib/slm_registry_smoke.py
```

## Shadow rollout (Option A) — serving + data flywheel

The shadow-rollout pieces (RFC
[`travel/docs/rfc/travel-slm-shadow-rollout.md`](https://github.com/noetl/travel/blob/main/docs/rfc/travel-slm-shadow-rollout.md))
run the trained v3 SLM ALONGSIDE the live deterministic path on real turns,
log both outputs for comparison, and turn shadow traffic into training data —
without ever touching the served response.

- **Serving endpoint**: [`lib/slm_serve.py`](lib/slm_serve.py) — a stdlib
  `http.server` over `SlmRunner` (the Option-A local MLX pilot). Loads a model
  artifact once and exposes `POST /extract`, `POST /render`, `GET /healthz`,
  returning the same `{slot_updates, tool_requests, render_intent}` /
  `{bot_message, widgets}` shapes the planner's `extract_turn` /
  `render_widget_chat` emit, plus a `schema_valid` flag computed against the
  contract + widget schemas. Needs the mlx venv (mlx_lm + lm-format-enforcer):

  ```bash
  .slm-venv/bin/python lib/slm_serve.py \
    --config <slm.config.yaml> \
    --model-artifact <.../v3/models/travel_slm_multitask-mlx> \
    --host 0.0.0.0 --port 8099 --constrained-decode
  ```

- **Shadow core**: [`lib/slm_shadow.py`](lib/slm_shadow.py) — the per-turn
  comparison engine (a `ShadowClient` over the endpoint + per-field agreement
  extractors identical to `slm_eval`'s, so a captured shadow corpus is scored
  by the same metric code). The planner's worker step inlines the same urllib
  POST + equality checks.
- **Validation harness**: [`lib/slm_shadow_validate.py`](lib/slm_shadow_validate.py)
  — drives the endpoint over real eval turns, runs the oracle (the live path),
  and writes shadow-comparison records with per-field agreement + schema
  validity + latency. Off-cluster proof of the in-planner shadow branch.

  ```bash
  python3 lib/slm_shadow_validate.py \
    --config <slm.config.yaml> --endpoint http://localhost:8099 \
    --eval <.../v3/eval.jsonl> --n 22 --out shadow_corpus.jsonl
  ```

- **Data flywheel**: [`lib/slm_replay.py`](lib/slm_replay.py) `--shadow` reads
  the planner's shadow-leaf records out of the event log into a labelable
  corpus (turn + redacted text + the live label as `prod_extract` + the SLM
  shadow output), which `dataset_build --corpus` re-labels into a training
  dataset — closing the loop from production traffic to the next iteration.

  ```bash
  python3 lib/slm_replay.py --base-url http://localhost:8082 \
    --path muno/playbooks/itinerary-planner --shadow --out shadow_corpus.jsonl
  python3 lib/slm_dataset_build.py --config <slm.config.yaml> \
    --corpus shadow_corpus.jsonl --version shadow_v_next --no-teacher
  ```

The consuming planner branch (the `shadow_slm_compare` leaf, gated on
`workload.slm_shadow.enabled`, default OFF) lives in
[`noetl/travel`](https://github.com/noetl/travel) under
`playbooks/itinerary-planner.yaml`; a self-contained orchestrator self-test is
`playbooks/slm/shadow-selftest.yaml` there.
