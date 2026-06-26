"""Generic SLM dataset_build engine.

Domain-agnostic.  Driven entirely by an org ``slm.config.yaml``:

  * loads the seed corpus (``data.seed_corpus``),
  * runs each turn through the configured label source (Phase A: the
    deterministic oracle named in ``roles[].deterministic_oracle``; a teacher
    HTTP source is pluggable later — RFC decision #6),
  * schema-validates each label (extract output, render output, and every
    widget envelope against the configured ``widget_schema_dir``),
  * splits train/eval deterministically,
  * writes versioned ``train.jsonl`` / ``eval.jsonl`` + a ``manifest.json``
    (the dataset-registry stub — G3 turns this into a real catalog resource).

No travel-specific code lives here.  A second domain runs this unchanged by
supplying its own config + oracle module + corpus + schemas.

Usage:
    python3 slm_dataset_build.py --config <path/to/slm.config.yaml> [--out <dir>]
"""

import argparse
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_common as C  # noqa: E402


def _role(cfg_roles, role_id):
    for r in cfg_roles:
        if r.get("id") == role_id:
            return r
    return {}


def _stable_bucket(key, seed):
    h = hashlib.sha256(("%s:%s" % (seed, key)).encode()).hexdigest()
    return int(h[:8], 16) / 0xFFFFFFFF


def build(config_path, out_override=None):
    cfg, cfg_dir = C.load_config(config_path)
    dom = cfg["slm_domain"]
    name = dom["name"]
    roles = dom.get("roles", [])
    db = dom.get("dataset_build", {})
    data = dom.get("data", {})

    label_source = db.get("label_source", "deterministic_oracle")
    if label_source != "deterministic_oracle":
        raise SystemExit(
            "Phase A supports label_source=deterministic_oracle only; "
            "teacher source is gated on RFC decision #6 (teacher budget)."
        )

    extract_role = _role(roles, "extract")
    render_role = _role(roles, "render")

    # the shared oracle module (referenced via the role's deterministic_oracle)
    oracle_ref = extract_role.get("deterministic_oracle", {})
    oracle_module = C.resolve(cfg_dir, oracle_ref.get("module"))
    if not oracle_module or not os.path.exists(oracle_module):
        raise SystemExit("oracle module not found: %s" % oracle_module)
    oracle = C.import_module_from_path(oracle_module)
    run_fn = getattr(oracle, db.get("run_fn", "run_turn"))

    extract_schema = C.resolve(cfg_dir, extract_role.get("output_schema"))
    render_schema = C.resolve(cfg_dir, render_role.get("output_schema"))
    widget_dir = C.resolve(cfg_dir, render_role.get("widget_schema_dir"))

    corpus_path = C.resolve(cfg_dir, data.get("seed_corpus"))
    turns = C.read_jsonl(corpus_path)

    split = data.get("split", {})
    eval_ratio = float(split.get("eval_ratio", 0.3))
    seed = str(split.get("seed", 13))

    version = db.get("version", "v1")
    out_dir = out_override or C.resolve(cfg_dir, db.get("output_dir", "datasets/build"))
    ds_dir = os.path.join(out_dir, name, version)

    examples = []
    by_intent = {}
    by_first_tool = {}
    widget_type_dist = {}
    n_ext_valid = n_rnd_valid = n_widgets_valid = n_with_widgets = 0
    total_envelopes = valid_envelopes = 0

    for turn in turns:
        produced = run_fn(turn)
        ex = produced["extract"]
        rd = produced["render"]

        ex_errs = C.validate_against_schema(ex, extract_schema) if extract_schema else []
        rd_errs = C.validate_against_schema(rd, render_schema) if render_schema else []

        widget_errs = []
        if widget_dir:
            for w in rd.get("widgets", []):
                total_envelopes += 1
                errs = C.validate_envelope(w, widget_dir)
                if errs:
                    widget_errs.extend(errs)
                else:
                    valid_envelopes += 1

        widgets_ok = len(widget_errs) == 0
        if not ex_errs:
            n_ext_valid += 1
        if not rd_errs:
            n_rnd_valid += 1
        if widgets_ok:
            n_widgets_valid += 1
        if rd.get("widgets"):
            n_with_widgets += 1

        # coverage stats
        intent = ex.get("render_intent", {}).get("kind", "?")
        by_intent[intent] = by_intent.get(intent, 0) + 1
        first_tool = (ex.get("tool_requests") or [{}])[0].get("tool", "") if ex.get("tool_requests") else ""
        first_tool = first_tool or "(none)"
        by_first_tool[first_tool] = by_first_tool.get(first_tool, 0) + 1
        for w in rd.get("widgets", []):
            wt = w.get("widget_type", "?")
            widget_type_dist[wt] = widget_type_dist.get(wt, 0) + 1

        examples.append(
            {
                "id": turn.get("id"),
                "intent_label": turn.get("intent_label"),
                "input": {
                    "event_type": turn.get("event_type"),
                    "event_payload": turn.get("event_payload"),
                    "slot_state": turn.get("slot_state", {}),
                    "thread_context": turn.get("thread_context", []),
                },
                "labels": {"extract": ex, "render": rd},
                "label_source": label_source,
                "valid": {
                    "extract_schema": not ex_errs,
                    "render_schema": not rd_errs,
                    "widgets": widgets_ok,
                    "errors": (ex_errs + rd_errs + widget_errs)[:10],
                },
            }
        )

    # deterministic split by stable hash of id
    train, ev = [], []
    for exmpl in examples:
        bucket = _stable_bucket(str(exmpl["id"]), seed)
        (ev if bucket < eval_ratio else train).append(exmpl)

    n = len(examples) or 1
    manifest = {
        "domain": name,
        "version": version,
        "label_source": label_source,
        "created_from": os.path.relpath(corpus_path, cfg_dir),
        "split": {"eval_ratio": eval_ratio, "seed": seed},
        "counts": {
            "total": len(examples),
            "train": len(train),
            "eval": len(ev),
            "with_widgets": n_with_widgets,
            "by_render_intent": by_intent,
            "by_first_tool": by_first_tool,
            "widget_type_distribution": widget_type_dist,
        },
        "validity": {
            "extract_schema_valid_rate": round(n_ext_valid / n, 4),
            "render_schema_valid_rate": round(n_rnd_valid / n, 4),
            "examples_all_widgets_valid_rate": round(n_widgets_valid / n, 4),
            "widget_envelope_valid_rate": round(valid_envelopes / total_envelopes, 4) if total_envelopes else 1.0,
            "total_widget_envelopes": total_envelopes,
            "valid_widget_envelopes": valid_envelopes,
        },
        "schemas": {
            "extract": os.path.relpath(extract_schema, cfg_dir) if extract_schema else None,
            "render": os.path.relpath(render_schema, cfg_dir) if render_schema else None,
            "widget_schema_dir": os.path.relpath(widget_dir, cfg_dir) if widget_dir else None,
        },
        "files": {
            "train": os.path.join(ds_dir, "train.jsonl"),
            "eval": os.path.join(ds_dir, "eval.jsonl"),
        },
        "registry_stub": {
            "kind": "dataset",
            "namespace": dom.get("improvement", {}).get("governance", {}).get(
                "registry_namespace", name
            ),
            "urn": "noetl://%s/datasets/%s" % (name, version),
            "note": "Stub only — a real versioned registry entry lands with platform foundation G3 (noetl/ai-meta#146).",
        },
    }

    C.write_jsonl(manifest["files"]["train"], train)
    C.write_jsonl(manifest["files"]["eval"], ev)
    C.write_json(os.path.join(ds_dir, "manifest.json"), manifest)

    return manifest, ds_dir


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    manifest, ds_dir = build(args.config, args.out)
    import json

    print("=== dataset_build complete ===")
    print("dataset dir:", ds_dir)
    print(json.dumps(manifest["counts"], indent=2))
    print(json.dumps(manifest["validity"], indent=2))


if __name__ == "__main__":
    main()
