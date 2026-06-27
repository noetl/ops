# travel SLM v3 — two-lever iteration (targeted data + grammar-constrained decode)

Third iteration of the travel-domain SLM, on the local Apple-Silicon
`mode=mlx` path.  After v2 (data scaling 45→701 turns) lifted every match
field but stayed below the gate, this iteration executes the two levers v2's
write-up named, and a 3B capacity probe was run + aborted (capacity was not the
bottleneck — see below):

1. **Targeted data (v3 dataset).** Over-sample the v2-weak slices — `show_places`
   (the model *over-predicted* it: 3/14 correct tool on predicted-show_places
   turns) + its contrast neighbours + the multi-widget `summary` render
   sequence.  701 → **950 turns** (train 806 / eval 144), still leak-free,
   oracle-labelled, 100% schema-valid.
2. **True grammar-constrained decoding (lever 1).** A logit-level
   lm-format-enforcer processor wired into mlx generation
   (`lib/slm_constrain.py`) so the extract pass can only emit schema-valid
   tokens — `tool` ∈ the 4-tool enum, `render_intent.kind` ∈ the 12-intent
   enum — at generation time, not just in post-hoc repair.

## Progression — v1 → v2 → v3 (1.5B, same 121/144-turn holdout style)

| field | v1 | v2 | **v3 (constrained)** | total Δ | gate |
| :-- | --: | --: | --: | --: | --: |
| tool_match | 0.5625 | 0.8017 | **0.9444** | +0.382 | 0.98 |
| render_intent_match | 0.5625 | 0.8595 | **0.9236** | +0.361 | 0.98 |
| widget_type_match | 0.3750 | 0.6529 | **0.7917** | +0.417 | 0.98 |
| arg_fidelity | 0.5625 | 0.7934 | **0.9444** | +0.382 | 0.95 |
| slot_update_match | 0.6250 | 0.9091 | **0.9375** | +0.313 | 0.95 |
| widget_schema_validity | 1.0 | 1.0 | **1.0** | held | 1.0 ✅ |
| extract_schema_validity | 1.0 | 1.0 | **1.0** | held | 1.0 ✅ |
| tool_vocab / intent_vocab validity | 1.0 | 1.0 | **1.0** | held | 1.0 ✅ |

(v1 holdout = 16 turns; v2 = 121; v3 = 144 — the eval also got more robust each
iteration.)

## A/B — what each lever bought (v3, 144-turn holdout)

| field | v3 unconstrained | v3 **constrained** | Δ decode lever |
| :-- | --: | --: | --: |
| tool_match | 0.9236 | **0.9444** | +0.021 |
| render_intent_match | 0.9236 | 0.9236 | — |
| widget_type_match | 0.7917 | 0.7917 | — |
| arg_fidelity | 0.9444 | 0.9444 | — |
| slot_update_match | 0.9514 | 0.9375 | −0.014 |
| extract_schema_validity | 0.9792 | **1.0000** | +0.021 |
| widget_schema_validity | 1.0 | 1.0 | — |

- **Data lever (v2→v3 unconstrained)** is the big mover: tool +0.122, widget_type
  +0.139, arg +0.151.  The `show_places` slice went from **3/14 → 27/27** correct
  tool — the contrast over-sampling fixed the over-prediction completely.
- **Decode lever (v3 OFF→ON)** is narrow but real: it *guarantees* 100% extract
  schema validity (0.9792 → 1.0, the 3 malformed extracts eliminated) and nudges
  tool_match (+0.021) by killing the malformed-output / `clarify` fall-backs.  It
  does **not** move the semantic-correctness fields (render_intent / widget_type
  / arg / slot) — those are a data/generation property, not a decode-validity
  one.  (Render constraint was tried and turned OFF by default: forcing the
  widget_type enum with a generic payload — the render schema has no per-type
  payload requirements — perturbs the model into payloads that fail the per-type
  schema and get dropped → empty widgets, worse than plain generation + repair.)

Latency (unoptimized local serving, 2 generations/turn, greedy, constrained):
p50 6.5 s / p95 15.9 s / mean 8.5 s.

## 3B capacity probe — aborted (capacity is not the bottleneck)

A `qwen2.5-3b-instruct` LoRA was started on the v2 dataset to test whether
capacity, not data, was the ceiling.  It was **aborted** after the v2 failure
analysis (and confirmed by the v3 result): the dominant errors were a specific
routing slice (`show_places` over-prediction), malformed-output fall-backs, and
render generation — all addressed by targeted data + constrained decoding on the
**1.5B**, not by a bigger base.  3B would roughly double train + serve cost for
a capacity lever the evidence says isn't binding.  The qwen2.5-3b HF alias +
`--base-model` path is wired and reproducible if a future iteration wants it.

## Per-intent (v3 constrained) — the remaining bottleneck

```
show_places   27/27   collect_missing 22/22   order_confirmation 13/13
summary       22/22   calendar_live    7/7    flight_detail        8/8
show_hotels   18/20   summarize        4/4    show_flights        15/21  <- weakest
```

`show_flights` (15/21) is the last weak routing slice; `widget_type_match` (0.79)
is the headline gap — even with the right intent, the render pass doesn't always
reproduce the exact valid widget sequence (notably `flight_list` payloads and the
two-widget `summary`).

## Verdict — not yet Muno-ready by the strict gate; 4 of 5 fields within ~0.04

The model holds the floor's **100% schema validity** (now *guaranteed* on extract
by constrained decode) and is right **92–94%** on tool / intent / arg / slot —
all within ~0.006–0.057 of the 0.95/0.98 gate — but **`widget_type_match` 0.79**
is the clear blocker, ~0.19 short.  So it should **not** replace the
OpenAI/Gemini path in Muno yet, but it is close on the extraction side and the
remaining work is well-localised.

**Next bottleneck, in priority order:**

1. **Render generation for data-bearing widgets** (`widget_type_match` 0.79):
   the render pass needs either (a) a payload-complete per-widget-type schema fed
   to the constrained decoder (so widget_type *and* its required payload fields
   are enforced together), or (b) more targeted render training on `flight_list`
   + the `summary` two-widget sequence.
2. **`show_flights` routing** (15/21) — more contrast data around the
   places-seen → flights boundary.
3. A bounded **on-cluster teacher diversity pass** (still $0 this iteration — the
   teacher only runs on the in-cluster worker WI, not locally) once 1–2 land.

## Registry entries (local G3 backend)

```
dataset  registry://muno/travel/dataset/travel_v3/1
model    registry://muno/travel/model/travel_slm_multitask/3   (1.5B mlx LoRA on v3, lineage → dataset)
eval     registry://muno/travel/eval/travel_slm_multitask/3    (v3 constrained holdout eval)
```

(No `release` registered — the gate still fails on widget_type.)

## Reproduce

```bash
TRAVEL=repos/travel/automation/mlops/slm/travel
LIB=repos/ops/automation/mlops/slm/lib
VP=.slm-venv/bin/python
export NOETL_REGISTRY_BACKEND=local NOETL_REGISTRY_LOCAL_DIR=$PWD/.slm_registry

# 1. v3 corpus (over-sampled weak/contrast slices) + oracle labels
$VP $TRAVEL/gen_synthetic_corpus.py --out $TRAVEL/datasets/seed/travel_v3_corpus.jsonl --profile v3 --seed muno-travel-v3 --report
$VP $LIB/slm_dataset_build.py --config $TRAVEL/slm.config.yaml --corpus $PWD/$TRAVEL/datasets/seed/travel_v3_corpus.jsonl --version v3 --no-teacher

# 2. retrain 1.5B (batch-1 safe footprint; batch-4 OOM/swap-thrashes on 32 GB)
$VP $LIB/slm_finetune.py --config $TRAVEL/slm.config.yaml --dataset $PWD/$TRAVEL/datasets/build/travel/v3 \
  --backend mlx --mlx-iters 1400 --mlx-batch-size 1 --mlx-num-layers 16 --mlx-max-seq-length 2304 --mlx-val-batches 12 --learning-rate 2e-4

# 3. A/B eval on the 144-turn holdout (constrained vs not)
ART=$PWD/$TRAVEL/datasets/build/travel/v3/models/travel_slm_multitask-mlx
$VP $LIB/slm_eval.py --config $TRAVEL/slm.config.yaml --dataset $PWD/$TRAVEL/datasets/build/travel/v3 \
  --candidate slm --model-artifact $ART --no-constrained-decode --out $PWD/$TRAVEL/datasets/build/travel/v3/eval_report_off.json
$VP $LIB/slm_eval.py --config $TRAVEL/slm.config.yaml --dataset $PWD/$TRAVEL/datasets/build/travel/v3 \
  --candidate slm --model-artifact $ART --constrained-decode --register --out $PWD/$TRAVEL/datasets/build/travel/v3/eval_report_on.json
```

This directory's `*.json` + `RESULTS.md` are the committed text artifacts; the
adapters + tarballs are git-ignored (large binaries) under the dataset's
`models/` + the local registry dir.
