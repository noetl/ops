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
import slm_teacher as T  # noqa: E402


def _role(cfg_roles, role_id):
    for r in cfg_roles:
        if r.get("id") == role_id:
            return r
    return {}


def _stable_bucket(key, seed):
    h = hashlib.sha256(("%s:%s" % (seed, key)).encode()).hexdigest()
    return int(h[:8], 16) / 0xFFFFFFFF


def _validate_labels(ex, rd, extract_schema, render_schema, widget_dir):
    """Validate one (extract, render) label pair. Returns a dict of counts +
    the per-example validity record."""
    ex_errs = C.validate_against_schema(ex, extract_schema) if extract_schema else []
    rd_errs = C.validate_against_schema(rd, render_schema) if render_schema else []
    widget_errs = []
    total_env = valid_env = 0
    if widget_dir:
        for w in rd.get("widgets", []):
            total_env += 1
            errs = C.validate_envelope(w, widget_dir)
            if errs:
                widget_errs.extend(errs)
            else:
                valid_env += 1
    return {
        "extract_schema": not ex_errs,
        "render_schema": not rd_errs,
        "widgets": len(widget_errs) == 0,
        "total_envelopes": total_env,
        "valid_envelopes": valid_env,
        "errors": (ex_errs + rd_errs + widget_errs)[:10],
    }


def build(config_path, out_override=None, corpus_override=None, version_override=None,
          limit=None, use_teacher=True, teacher_id=None):
    cfg, cfg_dir = C.load_config(config_path)
    dom = cfg["slm_domain"]
    name = dom["name"]
    roles = dom.get("roles", [])
    db = dom.get("dataset_build", {})
    data = dom.get("data", {})

    # label_source pins the FLOOR; the teacher block (if enabled) adds the
    # CEILING layer on top — it is not a label_source value.
    label_source = db.get("label_source", "deterministic_oracle")
    if label_source != "deterministic_oracle":
        raise SystemExit(
            "label_source=deterministic_oracle is the floor; the teacher is an "
            "additive ceiling layer (teachers[].status: enabled), not a "
            "label_source. Got label_source=%r." % label_source
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
    tool_summary_fn = getattr(oracle, "_tool_summary", None)

    extract_schema = C.resolve(cfg_dir, extract_role.get("output_schema"))
    render_schema = C.resolve(cfg_dir, render_role.get("output_schema"))
    widget_dir = C.resolve(cfg_dir, render_role.get("widget_schema_dir"))

    corpus_path = corpus_override or C.resolve(cfg_dir, data.get("seed_corpus"))
    turns = C.read_jsonl(corpus_path)
    if limit:
        turns = turns[: int(limit)]

    split = data.get("split", {})
    eval_ratio = float(split.get("eval_ratio", 0.3))
    seed = str(split.get("seed", 13))

    version = version_override or db.get("version", "v1")
    out_dir = out_override or C.resolve(cfg_dir, db.get("output_dir", "datasets/build"))
    ds_dir = os.path.join(out_dir, name, version)

    # ── teacher (ceiling) — optional, additive ──
    teacher = None
    teacher_msg = "teacher disabled (--no-teacher)"
    if use_teacher:
        teacher, teacher_msg = T.Teacher.from_config(cfg, cfg_dir, C, teacher_id=teacher_id)
    print("teacher: %s" % teacher_msg)
    teacher_errors = []

    examples = []
    by_intent = {}
    by_first_tool = {}
    widget_type_dist = {}
    n_ext_valid = n_rnd_valid = n_widgets_valid = n_with_widgets = 0
    total_envelopes = valid_envelopes = 0
    # teacher-side validity
    t_ext_valid = t_rnd_valid = t_widgets_valid = 0
    t_total_env = t_valid_env = 0
    n_teacher = 0

    for turn in turns:
        produced = run_fn(turn)
        ex = produced["extract"]
        rd = produced["render"]

        v = _validate_labels(ex, rd, extract_schema, render_schema, widget_dir)
        total_envelopes += v["total_envelopes"]
        valid_envelopes += v["valid_envelopes"]
        if v["extract_schema"]:
            n_ext_valid += 1
        if v["render_schema"]:
            n_rnd_valid += 1
        if v["widgets"]:
            n_widgets_valid += 1
        if rd.get("widgets"):
            n_with_widgets += 1

        # coverage stats (floor)
        intent = ex.get("render_intent", {}).get("kind", "?")
        by_intent[intent] = by_intent.get(intent, 0) + 1
        first_tool = (ex.get("tool_requests") or [{}])[0].get("tool", "") if ex.get("tool_requests") else ""
        first_tool = first_tool or "(none)"
        by_first_tool[first_tool] = by_first_tool.get(first_tool, 0) + 1
        for w in rd.get("widgets", []):
            wt = w.get("widget_type", "?")
            widget_type_dist[wt] = widget_type_dist.get(wt, 0) + 1

        example = {
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
                "extract_schema": v["extract_schema"],
                "render_schema": v["render_schema"],
                "widgets": v["widgets"],
                "errors": v["errors"],
            },
        }

        # ── teacher (ceiling) labels, additive ──
        if teacher is not None:
            try:
                tprod = teacher.label_turn(turn, tool_summary_fn=tool_summary_fn)
                tex, trd = tprod["extract"], tprod["render"]
                tv = _validate_labels(tex, trd, extract_schema, render_schema, widget_dir)
                t_total_env += tv["total_envelopes"]
                t_valid_env += tv["valid_envelopes"]
                if tv["extract_schema"]:
                    t_ext_valid += 1
                if tv["render_schema"]:
                    t_rnd_valid += 1
                if tv["widgets"]:
                    t_widgets_valid += 1
                n_teacher += 1
                example["labels_teacher"] = {"extract": tex, "render": trd}
                example["teacher_valid"] = {
                    "extract_schema": tv["extract_schema"],
                    "render_schema": tv["render_schema"],
                    "widgets": tv["widgets"],
                    "errors": tv["errors"],
                }
            except T.TeacherError as exc:
                teacher.usage["errors"] += 1
                teacher_errors.append("%s: %s" % (turn.get("id"), exc))
                example["teacher_error"] = str(exc)

        examples.append(example)

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
        "teacher": (
            {
                "enabled": True,
                "labeled": n_teacher,
                "errors": len(teacher_errors),
                "extract_model": teacher.extract_model,
                "render_model": teacher.render_model,
                "validity": {
                    "extract_schema_valid_rate": round(t_ext_valid / n, 4),
                    "render_schema_valid_rate": round(t_rnd_valid / n, 4),
                    "examples_all_widgets_valid_rate": round(t_widgets_valid / n, 4),
                    "widget_envelope_valid_rate": round(t_valid_env / t_total_env, 4) if t_total_env else 1.0,
                    "total_widget_envelopes": t_total_env,
                    "valid_widget_envelopes": t_valid_env,
                },
                "usage": teacher.usage,
                "error_samples": teacher_errors[:5],
            }
            if teacher is not None
            else {"enabled": False, "reason": teacher_msg}
        ),
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
    ap.add_argument("--corpus", default=None, help="override data.seed_corpus (e.g. a replay corpus)")
    ap.add_argument("--version", default=None, help="override dataset_build.version (dataset dir name)")
    ap.add_argument("--limit", type=int, default=None, help="cap number of turns labeled (token budget control)")
    ap.add_argument("--no-teacher", action="store_true", help="skip the teacher ceiling layer (floor only)")
    ap.add_argument("--teacher-id", default=None, help="select a specific teachers[].id")
    args = ap.parse_args()
    manifest, ds_dir = build(
        args.config,
        out_override=args.out,
        corpus_override=args.corpus,
        version_override=args.version,
        limit=args.limit,
        use_teacher=not args.no_teacher,
        teacher_id=args.teacher_id,
    )
    import json

    print("=== dataset_build complete ===")
    print("dataset dir:", ds_dir)
    print(json.dumps(manifest["counts"], indent=2))
    print(json.dumps(manifest["validity"], indent=2))
    if manifest.get("teacher", {}).get("enabled"):
        t = manifest["teacher"]
        print("teacher labeled:", t["labeled"], "errors:", t["errors"])
        print("teacher validity:", json.dumps(t["validity"]))
        print("teacher usage:", json.dumps(t["usage"]))


if __name__ == "__main__":
    main()
