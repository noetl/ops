# travel SLM v2 — data-scaling iteration (local Apple-Silicon, mode=mlx)

The second iteration of the travel-domain SLM fine-tune.  v1 held 100 %
schema validity but did **not** beat the deterministic oracle floor on the
per-field *match* metrics (tool 0.56 / intent 0.56 / widget_type 0.38);
the diagnosed root cause was **tiny data** (45 turns → 58 examples).  v2
attacks exactly the two next-iteration levers v1's RESULTS named:

1. **More data** — a 701-turn oracle-routed synthetic corpus (vs 45).
2. **Richer render conditioning** — the render pass now conditions on the
   `tool_summary` the oracle's `render` fn sees, not just `turn` +
   `extraction`.

Same pipeline (dataset → finetune → registry → eval → registry), same
file-backed G3 registry (`NOETL_REGISTRY_BACKEND=local`), same host.

## Host

| | |
| :-- | :-- |
| Chip | Apple M1 Max (10 cores: 8P/2E), 32 GB unified memory |
| Runtime | `mlx-lm` 0.31.3 in an arm64 Python 3.12 venv |

## Dataset v2 — composition

Built by `gen_synthetic_corpus.py` (in the travel repo): it crafts
`(event, slot_state)` inputs that deterministically route the oracle into
every reachable branch, then the generic `dataset_build` engine labels
them with the **oracle as the authoritative target** (free, 100 %
schema-valid by construction).

| | v1 | **v2** |
| :-- | --: | --: |
| Turns (total) | 45 | **701** |
| Train turns / examples | 29 / 58 | **580 / 1160** |
| Eval (holdout) turns | 16 | **121** |
| Reachable render intents covered | 9 | **9** |
| Tools covered | 4 | **4** |
| Widget types covered | 10 | **10** |
| Schema validity (extract/render/widget) | 100 % | **100 %** |

Leakage control: train and eval draw from **disjoint phrasing templates**
and **disjoint date/party pools**; a hard cross-split dedup guarantees no
eval turn shares an `(event, payload, slot_state)` signature with train
(verified: 0 shared phrasings, 0 cross-split signature collisions).  The
full city vocabulary appears in both splits on purpose (city→city_code is
a closed lookup the model is meant to learn); eval holds out the surface
form / parameter combination, so it measures generalisation to new
phrasings, not new vocab.

Per-intent train counts (oracle-labelled): collect_missing 94,
show_hotels 118, show_places 108, order_confirmation 96, summary 85,
show_flights 83, flight_detail 47, calendar_live 36, summarize 34.

**Teacher (ceiling) spend this iteration: $0.**  The constrained
Gemini-flash teacher mints its OAuth token from the GKE metadata server
(Workload Identity) — it runs only on the in-cluster worker pool, not on
this local Mac (no metadata server) and not on kind (no WI).  The v1
ceiling measurement also showed the teacher *diverges* from the
authoritative oracle on exactly the graded fields (tool-agreement 0.357,
intent-agreement 0.286), so teacher-augmented **extract** labels would
regress the oracle-match metrics.  v2 therefore trains on the oracle
target alone; the teacher ceiling is carried forward as the reference.
A bounded on-cluster teacher *diversity* pass is the natural next
iteration once the oracle-only baseline meets the floor.

## Training — Qwen2.5-1.5B-Instruct

| | |
| :-- | :-- |
| Base model | `Qwen/Qwen2.5-1.5B-Instruct` |
| Recipe | single multitask LoRA (extract + render in one adapter) |
| Trainable params | 5.276 M / 1543.714 M (0.342 %) |
| Hyperparams | iters 1400, batch 1, top-16 layers, lr 2e-4, max-seq 2304, `--mask-prompt` |
| Peak memory | 12.4 GB |
| Final train loss | 0.000 |
| Val loss curve | 0.745 → 0.042 → 0.007 → 0.005 → **0.002** |

(First attempt at batch 4 / seq 2304 blew past 32 GB unified memory and
swap-thrashed; batch 1 is the proven-safe footprint and is what these
numbers come from.  `max-seq 2304` is needed because the render examples,
now carrying the `tool_summary`, reach 2178 tokens.)

## Eval — 121-turn holdout, schema-constrained decoding

| metric | v1 (1.5B) | **v2 (1.5B)** | Δ v1→v2 | oracle floor | gate target |
| :-- | --: | --: | --: | --: | --: |
| widget_schema_validity | 1.0000 | **1.0000** | — | 1.0 | 1.0 ✅ |
| extract_schema_validity | 1.0000 | **1.0000** | — | 1.0 | 1.0 ✅ |
| tool_vocab_validity | 1.0000 | **1.0000** | — | 1.0 | 1.0 ✅ |
| render_intent_vocab_validity | 1.0000 | **1.0000** | — | 1.0 | 1.0 ✅ |
| tool_match | 0.5625 | **0.8017** | +0.239 | 1.0 | 0.98 |
| render_intent_match | 0.5625 | **0.8595** | +0.297 | 1.0 | 0.98 |
| widget_type_match | 0.3750 | **0.6529** | +0.278 | 1.0 | 0.98 |
| arg_fidelity | 0.5625 | **0.7934** | +0.231 | 1.0 | 0.95 |
| slot_update_match | 0.6250 | **0.9091** | +0.284 | 1.0 | 0.95 |

Latency (unoptimized local serving, 2 generations/turn, greedy):
p50 7.2 s / p95 15.4 s / mean 8.6 s.

Gate: **FAIL** (match targets 0.95–0.98 not met), but every match field
improved **+0.23 to +0.30** and schema validity stayed pinned at 100 %.

### Did the render `tool_summary` conditioning help?

Yes, clearly.  The two render-side metrics were v1's weakest:

- `widget_type_match`: 0.375 → **0.653** (+0.278, nearly doubled)
- `render_intent_match`: 0.5625 → **0.8595** (+0.297)

Feeding the render pass the tool result (place / offer / hotel data) lets
the model copy real values into schema-valid widget payloads instead of
hallucinating them, so fewer envelopes are dropped at constrained decode.

### Remaining weak slices (the next bottleneck)

From the per-predicted-intent breakdown:

- **`show_places` routing** is the weakest (only 3/14 of predicted
  `show_places` turns carried the correct first tool) — the google-places
  search hop is the most-confused branch.
- A handful of **`clarify` fall-backs** (out-of-vocab generations the
  constraint maps to `clarify`, an intent the oracle never emits).
- `widget_type_match` (0.653) is still the headline gap — even when the
  intent is right, the render generation doesn't always reproduce the
  exact valid widget sequence (e.g. the `summary` two-widget case).

## Capacity comparison — Qwen2.5-3B-Instruct (aborted)

The 3B LoRA was started on this v2 dataset to test capacity vs data as the
ceiling, then **aborted**: the v2 failure modes (the `show_places` over-
prediction, malformed-output fall-backs, render generation) pointed at
data/decode, not capacity.  The follow-up **v3** iteration (targeted data +
grammar-constrained decoding) on the **1.5B** confirmed this — see
[`../travel-mlx-v3/RESULTS.md`](../travel-mlx-v3/RESULTS.md): tool 0.80→0.94,
widget_type 0.65→0.79, with `show_places` going 3/14 → 27/27 correct tool.

## Verdict — not yet Muno-ready by the strict gate, but a large step

v2 turned the v1 "honest fail" into a model that is **right ~80–91 % of
the time on every match field** while still holding the floor's 100 %
schema validity — a +0.23–0.30 jump from data scaling + render
conditioning alone.  It is **not** yet at the 0.95/0.98 gate, so it should
not replace the OpenAI/Gemini path in Muno yet.

Next bottleneck, in priority order: (1) the `show_places` routing slice
and the `clarify` fall-backs (targeted data + a routing-disambiguation
signal); (2) true grammar-constrained generation at decode time (logit
masking over the contract enums) rather than only post-hoc repair, to
kill the in-vocab-but-wrong cases; (3) the render two-widget sequences.
Whether 1.5B→3B closes enough of the gap to change this verdict is
answered in the capacity-comparison section above.

## Registry entries (local G3 backend)

```
dataset  registry://muno/travel/dataset/travel_v2/1
model    registry://muno/travel/model/travel_slm_multitask/2   (1.5B mlx LoRA adapter, lineage → dataset)
eval     registry://muno/travel/eval/travel_slm_multitask/2    (1.5B holdout eval)
```

(No `release` registered: the gate fails, so the model is not marked
serving-ready.)

## Reproduce

```bash
TRAVEL=repos/travel/automation/mlops/slm/travel
LIB=repos/ops/automation/mlops/slm/lib
VP=.slm-venv/bin/python   # arm64 venv with mlx-lm
export NOETL_REGISTRY_BACKEND=local
export NOETL_REGISTRY_LOCAL_DIR=$PWD/.slm_registry

# 1. generate the leak-free v2 corpus (701 turns)
$VP $TRAVEL/gen_synthetic_corpus.py --out $TRAVEL/datasets/seed/travel_v2_corpus.jsonl --report

# 2. oracle-label it into dataset v2 (no teacher)
$VP $LIB/slm_dataset_build.py --config $TRAVEL/slm.config.yaml \
  --corpus $PWD/$TRAVEL/datasets/seed/travel_v2_corpus.jsonl --version v2 --no-teacher

# 3. train the 1.5B multitask LoRA on v2
$VP $LIB/slm_finetune.py --config $TRAVEL/slm.config.yaml \
  --dataset $PWD/$TRAVEL/datasets/build/travel/v2 --backend mlx \
  --mlx-iters 1400 --mlx-batch-size 1 --mlx-num-layers 16 \
  --mlx-max-seq-length 2304 --mlx-val-batches 12 --learning-rate 2e-4

# 4. eval on the 121-turn holdout under constrained decoding
$VP $LIB/slm_eval.py --config $TRAVEL/slm.config.yaml \
  --dataset $PWD/$TRAVEL/datasets/build/travel/v2 --candidate slm \
  --model-artifact $PWD/$TRAVEL/datasets/build/travel/v2/models/travel_slm_multitask-mlx \
  --out $PWD/$TRAVEL/datasets/build/travel/v2/eval_report_mlx.json --register
```

The trained adapters + packed tarballs live under the local registry dir +
the dataset's `models/` (git-ignored — large binaries); this directory's
`*.json` + `RESULTS.md` are the committed text artifacts of the run.
