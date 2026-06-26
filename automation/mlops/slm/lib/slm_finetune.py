"""Generic SLM finetune engine — Phase B (noetl/ai-meta#141).

Reads the Phase-1 dataset (train split) for a domain, builds the **multitask**
training set (the two roles the contract declares — ``extract`` and ``render`` —
flattened into one instruction-tuning corpus), trains a **single multitask
LoRA**, writes the adapter as a model artifact, and registers it into the G3
registry (kind=model, lineage → the dataset entry).

Domain-agnostic: everything travel-specific arrives through the org
``slm.config.yaml`` (the ``model`` block: base family/size, candidates, recipe,
role layout) + the dataset the org's ``dataset_build`` produced.

Two backends share one artifact contract (see ``slm_infer``):

  * ``stub``  — pure-stdlib CPU "training": builds the nearest-prototype
                retrieval store from the multitask examples.  This is the
                Phase-B **validation** backend — it makes the whole orchestration
                (dataset → finetune → registry → eval → release) runnable on
                kind / CPU with zero heavy deps and no GPU, exactly the
                "tiny/dummy model" the task calls for.  Real, deterministic, and
                schema-constrained at decode time.
  * ``peft``  — the real LoRA fine-tune of qwen2.5-1.5b-instruct (fallback
                llama-3.2-1b-instruct) via PEFT/transformers.  Import-guarded:
                absent torch/transformers/peft it raises a precise "GPU training
                runtime not installed" error.  This is what runs inside the G1
                container/GPU Job; the worker frees its slot via G2 poll while it
                runs.

Usage::

    python3 slm_finetune.py --config <slm.config.yaml> [--backend stub|peft]
        [--dataset <dir>] [--base-model <id>] [--out <artifact_dir>]
        [--augment-teacher] [--max-steps N] [--epochs N] [--no-register]

The registry write is server-mediated (data-access-boundary.md) via
``slm_registry``; pass ``NOETL_REGISTRY_BACKEND=local`` for the offline smoke.
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_common as C  # noqa: E402
import slm_infer as INFER  # noqa: E402


# ── multitask example construction ──────────────────────────────────────────

def _read_text(path):
    if path and os.path.isfile(path):
        with open(path) as fh:
            return fh.read()
    return ""


def build_multitask_examples(records, *, label_field="labels", include_teacher=False):
    """Flatten dataset records into the multitask instruction corpus.

    For every record we emit two task examples — one per role — so a *single*
    LoRA learns both passes (``role_layout: single_multitask``).  The
    authoritative target is the oracle label (``labels``); the constrained
    teacher (``labels_teacher_repaired``) is optional augmentation (it was
    already validated + repaired toward the contract in dataset_build).
    """
    examples = []
    for rec in records:
        turn = {
            "event_type": rec["input"]["event_type"],
            "event_payload": rec["input"]["event_payload"],
            "slot_state": rec["input"]["slot_state"],
        }
        sources = [(label_field, rec.get(label_field))]
        if include_teacher and rec.get("labels_teacher_repaired"):
            sources.append(("labels_teacher_repaired", rec["labels_teacher_repaired"]))
        for src_name, labels in sources:
            if not labels:
                continue
            examples.append({
                "id": rec.get("id"),
                "role": "extract",
                "label_source": src_name,
                "turn": turn,
                "target": labels.get("extract", {}),
            })
            examples.append({
                "id": rec.get("id"),
                "role": "render",
                "label_source": src_name,
                "turn": turn,
                "extraction": labels.get("extract", {}),
                "target": labels.get("render", {}),
            })
    return examples


# ── backends ─────────────────────────────────────────────────────────────────

def _train_stub(records, artifact_dir, manifest, *, include_teacher):
    """Build the retrieval store: one prototype per *training record* carrying
    its featurized input + both role targets.  (The multitask split is implicit
    — a prototype holds extract AND render, the runner reads whichever the eval
    asks for.)"""
    protos = []
    for rec in records:
        turn = {
            "event_type": rec["input"]["event_type"],
            "event_payload": rec["input"]["event_payload"],
            "slot_state": rec["input"]["slot_state"],
        }
        labels = rec.get("labels", {})
        protos.append({
            "id": rec.get("id"),
            "label_source": "labels",
            "features": INFER.featurize(turn),
            "extract": labels.get("extract", {}),
            "render": labels.get("render", {}),
        })
        if include_teacher and rec.get("labels_teacher_repaired"):
            tl = rec["labels_teacher_repaired"]
            protos.append({
                "id": rec.get("id"),
                "label_source": "labels_teacher_repaired",
                "features": INFER.featurize(turn),
                "extract": tl.get("extract", {}),
                "render": tl.get("render", {}),
            })
    C.write_jsonl(os.path.join(artifact_dir, INFER.PROTOTYPES_NAME), protos)
    manifest["train"] = {
        "backend": "stub",
        "prototype_count": len(protos),
        "recipe": "retrieval-prototype",
        "note": "CPU/offline validation backend — nearest-prototype retrieval "
                "with schema-constrained decoding. Mechanics-equivalent to the "
                "peft path for orchestration; not a real LoRA fine-tune.",
    }
    return manifest


def _train_peft(examples, artifact_dir, manifest, *, base_model, max_steps,
                epochs, lora_r, lora_alpha, lora_dropout, learning_rate):  # pragma: no cover
    """Real multitask LoRA fine-tune.  Only runs where the GPU training deps are
    installed (the G1 container image); import-guarded so the CPU smoke never
    pulls torch."""
    try:
        import torch  # noqa: F401
        from datasets import Dataset
        from peft import LoraConfig, get_peft_model
        from transformers import (AutoModelForCausalLM, AutoTokenizer,
                                   DataCollatorForLanguageModeling, Trainer,
                                   TrainingArguments)
    except Exception as exc:
        raise RuntimeError(
            "peft backend needs torch + transformers + peft + datasets (the GPU "
            "training runtime). Run --backend stub for the CPU smoke. Import "
            "error: %s" % exc)

    sysp = manifest.get("prompts", {})
    tokenizer = AutoTokenizer.from_pretrained(base_model)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    def render_prompt(ex):
        if ex["role"] == "extract":
            head = sysp.get("extract", "")
            body = {"turn": ex["turn"]}
        else:
            head = sysp.get("render", "")
            body = {"turn": ex["turn"], "extraction": ex["extraction"]}
        prompt = "%s\n\n### INPUT\n%s\n\n### OUTPUT (JSON)\n" % (head, json.dumps(body, sort_keys=True))
        completion = json.dumps(ex["target"], sort_keys=True) + tokenizer.eos_token
        full = prompt + completion
        toks = tokenizer(full, truncation=True, max_length=2048)
        return {"input_ids": toks["input_ids"], "attention_mask": toks["attention_mask"]}

    ds = Dataset.from_list([render_prompt(e) for e in examples])
    model = AutoModelForCausalLM.from_pretrained(base_model)
    peft_cfg = LoraConfig(
        r=lora_r, lora_alpha=lora_alpha, lora_dropout=lora_dropout,
        target_modules=["q_proj", "v_proj", "k_proj", "o_proj"],
        task_type="CAUSAL_LM",
    )
    model = get_peft_model(model, peft_cfg)
    args = TrainingArguments(
        output_dir=os.path.join(artifact_dir, "_trainer"),
        per_device_train_batch_size=1,
        gradient_accumulation_steps=8,
        num_train_epochs=epochs,
        max_steps=max_steps if max_steps and max_steps > 0 else -1,
        learning_rate=learning_rate,
        logging_steps=1,
        save_strategy="no",
        report_to=[],
    )
    collator = DataCollatorForLanguageModeling(tokenizer, mlm=False)
    trainer = Trainer(model=model, args=args, train_dataset=ds, data_collator=collator)
    train_result = trainer.train()
    model.save_pretrained(os.path.join(artifact_dir, "adapter"))
    tokenizer.save_pretrained(os.path.join(artifact_dir, "tokenizer"))
    manifest["train"] = {
        "backend": "peft",
        "recipe": "lora",
        "base_model": base_model,
        "lora": {"r": lora_r, "alpha": lora_alpha, "dropout": lora_dropout},
        "epochs": epochs,
        "max_steps": max_steps,
        "learning_rate": learning_rate,
        "example_count": len(examples),
        "train_loss": float(getattr(train_result, "training_loss", 0.0) or 0.0),
    }
    return manifest


# ── dataset lineage helper ──────────────────────────────────────────────────

def ensure_dataset_registered(client, *, name, dataset_dir, manifest_path, tenant, project):
    """Return the registry ref of the dataset entry for lineage.  Reuses the
    newest existing entry for ``name``; registers one from the dataset manifest
    if none exists yet (Phase A only wrote a local stub manifest)."""
    if client is None:
        return None
    existing = client.list(kind="dataset", name=name, tenant=tenant, project=project, limit=1)
    if existing:
        return existing[0]["ref"]
    with open(manifest_path) as fh:
        ds_manifest = json.load(fh)
    entry = client.register(
        "dataset", name,
        metadata={"manifest": ds_manifest, "dataset_dir": dataset_dir,
                  "registered_by": "slm_finetune"},
        tenant=tenant, project=project,
        tags=["slm", ds_manifest.get("domain", ""), ds_manifest.get("version", "")],
    )
    return entry["ref"]


# ── driver ───────────────────────────────────────────────────────────────────

def _default_dataset_dir(dom, cfg_dir):
    db = dom.get("dataset_build", {})
    out_dir = C.resolve(cfg_dir, db.get("output_dir", "datasets/build"))
    version = os.environ.get("SLM_DATASET_VERSION") or db.get("version", "v1")
    return os.path.join(out_dir, dom["name"], version)


def _registry_client():
    """Build a registry client (server or local backend); None if unconfigured
    and --no-register implied."""
    try:
        import slm_registry as REG
    except Exception:
        return None
    try:
        return REG.make_client()
    except Exception as exc:
        print("registry client unavailable (%s) — continuing without registration" % exc, file=sys.stderr)
        return None


def finetune(config_path, *, backend=None, dataset_dir=None, base_model=None,
             out_dir=None, augment_teacher=False, max_steps=2, epochs=1,
             lora_r=8, lora_alpha=16, lora_dropout=0.05, learning_rate=2e-4,
             register=True, model_name=None, tenant=None, project=None):
    cfg, cfg_dir = C.load_config(config_path)
    dom = cfg["slm_domain"]
    name = dom["name"]
    model_cfg = dom.get("model", {})
    gov = dom.get("improvement", {}).get("governance", {})
    ns = gov.get("registry_namespace", "default/default")
    ns_tenant, _, ns_project = ns.partition("/")
    tenant = tenant or ns_tenant or "default"
    project = project or ns_project or name
    model_name = model_name or "%s_slm_multitask" % name

    if not dataset_dir:
        dataset_dir = _default_dataset_dir(dom, cfg_dir)
    train_path = os.path.join(dataset_dir, "train.jsonl")
    manifest_path = os.path.join(dataset_dir, "manifest.json")
    records = C.read_jsonl(train_path)

    # backend selection: explicit, else config recipe, else stub if no torch
    if backend is None:
        backend = "peft" if model_cfg.get("recipe") == "lora" else "stub"
        try:
            import torch  # noqa: F401
        except Exception:
            backend = "stub"

    candidates = model_cfg.get("candidates") or ["qwen2.5-1.5b-instruct"]
    base_model = base_model or candidates[0]

    if not out_dir:
        out_dir = os.path.join(dataset_dir, "models", "%s-%s" % (model_name, backend))
    os.makedirs(out_dir, exist_ok=True)

    roles = {r["id"]: r for r in dom.get("roles", [])}
    extract_role = roles.get("extract", {})
    render_role = roles.get("render", {})

    manifest = {
        "schema": "noetl.slm.model/1",
        "backend": backend,
        "domain": name,
        "model_name": model_name,
        "base_model": base_model,
        "base_family": model_cfg.get("base_family"),
        "base_size": model_cfg.get("base_size"),
        "recipe": model_cfg.get("recipe", "lora"),
        "role_layout": model_cfg.get("role_layout", "single_multitask"),
        "vocab": dom.get("vocab", {}),
        "prompts": {
            "extract": _read_text(C.resolve(cfg_dir, extract_role.get("system_prompt"))),
            "render": _read_text(C.resolve(cfg_dir, render_role.get("system_prompt"))),
        },
        "schemas": {
            "extract": extract_role.get("output_schema"),
            "render": render_role.get("output_schema"),
            "widget_schema_dir": render_role.get("widget_schema_dir"),
        },
        "dataset_dir": dataset_dir,
        "train_records": len(records),
        "augment_teacher": augment_teacher,
        "created_unix": int(time.time()),
    }

    t0 = time.time()
    if backend == "stub":
        manifest = _train_stub(records, out_dir, manifest, include_teacher=augment_teacher)
    elif backend == "peft":  # pragma: no cover
        examples = build_multitask_examples(records, include_teacher=augment_teacher)
        manifest = _train_peft(
            examples, out_dir, manifest, base_model=base_model, max_steps=max_steps,
            epochs=epochs, lora_r=lora_r, lora_alpha=lora_alpha,
            lora_dropout=lora_dropout, learning_rate=learning_rate)
    else:
        raise SystemExit("unknown backend %r" % backend)
    manifest["train_seconds"] = round(time.time() - t0, 3)

    with open(os.path.join(out_dir, INFER.MANIFEST_NAME), "w") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)

    # pack the artifact for the object store
    tar_path = out_dir.rstrip("/") + ".tar.gz"
    INFER.pack_artifact_dir(out_dir, tar_path)

    result = {
        "domain": name,
        "backend": backend,
        "base_model": base_model,
        "artifact_dir": out_dir,
        "artifact_tar": tar_path,
        "train_records": len(records),
        "manifest": manifest["train"],
        "registry": None,
    }

    if register:
        client = _registry_client()
        if client is not None:
            ds_ref = ensure_dataset_registered(
                client, name="%s_%s" % (name, os.path.basename(dataset_dir)),
                dataset_dir=dataset_dir, manifest_path=manifest_path,
                tenant=tenant, project=project)
            with open(tar_path, "rb") as fh:
                tar_bytes = fh.read()
            entry = client.put_and_register(
                "model", model_name, "model.tar.gz", tar_bytes,
                media_type="application/gzip",
                metadata={
                    "backend": backend, "base_model": base_model,
                    "recipe": manifest["recipe"], "role_layout": manifest["role_layout"],
                    "train": manifest["train"], "train_records": len(records),
                    "augment_teacher": augment_teacher,
                },
                lineage=[ds_ref] if ds_ref else None,
                tags=["slm", name, backend],
                tenant=tenant, project=project)
            result["registry"] = {
                "model_ref": entry["ref"], "version": entry["version"],
                "dataset_ref": ds_ref, "tenant": tenant, "project": project,
                "artifact_uri": entry.get("artifact_uri"),
            }
        else:
            result["registry"] = {"skipped": "no registry client configured"}

    C.write_json(os.path.join(out_dir, "train_report.json"), result)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--backend", choices=["stub", "peft"], default=None)
    ap.add_argument("--dataset", default=None)
    ap.add_argument("--base-model", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--augment-teacher", action="store_true")
    ap.add_argument("--max-steps", type=int, default=2)
    ap.add_argument("--epochs", type=int, default=1)
    ap.add_argument("--lora-r", type=int, default=8)
    ap.add_argument("--lora-alpha", type=int, default=16)
    ap.add_argument("--lora-dropout", type=float, default=0.05)
    ap.add_argument("--learning-rate", type=float, default=2e-4)
    ap.add_argument("--no-register", action="store_true")
    ap.add_argument("--model-name", default=None)
    ap.add_argument("--tenant", default=None)
    ap.add_argument("--project", default=None)
    args = ap.parse_args()

    result = finetune(
        args.config, backend=args.backend, dataset_dir=args.dataset,
        base_model=args.base_model, out_dir=args.out,
        augment_teacher=args.augment_teacher, max_steps=args.max_steps,
        epochs=args.epochs, lora_r=args.lora_r, lora_alpha=args.lora_alpha,
        lora_dropout=args.lora_dropout, learning_rate=args.learning_rate,
        register=not args.no_register, model_name=args.model_name,
        tenant=args.tenant, project=args.project)
    print("=== finetune complete ===")
    print("backend:", result["backend"], "| base:", result["base_model"])
    print("artifact:", result["artifact_dir"])
    print("train:", json.dumps(result["manifest"]))
    print("registry:", json.dumps(result["registry"]))


if __name__ == "__main__":
    main()
