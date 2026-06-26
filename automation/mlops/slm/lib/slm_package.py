"""Generic SLM package engine — Phase B (noetl/ai-meta#141).

The thin packaging stage that turns a *trained + evaluated* model into a
serving-ready **release**: it pulls the registered model artifact + its eval
run from the G3 registry, (for the real LoRA path) merges/exports the adapter,
writes a **model card** (markdown, metrics included), bundles everything into a
release tarball, and registers a G3 release entry (kind=release, lineage →
[model, eval]).

Domain-agnostic: the only inputs are the org ``slm.config.yaml`` (for the
registry namespace + serving target) and the registry refs of the model + eval.

Stub vs peft:
  * ``stub``  — the artifact is self-contained (the retrieval store); "export"
                is a repack with the model card + eval report. Runs on CPU,
                proves the release mechanics end-to-end.
  * ``peft``  — merge the LoRA adapter into the base weights
                (``merge_and_unload``) and export, optionally quantize to the
                serving target (gguf, per config ``serving``). Import-guarded;
                runs in the GPU/serving image only.

Usage::

    python3 slm_package.py --config <slm.config.yaml> [--model-ref <urn|latest>]
        [--eval-ref <urn|latest>] [--out <release_dir>] [--no-register]
"""

import argparse
import json
import os
import sys
import tarfile
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_common as C  # noqa: E402
import slm_infer as INFER  # noqa: E402


def _registry_namespace(dom):
    ns = dom.get("improvement", {}).get("governance", {}).get("registry_namespace", "default/default")
    t, _, p = ns.partition("/")
    return (t or "default"), (p or dom["name"])


def _resolve_latest(client, kind, name, tenant, project, ref):
    if ref and ref not in ("latest", ""):
        return client.resolve(ref, tenant=tenant, project=project)
    entries = client.list(kind=kind, name=name, tenant=tenant, project=project, limit=1)
    return entries[0] if entries else None


def _model_card(dom, model_entry, eval_entry, release_meta):
    """Render the model card markdown.  Metrics + gate come from the eval entry's
    metadata so the card never drifts from the scored numbers."""
    name = dom["name"]
    em = (eval_entry or {}).get("metadata", {}) if eval_entry else {}
    metrics = em.get("metrics", {})
    gate = em.get("gate", {})
    latency = em.get("latency_ms", {})
    mm = model_entry.get("metadata", {})
    lines = []
    lines.append("# Model card — %s SLM (multitask)" % name)
    lines.append("")
    lines.append("- **Release**: `%s`" % release_meta.get("release_ref", "(unregistered)"))
    lines.append("- **Model**: `%s` (registry v%s)" % (model_entry.get("ref"), model_entry.get("version")))
    lines.append("- **Eval**: `%s`" % ((eval_entry or {}).get("ref", "(none)")))
    lines.append("- **Backend / recipe**: %s / %s" % (mm.get("backend"), mm.get("recipe")))
    lines.append("- **Base model**: `%s`" % mm.get("base_model"))
    lines.append("- **Role layout**: %s (single multitask LoRA: extract + render)" % mm.get("role_layout"))
    lines.append("- **Decoding**: JSON-schema / grammar-constrained (the Phase-1 lever)")
    lines.append("- **Lineage**: dataset → model → eval → release")
    lines.append("")
    lines.append("## Intended use")
    lines.append("")
    lines.append("Drop-in for the %s domain's intent-extraction + widget-render passes "
                 "(the two LLM calls the consuming playbook declares). Serving target: "
                 "`%s`." % (name, dom.get("serving", {}).get("target", "cpu")))
    lines.append("")
    lines.append("## Eval metrics (vs the deterministic oracle floor)")
    lines.append("")
    if metrics:
        lines.append("| metric | value |")
        lines.append("| :-- | --: |")
        for k in ("widget_schema_validity", "extract_schema_validity", "tool_vocab_validity",
                  "render_intent_vocab_validity", "tool_match", "render_intent_match",
                  "widget_type_match", "arg_fidelity", "slot_update_match"):
            if k in metrics:
                lines.append("| %s | %.4f |" % (k, metrics[k]))
        lines.append("")
        lines.append("- **Gate**: %s%s" % (
            "PASS" if gate.get("passed") else "FAIL",
            "" if gate.get("passed") else " — " + "; ".join(gate.get("failures", []))))
        lines.append("- **Floor target**: schema validity 1.0 (widget + extract). "
                     "The release holds the floor when both validity rows are 1.0000.")
        lines.append("- **Candidate latency**: p50 %s ms / p95 %s ms"
                     % (latency.get("p50"), latency.get("p95")))
    else:
        lines.append("_No eval metrics found on the registered eval entry._")
    lines.append("")
    lines.append("## Limitations")
    lines.append("")
    if mm.get("backend") == "stub":
        lines.append("- This is the **stub / retrieval** validation backend (CPU, no GPU). "
                     "It proves the dataset → finetune → registry → eval → release mechanics; "
                     "it is **not** a real fine-tuned LoRA. The production release is the "
                     "`peft` backend trained on a GPU node pool.")
    lines.append("- Trained on the Phase-1 seed dataset (small, synthetic + replay-augmented). "
                 "Coverage is bounded by the seed corpus; out-of-distribution turns fall back to "
                 "schema-constrained safe outputs.")
    lines.append("- Constrained decoding guarantees *schema validity*, not *semantic correctness* — "
                 "an in-vocab but wrong tool/intent is still possible; the match metrics above bound that.")
    lines.append("")
    lines.append("_Generated by `slm_package.py` on unix %d._" % release_meta.get("created_unix", 0))
    return "\n".join(lines) + "\n"


def _export_model_artifact(client, model_entry, work_dir):
    """Pull the model artifact and (peft) merge the adapter for serving.  Returns
    the path to the exported model dir."""
    key = model_entry.get("artifact_uri")
    data = client.get_artifact(key)
    tar_path = os.path.join(work_dir, "model.tar.gz")
    with open(tar_path, "wb") as fh:
        fh.write(data)
    model_dir = INFER.load_artifact_dir(tar_path)
    backend = model_entry.get("metadata", {}).get("backend", "stub")
    if backend == "peft":  # pragma: no cover - GPU/serving only
        _merge_peft_adapter(model_dir)
    return model_dir, tar_path, backend


def _merge_peft_adapter(model_dir):  # pragma: no cover - GPU/serving only
    """Merge the LoRA adapter into base weights for a standalone serving model."""
    try:
        from peft import PeftModel
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except Exception as exc:
        raise RuntimeError("peft export needs torch + transformers + peft: %s" % exc)
    with open(os.path.join(model_dir, INFER.MANIFEST_NAME)) as fh:
        manifest = json.load(fh)
    base = manifest["base_model"]
    model = AutoModelForCausalLM.from_pretrained(base)
    model = PeftModel.from_pretrained(model, os.path.join(model_dir, "adapter"))
    merged = model.merge_and_unload()
    out = os.path.join(model_dir, "merged")
    merged.save_pretrained(out)
    AutoTokenizer.from_pretrained(
        os.path.join(model_dir, "tokenizer") if os.path.isdir(os.path.join(model_dir, "tokenizer")) else base
    ).save_pretrained(out)
    return out


def package(config_path, *, model_ref=None, eval_ref=None, out_dir=None,
            register=True, tenant=None, project=None, release_name=None):
    cfg, cfg_dir = C.load_config(config_path)
    dom = cfg["slm_domain"]
    name = dom["name"]
    t, p = _registry_namespace(dom)
    tenant = tenant or t
    project = project or p
    model_name = "%s_slm_multitask" % name
    release_name = release_name or model_name

    import slm_registry as REG
    client = REG.make_client()

    model_entry = _resolve_latest(client, "model", model_name, tenant, project, model_ref)
    if not model_entry:
        raise SystemExit("no model entry to package (name=%s tenant=%s project=%s)" % (model_name, tenant, project))
    eval_entry = _resolve_latest(client, "eval", model_name, tenant, project, eval_ref)

    work = out_dir or tempfile.mkdtemp(prefix="slm_release_")
    os.makedirs(work, exist_ok=True)
    model_dir, model_tar, backend = _export_model_artifact(client, model_entry, work)

    release_meta = {
        "domain": name, "backend": backend, "created_unix": int(time.time()),
        "model_ref": model_entry["ref"], "eval_ref": (eval_entry or {}).get("ref"),
        "serving": dom.get("serving", {}),
    }
    card = _model_card(dom, model_entry, eval_entry, release_meta)
    card_path = os.path.join(work, "MODEL_CARD.md")
    with open(card_path, "w") as fh:
        fh.write(card)

    release_json_path = os.path.join(work, "release.json")
    with open(release_json_path, "w") as fh:
        json.dump(release_meta, fh, indent=2, sort_keys=True)

    # bundle: model.tar.gz + model card + eval report + release.json
    bundle_path = os.path.join(work, "%s_release.tar.gz" % name)
    with tarfile.open(bundle_path, "w:gz") as tf:
        tf.add(model_tar, arcname="model.tar.gz")
        tf.add(card_path, arcname="MODEL_CARD.md")
        tf.add(release_json_path, arcname="release.json")
        if eval_entry:
            ev_path = os.path.join(work, "eval_report.json")
            with open(ev_path, "wb") as fh:
                fh.write(client.get_artifact(eval_entry["artifact_uri"]))
            tf.add(ev_path, arcname="eval_report.json")

    result = {
        "domain": name, "backend": backend, "release_bundle": bundle_path,
        "model_card": card_path, "model_ref": model_entry["ref"],
        "eval_ref": (eval_entry or {}).get("ref"), "registry": None,
    }

    if register:
        with open(bundle_path, "rb") as fh:
            bundle_bytes = fh.read()
        lineage = [model_entry["ref"]]
        if eval_entry:
            lineage.append(eval_entry["ref"])
        entry = client.put_and_register(
            "release", release_name, "%s_release.tar.gz" % name, bundle_bytes,
            media_type="application/gzip",
            metadata={"backend": backend, "serving": dom.get("serving", {}),
                      "model_ref": model_entry["ref"], "eval_ref": (eval_entry or {}).get("ref"),
                      "eval_metrics": (eval_entry or {}).get("metadata", {}).get("metrics"),
                      "gate": (eval_entry or {}).get("metadata", {}).get("gate")},
            lineage=lineage, tags=["slm", name, "release", backend],
            tenant=tenant, project=project)
        release_meta["release_ref"] = entry["ref"]
        # rewrite the card with the now-known release ref
        with open(card_path, "w") as fh:
            fh.write(_model_card(dom, model_entry, eval_entry, release_meta))
        result["registry"] = {"release_ref": entry["ref"], "version": entry["version"],
                              "lineage": lineage, "tenant": tenant, "project": project}

    if out_dir:
        C.write_json(os.path.join(out_dir, "package_report.json"), result)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--model-ref", default=None)
    ap.add_argument("--eval-ref", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--release-name", default=None)
    ap.add_argument("--no-register", action="store_true")
    ap.add_argument("--tenant", default=None)
    ap.add_argument("--project", default=None)
    args = ap.parse_args()
    result = package(args.config, model_ref=args.model_ref, eval_ref=args.eval_ref,
                     out_dir=args.out, register=not args.no_register,
                     tenant=args.tenant, project=args.project, release_name=args.release_name)
    print("=== package complete ===")
    print("bundle:", result["release_bundle"])
    print("model_card:", result["model_card"])
    print("registry:", json.dumps(result["registry"]))


if __name__ == "__main__":
    main()
