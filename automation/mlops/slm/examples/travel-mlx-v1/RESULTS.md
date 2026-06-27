# travel SLM — first real fine-tune (local Apple-Silicon, mode=mlx)

The first **real** (non-stub) fine-tune of the travel-domain SLM, run
locally on an Apple-Silicon box via the new `mode=mlx` finetune backend
(`lib/slm_finetune.py` `_train_mlx`, `mlx-lm` LoRA).  No GPU node pool,
no container — the LoRA trained in unified memory and the full pipeline
(dataset → finetune → registry → eval → registry → package → registry)
ran end-to-end against the file-backed G3 registry
(`NOETL_REGISTRY_BACKEND=local`).

This run is the proof that the platform's Phase-B finetune path produces
a real model artifact + lineage; the eval numbers below are an honest
baseline, **not** a production-ready model (see *Verdict*).

## Host

| | |
| :-- | :-- |
| Machine | Mac Studio (Mac13,1) |
| Chip | Apple M1 Max (10 cores: 8P/2E) |
| Unified memory | 32 GB |
| OS | macOS 26.3.1, arm64 |
| Runtime | `mlx-lm` 0.31.3 in an arm64 Python 3.12 venv |

## Training

| | |
| :-- | :-- |
| Base model | `Qwen/Qwen2.5-1.5B-Instruct` (full bf16, ≈3 GB pulled from HF) |
| Recipe | single multitask LoRA (extract + render in one adapter) |
| Train data | 29 train records → 58 multitask examples (oracle labels only) |
| Trainable params | 5.276 M / 1543.714 M (0.342 %) |
| Hyperparams | iters 800, batch 1, top-16 layers, lr 1e-4, max-seq 2048, `--mask-prompt` |
| Peak memory | 9.7 GB |
| Wall-clock | ≈25 min |
| Final train loss | 0.000 |
| Val loss curve | 0.811 → 0.077 → 0.079 → 0.088 → 0.089 |

Data choice: trained on the **oracle labels only** (not the
constrained-teacher augmentation) because the eval scores per-field
**exact match against the oracle `labels`** — training directly on that
target is the cleanest test of "can the SLM learn the deterministic
floor's decisions".

## Eval (16-example holdout, schema-constrained decoding)

Constrained decoding = the model proposes JSON, then the contract
schemas dispose (`_constrain_extract` / `_constrain_render` repair toward
a minimal schema-valid form) — the same "constrain, don't enlarge the
model" lever Phase 1 used.

All three on the SAME `v1_constrained` 16-example holdout:

| metric | SLM (mlx) | oracle floor | CPU stub |
| :-- | --: | --: | --: |
| widget_schema_validity | **1.0000** | 1.0 | 1.0 |
| extract_schema_validity | **1.0000** | 1.0 | 1.0 |
| tool_vocab_validity | **1.0000** | 1.0 | 1.0 |
| render_intent_vocab_validity | **1.0000** | 1.0 | 1.0 |
| tool_match | 0.5625 | 1.0 | 0.6875 |
| render_intent_match | 0.5625 | 1.0 | 0.6250 |
| arg_fidelity | 0.5625 | 1.0 | 0.4375 |
| slot_update_match | 0.6250 | 1.0 | 0.5000 |
| widget_type_match | 0.3750 | 1.0 | 0.5000 |

The fine-tune and the retrieval stub **trade wins**: the SLM is better
on `arg_fidelity` (0.5625 vs 0.4375) and `slot_update_match` (0.625 vs
0.5) — it generalizes argument/slot structure rather than copying a
nearest neighbour — but worse on `tool_match`, `render_intent_match`,
and `widget_type_match`, where nearest-prototype retrieval copies a
memorised label that happens to match on this distribution-overlapping
holdout.  Neither beats the deterministic floor.

Latency (unoptimized local serving, 2 generations/turn, greedy):
p50 9.2 s / p95 13.1 s.

Gate: **FAIL** (match targets 0.95–0.98 not met).

## Verdict — not yet good enough to replace the OpenAI/Gemini path

The fine-tune **holds the floor's 100 % schema validity** (every emitted
extract + widget envelope is contract-valid by construction), and the
generations are genuinely sensible — exact oracle match on clear turns
("plan a trip" → `collect_missing`, "confirm and purchase" →
`create_order`/`order_confirmation`), correct tool+intent on "what
flights are available".

But on per-field match it does **not** beat the deterministic floor, and
against the retrieval CPU stub it only **trades wins** (better on
arg/slot, worse on tool/intent/widget — table above).  So this iteration
did **not** close the gap the stub honestly failed.  The weakest pass is
render (`widget_type_match` 0.375): on turns with no tool data yet (e.g.
`show_flights` before offers exist) the model under-produces the widget
the oracle emits.

What a next iteration needs:

1. **More data.** 58 examples is tiny.  Wire the config's
   `event_log_replay` (cap 1000 turns of real Muno planner turns) into
   the train set; the bounded vocab (4 tools, 12 intents) generalizes,
   but only with coverage of the context-dependent turns ("that flight",
   "those") the model currently misroutes.
2. **Richer render conditioning.** The render pass needs the
   `tool_summary` / slot context the oracle's `render` fn sees, not just
   `turn` + `extraction`, so it can emit the right widget on
   data-bearing turns.
3. **True grammar-constrained generation** at decode time (logit
   masking / outlines over the contract enums) rather than only
   post-hoc repair — this lifts the in-vocab-but-wrong tool/intent
   cases that the repair lever can't fix.
4. **Teacher-augmented + curriculum** training once (1)–(3) are in, and
   a larger candidate (e.g. qwen2.5-3B) if 1.5B plateaus below the gate.

## Registry entries (local G3 backend)

```
dataset  registry://muno/travel/dataset/travel_v1_constrained/1
model    registry://muno/travel/model/travel_slm_multitask/1     (mlx LoRA adapter, ≈39 MB tar)
eval     registry://muno/travel/eval/travel_slm_multitask/1      (lineage → model)
release  registry://muno/travel/release/travel_slm_multitask/1   (lineage → [model, eval])
```

## Reproduce

```bash
# arm64 venv with mlx-lm
python3 -m venv .slm-venv && .slm-venv/bin/pip install mlx-lm

export SLM_DATASET_VERSION=v1_constrained
export NOETL_REGISTRY_BACKEND=local
export NOETL_REGISTRY_LOCAL_DIR=$PWD/.slm_registry
CONFIG=$PWD/repos/travel/automation/mlops/slm/travel/slm.config.yaml
LIB=repos/ops/automation/mlops/slm/lib

# train (the adapter + model artifact register into G3)
.slm-venv/bin/python $LIB/slm_finetune.py --config "$CONFIG" --backend mlx \
  --tenant muno --project travel --learning-rate 1e-4 \
  --mlx-iters 800 --mlx-batch-size 1 --mlx-num-layers 16 --mlx-max-seq-length 2048

# eval the trained candidate under schema-constrained decoding
.slm-venv/bin/python $LIB/slm_eval.py --config "$CONFIG" --candidate slm \
  --model-ref latest --tenant muno --project travel --register

# package → model card + release
.slm-venv/bin/python $LIB/slm_package.py --config "$CONFIG" \
  --model-ref latest --eval-ref latest --tenant muno --project travel
```

The trained adapter + the packed model/release tarballs live under the
local registry dir + the dataset's `models/` (both git-ignored — large
binaries); `MODEL_CARD.md` + `eval_report.json` in this directory are the
committed text artifacts of the run.
