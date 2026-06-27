# travel SLM v4 — render iteration (targeted at widget_type_match 0.79)

Fourth iteration of the travel-domain SLM on the local Apple-Silicon
`mode=mlx` path.  The goal was the one gate field v3 left short:
**`widget_type_match` 0.79** (target 0.98), the render generation for the
data-bearing widgets (`flight_list`, `hotel_list`, the two-widget
`itinerary_summary`+`calendar_view` summary) plus a soft `show_flights`
routing slice.

**Outcome: the gate was not cleared, and v3 remains the best model.**  This
write-up is a negative result with three concrete, reproducible findings that
constrain the next iteration.  All work was local (MLX on a 32 GB Mac); no
GKE/GPU-pool/prod deploy, no flag flips, no OQ5/result_store/NATS/IAM/secret
touch.

## The two levers tried

1. **DATA** — dataset v4 / v4b: over-sample the weak render slices
   (flight_list / hotel_list / summary) and the show_flights boundary.
2. **CONSTRAINED DECODE** — a per-widget-type *payload-complete* render
   constraint: once a widget_type is chosen, the lm-format-enforcer decoder is
   constrained to a schema that REQUIRES that type's mandatory payload fields,
   so the model can't emit a valid-type-but-incomplete-payload widget (which
   `validate_envelope` drops → the widget-type sequence shortens →
   `widget_type_match` fails).  Wired behind `SLM_CONSTRAIN_RENDER`
   (`slm_constrain.render_schema_payload_complete`).

## Numbers — v3 vs the v4 family (1.5B, constrained extract, ~138–144 holdout)

| field | v3 (best) | v4 | v4b render-OFF | v4b render-ON | gate |
| :-- | --: | --: | --: | --: | --: |
| tool_match | 0.944 | 0.542 | **0.949** | 0.949 | 0.98 |
| render_intent_match | 0.924 | 0.901 | 0.841 | 0.841 | 0.98 |
| widget_type_match | **0.792** | 0.514 | 0.768 | **0.297** | 0.98 |
| arg_fidelity | 0.944 | 0.528 | 0.877 | 0.877 | 0.95 |
| slot_update_match | 0.938 | 0.310 | **0.978** | 0.978 | 0.95 |
| widget_schema_validity | 1.0 | 1.0 | 1.0 | 1.0 | 1.0 ✅ |
| extract_schema_validity | 1.0 | 1.0 | 1.0 | 1.0 | 1.0 ✅ |
| tool/intent vocab validity | 1.0 | 1.0 | 1.0 | 1.0 | 1.0 ✅ |

(v4 = aggressive over-sampling + envelope-first serialization; v4b render-OFF =
balanced data + reverted serialization, model registry version 6; v4b render-ON
= same model with the payload-complete render constraint enabled.)

## Three findings

### 1. Aggressive render over-sampling regresses the EXTRACT pass (v4)

v4 boosted show_flights/show_hotels/summary 1.7–1.8× while the funnel-start
extract slices (collect_region / unknown_city / collect_dates) stayed flat,
dropping them to ~6 % of the corpus.  Because every record makes one extract +
one render example and the render completions are far longer (a flight_list
copies 3 full cards), the render task dominates the `--mask-prompt` loss
tokens; over-sampling render-heavy records starved extract of gradient.  At
1600 iters (0.73 epoch) the model undertrained on "no city → emit NO region"
and **hallucinated regions on collect_missing turns** → `slot_update_match`
0.94 → **0.31**, dragging tool/arg/widget down with it.  The v3 model gets the
same held-out turns right.  *Lesson: keep the extract distribution balanced;
boosting render slices must scale the funnel slices in step.*

### 2. Envelope-keys-first render serialization destabilises free-running generation

To make the payload-complete constraint work, the render completion was
serialized **envelope-keys-first / payload-last** (widget_type emitted first,
matching the constraint's `force_json_field_order`) instead of v1–v3's
`sort_keys=True` (which sorts `payload` first alphabetically).  Two independent
runs (v4 and v4b) with this change **collapsed the model's free-running greedy
generation into repetition/gibberish** on the extract pass
(`!missingparty"]partyCode...`) — even though the teacher-forced val loss
stayed low (0.007) and the training data itself was well-formed.  The training
loss curve showed a matching instability (a sustained spike to ~8.3 around iter
60 that v3's recipe never had).  **Reverting to `sort_keys=True` restored clean
generation** (smooth loss, no spike) — see v4b render-OFF, which recovered
extract (tool 0.95, slot 0.98).  *Lesson: the serialization order the model is
trained on is load-bearing for free-running decode stability on this 1.5B; the
envelope-first idea was reverted.*

### 3. The payload-complete render constraint is blocked on the DEEP list widgets by an lm-format-enforcer limitation

The constraint is a clean win on the **shallow** widgets
(`itinerary_summary`+`calendar_view` summary, `order_confirmation`, the
`collect_missing` inputs) — those complete and validate.  But on the **deep
list** widgets (`flight_list` / `hotel_list`, each a `title`+array-of-cards
payload) it truncates: the decoder fills the long nested payload, then
degenerates into whitespace before closing the envelope, so the JSON never
parses and the widget is dropped.  Root cause: lm-format-enforcer's
`force_json_field_order` **does not compose with `anyOf`** — and `anyOf` is
required to offer multiple widget types — so inside any anyOf branch the
payload's required field order can't be forced and a small model skips a
required field (`title`) or wanders into an off-distribution optional, then
runs off the token budget.  Net effect: enabling the render constraint
**crashed `widget_type_match` from 0.768 to 0.297** (the 35+ list-widget turns
all dropped to empty).  The constraint stays opt-in and OFF by default.

## Verdict — not Muno-ready; v3 stays the best model

- The DATA lever did not move `widget_type` (v4b 0.768 ≈ v3 0.792) and slightly
  regressed routing (`render_intent` 0.841 vs 0.924) — the v4b model now
  mis-routes show_flights into show_hotels/calendar_live.
- The CONSTRAINT lever is net-negative on this model because the deep-list
  truncation outweighs the shallow-widget gains.
- The schema-validity floor held at 100 % throughout.

**The widget_type misses are now split between (a) routing errors
(render_intent → wrong widget) and (b) render-side payload completeness on the
deep list widgets.**  The constraint can't fix (a) and breaks on (b).

## Next bottleneck, in priority order

1. **Per-type SINGLE-schema render constraint (no anyOf).**  At serve/eval the
   render pass runs after extract, so the chosen `render_intent` is known; map
   it to the expected widget_type(s) and constrain the render to that ONE
   type's concrete schema.  Without anyOf, `force_json_field_order` works and
   the deep list payloads complete in order.  This is the real fix for
   finding 3 — at the cost of the model no longer *choosing* the widget_type
   freely (it follows the contract mapping, which is legitimate for serving).
2. **Routing data** for the show_flights↔show_hotels boundary
   (places_seen → flights vs picked_flight → hotels) to recover `render_intent`
   and fix the (a) bucket.
3. **Keep the extract distribution balanced** (finding 1) and the proven
   `sort_keys=True` serialization (finding 2) in any future data scaling.

## Registry entries (local G3 backend)

```
dataset  registry://muno/travel/dataset/travel_v4b/1
model    registry://muno/travel/model/travel_slm_multitask/6   (1.5B mlx LoRA on v4b, balanced, reverted serialization)
eval     registry://muno/travel/eval/travel_slm_multitask/4    (v4b render-OFF holdout)
```

(Models 4 = v4, 5 = v4b-envelope-first — both regressed, kept for the audit
trail.  No `release` registered — the gate still fails on widget_type, and v4b
does not beat v3.)

## Reproduce

```bash
TRAVEL=repos/travel/automation/mlops/slm/travel
LIB=repos/ops/automation/mlops/slm/lib
VP=.slm-venv/bin/python
export NOETL_REGISTRY_BACKEND=local NOETL_REGISTRY_LOCAL_DIR=$PWD/.slm_registry

# v4b balanced corpus + oracle labels
$VP $TRAVEL/gen_synthetic_corpus.py --out $TRAVEL/datasets/seed/travel_v4b_corpus.jsonl --profile v4b --seed muno-travel-v4b --report
$VP $LIB/slm_dataset_build.py --config $TRAVEL/slm.config.yaml --corpus $PWD/$TRAVEL/datasets/seed/travel_v4b_corpus.jsonl --version v4b --no-teacher

# retrain 1.5B (sort_keys=True serialization, v3 recipe; batch-1 safe footprint)
$VP $LIB/slm_finetune.py --config $TRAVEL/slm.config.yaml --dataset $PWD/$TRAVEL/datasets/build/travel/v4b \
  --backend mlx --mlx-iters 1400 --mlx-batch-size 1 --mlx-num-layers 16 --mlx-max-seq-length 2304 --mlx-val-batches 12 --learning-rate 2e-4

# A/B eval (render-OFF is the better mode; render-ON crashes widget_type on deep list widgets)
ART=$PWD/$TRAVEL/datasets/build/travel/v4b/models/travel_slm_multitask-mlx
$VP $LIB/slm_eval.py --config $TRAVEL/slm.config.yaml --dataset $PWD/$TRAVEL/datasets/build/travel/v4b \
  --candidate slm --model-artifact $ART --constrained-decode --out $PWD/$TRAVEL/datasets/build/travel/v4b/eval_report_off.json
SLM_CONSTRAIN_RENDER=1 $VP $LIB/slm_eval.py --config $TRAVEL/slm.config.yaml --dataset $PWD/$TRAVEL/datasets/build/travel/v4b \
  --candidate slm --model-artifact $ART --constrained-decode --out $PWD/$TRAVEL/datasets/build/travel/v4b/eval_report_on.json
```
