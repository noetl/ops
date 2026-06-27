# Model card — travel SLM (multitask) v3

- **Model**: `registry://muno/travel/model/travel_slm_multitask/3` (registry v3)
- **Dataset**: `registry://muno/travel/dataset/travel_v3/1` (950 turns, train 806 / eval 144)
- **Eval**: `registry://muno/travel/eval/travel_slm_multitask/3` (constrained holdout)
- **Backend / recipe**: mlx / lora (single multitask LoRA: extract + render)
- **Base model**: `qwen2.5-1.5b-instruct`
- **Decoding**: logit-level grammar-constrained on the extract pass
  (lm-format-enforcer; tool + render_intent enums) + post-hoc schema repair on render
- **Lineage**: dataset → model → eval

## Intended use

Drop-in for the travel domain's intent-extraction + widget-render passes (the
two LLM calls the Muno itinerary-planner declares). Serving target: `cpu`.

## Eval metrics (v3 constrained, 144-turn holdout, vs the oracle floor)

| metric | value | gate |
| :-- | --: | --: |
| widget_schema_validity | 1.0000 | 1.0 ✅ |
| extract_schema_validity | 1.0000 | 1.0 ✅ |
| tool_vocab_validity | 1.0000 | 1.0 ✅ |
| render_intent_vocab_validity | 1.0000 | 1.0 ✅ |
| tool_match | 0.9444 | 0.98 |
| render_intent_match | 0.9236 | 0.98 |
| widget_type_match | 0.7917 | 0.98 |
| arg_fidelity | 0.9444 | 0.95 |
| slot_update_match | 0.9375 | 0.95 |

- **Gate**: FAIL — `widget_type_match` 0.7917 is the blocker (~0.19 short); the
  other four match fields are within ~0.006–0.057 of target.
- **Floor**: schema validity 1.0 held (now *guaranteed* on extract by constrained
  decoding).
- **Latency**: p50 6.5 s / p95 15.9 s (unoptimized local serving).

## Progression

| field | v1 | v2 | v3 |
| :-- | --: | --: | --: |
| tool_match | 0.5625 | 0.8017 | 0.9444 |
| render_intent_match | 0.5625 | 0.8595 | 0.9236 |
| widget_type_match | 0.3750 | 0.6529 | 0.7917 |
| arg_fidelity | 0.5625 | 0.7934 | 0.9444 |
| slot_update_match | 0.6250 | 0.9091 | 0.9375 |

## Limitations

- Trained on a synthetic oracle-routed corpus; coverage is bounded by the 9
  reachable render intents / 4 tools / 10 widget types the oracle emits.
- Constrained decoding guarantees *schema validity* on extract, not *semantic
  correctness* — an in-vocab-but-wrong tool/intent is still possible (the match
  metrics bound that).  Render is repaired post-hoc, not logit-constrained.
- Not yet Muno-ready by the strict gate; `widget_type_match` (render generation
  for data-bearing widgets) is the remaining bottleneck.
