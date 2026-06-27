"""Host-side shadow validation harness — RFC Option A, proof (a).

Drives the ``slm_serve`` endpoint over a set of real turns, runs the
deterministic oracle (the LIVE path == the labeler, RFC §1.2) for each turn,
computes per-field agreement + schema validity + latency with ``slm_shadow``
(the same engine the planner's ``log_shadow_comparison`` step uses inline), and
writes the shadow-comparison records to a JSONL sink.

This is the off-cluster twin of the in-planner shadow branch: the oracle stands
in for ``extract_turn`` / ``render_widget_chat`` (it IS the code those steps
run), and the endpoint stands in for the SLM call.  The records it writes are
the data-flywheel capture objects — feed them to ``slm_replay --shadow`` →
``dataset_build`` to turn shadow traffic into training data (proof (c)).

The SLM output is recorded, never chosen — exactly the shadow invariant.

Run:
    python3 lib/slm_shadow_validate.py \
        --config <slm.config.yaml> --endpoint http://localhost:8099 \
        --eval <.../v3/eval.jsonl> --n 12 --out shadow_corpus.jsonl
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_common as C  # noqa: E402
import slm_shadow as SH  # noqa: E402
import slm_replay as REPLAY  # noqa: E402


def _load_turns(eval_path, seed_path, n):
    if eval_path and os.path.isfile(eval_path):
        rows = C.read_jsonl(eval_path)
        turns = []
        for r in rows[:n]:
            inp = r.get("input", {})
            turns.append({
                "id": r.get("id"),
                "event_type": inp.get("event_type"),
                "event_payload": inp.get("event_payload"),
                "slot_state": inp.get("slot_state"),
                "tool_summary": inp.get("tool_summary"),
            })
        return turns
    rows = C.read_jsonl(seed_path)
    return [{
        "id": r.get("id"),
        "event_type": r.get("event_type"),
        "event_payload": r.get("event_payload"),
        "slot_state": r.get("slot_state"),
        "tool_summary": None,
    } for r in rows[:n]]


def validate(config_path, endpoint, *, eval_path=None, seed_path=None, n=12,
             out_path="shadow_corpus.jsonl", tenant_tag="muno/slm/shadow-validate",
             timeout_ms=120000):
    cfg, cfg_dir = C.load_config(config_path)
    dom = cfg["slm_domain"]
    extract_role = next((r for r in dom.get("roles", []) if r.get("id") == "extract"), {})
    oracle = C.import_module_from_path(C.resolve(cfg_dir, extract_role.get("deterministic_oracle", {}).get("module")))
    run_fn = getattr(oracle, dom.get("dataset_build", {}).get("run_fn", "run_turn"))

    client = SH.ShadowClient(endpoint, timeout_ms=timeout_ms)
    health = client.healthz()
    print("endpoint:", json.dumps(health), file=sys.stderr)

    turns = _load_turns(eval_path, seed_path, n)
    records = []
    for i, turn in enumerate(turns):
        # LIVE path (what the planner serves) = the deterministic oracle.
        live = run_fn(turn)
        live_extract, live_render = live["extract"], live["render"]

        # SHADOW path = the SLM, end-to-end (render conditions on the SLM extract,
        # mirroring SlmRunner.run_turn).  Any endpoint error → fell_back, logged.
        slm_extract = slm_render = None
        ex_lat = rd_lat = None
        sv = {}
        fell_back = False
        err = None
        try:
            er = client.extract(turn)
            slm_extract, ex_lat, sv["extract"] = er["extract"], er["latency_ms"], er["schema_valid"]
            rr = client.render(turn, slm_extract)
            slm_render, rd_lat, sv["render"] = rr["render"], rr["latency_ms"], rr["schema_valid"]
        except Exception as exc:  # endpoint down / timeout / decode
            fell_back = True
            err = "%s: %s" % (type(exc).__name__, exc)

        # redact the captured turn (flywheel safety — same redactor as replay)
        red_turn = dict(turn)
        red_turn["event_payload"] = REPLAY.redact_payload(turn.get("event_payload"))

        rec = SH.build_record(
            red_turn, live_extract, live_render, slm_extract, slm_render,
            schema_valid=sv, slm_extract_latency_ms=ex_lat, slm_render_latency_ms=rd_lat,
            fell_back=fell_back, error=err)
        rec["id"] = turn.get("id")
        rec["tenant_tag"] = tenant_tag
        rec["source"] = "shadow_validate"
        records.append(rec)
        a = rec["agreement"]
        print("[%2d/%d] %-30s tool=%s intent=%s widget=%s%s" % (
            i + 1, len(turns), str(turn.get("id"))[:30],
            a.get("tool_match"), a.get("render_intent_match"), a.get("widget_type_match"),
            " FELL_BACK" if fell_back else ""), file=sys.stderr)

    C.write_jsonl(out_path, records)
    summary = SH.agreement_summary(records)
    summary["out"] = out_path
    summary["tenant_tag"] = tenant_tag
    summary["endpoint"] = health
    return summary, records


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--endpoint", default="http://localhost:8099")
    ap.add_argument("--eval", dest="eval_path", default=None)
    ap.add_argument("--seed", dest="seed_path", default=None)
    ap.add_argument("--n", type=int, default=12)
    ap.add_argument("--out", default="shadow_corpus.jsonl")
    ap.add_argument("--tenant-tag", default="muno/slm/shadow-validate")
    ap.add_argument("--timeout-ms", type=int, default=120000)
    args = ap.parse_args()
    summary, _ = validate(
        args.config, args.endpoint, eval_path=args.eval_path, seed_path=args.seed_path,
        n=args.n, out_path=args.out, tenant_tag=args.tenant_tag, timeout_ms=args.timeout_ms)
    print("=== shadow validation complete ===")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
