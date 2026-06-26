"""Generic SLM eval engine.

Domain-agnostic.  Given a dataset's eval split + a *candidate* producer, it
computes the metrics the org's ``slm.config.yaml`` defines, measured against
two references the RFC names:

  * FLOOR   — the deterministic oracle (the safe baseline the model must beat).
  * CEILING — the teacher (e.g. OpenAI).  Requires teacher labels; when none
              are present (Phase A — no teacher budget yet, RFC decision #6) the
              ceiling rows are reported as ``deferred`` rather than faked.

Phase A candidate = the deterministic oracle itself (the trivial candidate that
validates the harness end-to-end and pins the FLOOR numbers).  Swapping in the
SLM later is a config change (``eval.candidate``), no engine edit.

Metrics:
  * match vs the stored labels: tool / argument / slot / render-intent /
    widget-type-sequence  (a deterministic candidate reproduces the floor → ~1.0;
    that 1.0 is the harness sanity check, not a model score).
  * absolute validity (the real Phase-A signal): widget-schema validity %,
    extract-output schema validity %, tool-vocab validity %, render-intent
    vocab validity %.
  * latency p50/p95 of the candidate (the FLOOR latency the SLM must beat).

Usage:
    python3 slm_eval.py --config <slm.config.yaml> --dataset <dataset_dir> [--out <report.json>]
"""

import argparse
import json
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_common as C  # noqa: E402


def _role(cfg_roles, role_id):
    for r in cfg_roles:
        if r.get("id") == role_id:
            return r
    return {}


def _first_tool(extract):
    reqs = extract.get("tool_requests") or []
    return reqs[0].get("tool", "") if reqs else ""


def _first_args(extract):
    reqs = extract.get("tool_requests") or []
    return reqs[0].get("arguments", {}) if reqs else {}


def _widget_types(render):
    return [w.get("widget_type") for w in render.get("widgets", [])]


def _default_dataset_dir(dom, cfg_dir):
    db = dom.get("dataset_build", {})
    out_dir = C.resolve(cfg_dir, db.get("output_dir", "datasets/build"))
    return os.path.join(out_dir, dom["name"], db.get("version", "v1"))


def evaluate(config_path, dataset_dir=None, out_override=None):
    cfg, cfg_dir = C.load_config(config_path)
    dom = cfg["slm_domain"]
    name = dom["name"]
    if not dataset_dir:
        dataset_dir = _default_dataset_dir(dom, cfg_dir)
    roles = dom.get("roles", [])
    eval_cfg = dom.get("eval", {})
    candidate = eval_cfg.get("candidate", "deterministic_oracle")

    extract_role = _role(roles, "extract")
    render_role = _role(roles, "render")
    extract_schema = C.resolve(cfg_dir, extract_role.get("output_schema"))
    widget_dir = C.resolve(cfg_dir, render_role.get("widget_schema_dir"))

    # vocabularies for the absolute vocab-validity metrics
    oracle_ref = extract_role.get("deterministic_oracle", {})
    oracle_module = C.resolve(cfg_dir, oracle_ref.get("module"))
    oracle = C.import_module_from_path(oracle_module)
    tool_vocab = set(getattr(oracle, "TOOL_VOCAB", []))
    intent_vocab = set(getattr(oracle, "RENDER_INTENT_VOCAB", []))
    run_fn = getattr(oracle, dom.get("dataset_build", {}).get("run_fn", "run_turn"))

    if candidate != "deterministic_oracle":
        raise SystemExit(
            "Phase A eval candidate=deterministic_oracle only; the SLM candidate "
            "lands once finetune/serve ship (gated on G1/G2/G3)."
        )

    eval_path = os.path.join(dataset_dir, "eval.jsonl")
    examples = C.read_jsonl(eval_path)

    tool_hits = arg_hits = slot_hits = intent_hits = wt_hits = 0
    ext_valid = 0
    tool_vocab_ok = intent_vocab_ok = 0
    total_env = valid_env = 0
    latencies = []
    by_intent = {}

    for exmpl in examples:
        turn = {
            "event_type": exmpl["input"]["event_type"],
            "event_payload": exmpl["input"]["event_payload"],
            "slot_state": exmpl["input"]["slot_state"],
        }
        label = exmpl["labels"]
        t0 = time.perf_counter()
        produced = run_fn(turn)
        latencies.append((time.perf_counter() - t0) * 1000.0)

        cand_ex, cand_rd = produced["extract"], produced["render"]
        lbl_ex, lbl_rd = label["extract"], label["render"]

        # match vs stored label (floor reproduction)
        if _first_tool(cand_ex) == _first_tool(lbl_ex):
            tool_hits += 1
        if _first_args(cand_ex) == _first_args(lbl_ex):
            arg_hits += 1
        if cand_ex.get("slot_updates") == lbl_ex.get("slot_updates"):
            slot_hits += 1
        cand_intent = cand_ex.get("render_intent", {}).get("kind")
        if cand_intent == lbl_ex.get("render_intent", {}).get("kind"):
            intent_hits += 1
        if _widget_types(cand_rd) == _widget_types(lbl_rd):
            wt_hits += 1

        # absolute validity
        if extract_schema and not C.validate_against_schema(cand_ex, extract_schema):
            ext_valid += 1
        ft = _first_tool(cand_ex)
        if not ft or ft in tool_vocab:
            tool_vocab_ok += 1
        if cand_intent in intent_vocab:
            intent_vocab_ok += 1
        if widget_dir:
            for w in cand_rd.get("widgets", []):
                total_env += 1
                if not C.validate_envelope(w, widget_dir):
                    valid_env += 1

        b = by_intent.setdefault(cand_intent, {"n": 0, "tool_hits": 0})
        b["n"] += 1
        if _first_tool(cand_ex) == _first_tool(lbl_ex):
            b["tool_hits"] += 1

    n = len(examples) or 1

    def pct(x):
        return round(x / n, 4)

    p50 = round(statistics.median(latencies), 3) if latencies else 0.0
    p95 = (
        round(statistics.quantiles(latencies, n=20)[18], 3)
        if len(latencies) >= 20
        else round(max(latencies), 3)
        if latencies
        else 0.0
    )

    computed = {
        "tool_match": pct(tool_hits),
        "arg_fidelity": pct(arg_hits),
        "slot_update_match": pct(slot_hits),
        "render_intent_match": pct(intent_hits),
        "widget_type_match": pct(wt_hits),
        "widget_schema_validity": round(valid_env / total_env, 4) if total_env else 1.0,
        "extract_schema_validity": pct(ext_valid),
        "tool_vocab_validity": pct(tool_vocab_ok),
        "render_intent_vocab_validity": pct(intent_vocab_ok),
        "output_validity": round(valid_env / total_env, 4) if total_env else 1.0,
    }

    # gate against config targets (numeric only)
    metric_targets = {}
    for m in eval_cfg.get("metrics", []):
        if "target" in m:
            metric_targets[m["id"]] = m["target"]
    gate_failures = []
    gated = {}
    for mid, target in metric_targets.items():
        val = computed.get(mid)
        if val is None:
            continue
        ok = val >= target
        gated[mid] = {"value": val, "target": target, "pass": ok}
        if not ok:
            gate_failures.append("%s=%.4f < target %.4f" % (mid, val, target))

    report = {
        "domain": name,
        "dataset_dir": dataset_dir,
        "candidate": candidate,
        "eval_count": len(examples),
        "metrics": computed,
        "gated_metrics": gated,
        "latency_ms": {"p50": p50, "p95": p95, "mean": round(statistics.mean(latencies), 3) if latencies else 0.0},
        "baseline": {
            "floor": {
                "source": eval_cfg.get("floor", "deterministic_oracle"),
                "note": "Candidate == deterministic oracle, so match-vs-floor == 1.0 by construction; this is the harness sanity check. The load-bearing Phase-A numbers are the absolute validity rates + the floor latency below.",
                "floor_latency_ms_p50": p50,
                "floor_latency_ms_p95": p95,
            },
            "ceiling": {
                "source": eval_cfg.get("ceiling", "teacher.primary"),
                "status": "deferred",
                "reason": "No teacher (OpenAI) labels on this set yet — needs teacher-token budget (RFC decision #6). Once enabled, ceiling = candidate-vs-teacher agreement.",
            },
        },
        "by_render_intent": by_intent,
        "gate": {"passed": len(gate_failures) == 0, "failures": gate_failures},
        "phase": "A — deterministic floor + harness validation; ceiling deferred",
    }

    out_path = out_override or os.path.join(dataset_dir, "eval_report.json")
    C.write_json(out_path, report)
    return report, out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--dataset", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    report, out_path = evaluate(args.config, args.dataset, args.out)
    print("=== eval complete ===")
    print("report:", out_path)
    print(json.dumps(report["metrics"], indent=2))
    print("latency_ms:", json.dumps(report["latency_ms"]))
    print("gate:", json.dumps(report["gate"]))


if __name__ == "__main__":
    main()
