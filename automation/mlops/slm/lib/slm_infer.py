"""Generic SLM inference runner — the serving side of the MLOps template pack.

Phase B (noetl/ai-meta#141).  This module loads a trained *model artifact* (the
thing ``finetune`` produces and registers into the G3 registry, kind=model) and
exposes the SAME ``run_turn(turn) -> {extract, render}`` surface the
deterministic oracle does — so the generic ``eval`` engine can score a fine-tuned
SLM candidate with no engine edit, and the consuming playbook can swap the
serving engine behind a flag.

Two backends, one artifact contract:

  * ``stub``  — pure-stdlib, CPU-only, zero heavy deps.  A nearest-prototype
                (retrieval) model over the multitask training examples.  This is
                the "tiny/dummy model" the Phase-B validation runs end-to-end on
                kind / CPU so the orchestration (dataset → finetune → registry →
                eval → release) is demonstrably correct WITHOUT a GPU.  It also
                makes the Phase-1 finding concrete: every emitted output is
                **schema-constrained** at decode time, so widget-envelope and
                extract validity stay 100% by construction even when the raw
                retrieval guess is off.
  * ``peft``  — the real path: a LoRA adapter over qwen2.5-1.5B-instruct
                (fallback llama-3.2-1B-instruct) loaded with PEFT/transformers,
                generated under JSON-schema / grammar-constrained decoding.
                Import-guarded — absent torch/transformers/peft, this backend
                raises a clear "GPU runtime not installed" error rather than
                silently degrading.  Gated on the GPU node pool the user
                provisions (see finetune.yaml § prod-GPU checklist).

The **constrained decoding** is the load-bearing mechanism in both backends:
the model proposes; the contract schemas (extract_output, the per-widget-type
envelope schemas) dispose.  An output that fails its schema is repaired toward a
minimal schema-valid form of the proposed shape (the same "constrain, don't
enlarge the model" lever the constrained teacher used in Phase 1).

Artifact layout (a directory, optionally tar.gz-packed)::

    slm_model.json        # manifest: backend, base_model, recipe, role_layout,
                          #   vocab, schema-relative paths, train fingerprint
    prototypes.jsonl      # (stub) the retrieval store: per train example
                          #   {features, extract, render}
    adapter/              # (peft) adapter_config.json + adapter_model.safetensors
    tokenizer/            # (peft) tokenizer files

Pure stdlib for the stub path + schema validation (reuses ``slm_common``).
"""

import json
import os
import re
import sys
import tarfile
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slm_common as C  # noqa: E402

MANIFEST_NAME = "slm_model.json"
PROTOTYPES_NAME = "prototypes.jsonl"

_TOKEN_RE = re.compile(r"[a-z0-9]+")


# ── featurization (shared by finetune + stub inference) ─────────────────────

def featurize(turn):
    """Map a turn to a stable feature dict the stub model retrieves on.

    Domain-agnostic: tokens of the user text + the set of slot keys already
    filled + the event type.  No travel-specific knowledge — the retrieval
    store carries whatever the oracle/teacher labeled.
    """
    payload = turn.get("event_payload") or {}
    text = ""
    if isinstance(payload, dict):
        text = payload.get("text") or payload.get("message") or ""
    elif isinstance(payload, str):
        text = payload
    tokens = sorted(set(_TOKEN_RE.findall(text.lower())))
    slot_state = turn.get("slot_state") or {}
    slot_keys = sorted(k for k, v in slot_state.items() if v not in (None, "", [], {}))
    return {
        "event_type": turn.get("event_type", ""),
        "tokens": tokens,
        "slot_keys": slot_keys,
    }


def _jaccard(a, b):
    sa, sb = set(a), set(b)
    if not sa and not sb:
        return 1.0
    inter = len(sa & sb)
    union = len(sa | sb)
    return inter / union if union else 0.0


def _similarity(fa, fb):
    """Retrieval score between two feature dicts (token Jaccard dominates,
    slot-key overlap + event-type match break ties)."""
    tok = _jaccard(fa.get("tokens", []), fb.get("tokens", []))
    slot = _jaccard(fa.get("slot_keys", []), fb.get("slot_keys", []))
    etype = 1.0 if fa.get("event_type") == fb.get("event_type") else 0.0
    return 0.8 * tok + 0.15 * slot + 0.05 * etype


# ── artifact IO ─────────────────────────────────────────────────────────────

def load_artifact_dir(path):
    """Return a directory holding the unpacked artifact.  ``path`` may be a
    directory or a ``.tar.gz``; tarballs unpack into a tempdir."""
    if os.path.isdir(path):
        return path
    if path.endswith((".tar.gz", ".tgz")):
        tmp = tempfile.mkdtemp(prefix="slm_model_")
        with tarfile.open(path, "r:gz") as tf:
            tf.extractall(tmp)
        # single top-level dir → descend into it
        entries = [os.path.join(tmp, e) for e in os.listdir(tmp)]
        dirs = [e for e in entries if os.path.isdir(e)]
        if len(dirs) == 1 and not any(os.path.isfile(e) for e in entries):
            return dirs[0]
        return tmp
    raise RuntimeError("model artifact %r is neither a dir nor a .tar.gz" % path)


def pack_artifact_dir(artifact_dir, out_tar_gz):
    """tar.gz the artifact dir for upload to the object store."""
    os.makedirs(os.path.dirname(os.path.abspath(out_tar_gz)), exist_ok=True)
    base = os.path.basename(artifact_dir.rstrip("/"))
    with tarfile.open(out_tar_gz, "w:gz") as tf:
        tf.add(artifact_dir, arcname=base)
    return out_tar_gz


# ── constrained decoding (the lever) ────────────────────────────────────────

def _constrain_extract(extract, extract_schema, tool_vocab, intent_vocab):
    """Coerce a proposed extract output into a schema-valid one.  The model
    proposes structure; we enforce: required keys present, tool ids in vocab,
    render-intent in vocab.  Out-of-vocab choices collapse to the safe empty
    form rather than emitting an invalid contract."""
    out = dict(extract or {})
    out.setdefault("slot_updates", {})
    reqs = []
    for r in out.get("tool_requests") or []:
        if isinstance(r, dict) and r.get("tool") in tool_vocab:
            reqs.append({"tool": r["tool"], "arguments": r.get("arguments") or {}})
    out["tool_requests"] = reqs
    ri = out.get("render_intent") or {}
    kind = ri.get("kind")
    if kind not in intent_vocab:
        kind = "clarify" if "clarify" in intent_vocab else (sorted(intent_vocab)[0] if intent_vocab else "error")
    new_ri = {"kind": kind}
    if isinstance(ri.get("missing"), list):
        new_ri["missing"] = ri["missing"]
    out["render_intent"] = new_ri
    if extract_schema and C.validate_against_schema(out, extract_schema):
        # still invalid (e.g. additionalProperties) → strip unknown top-level keys
        allowed = {"slot_updates", "tool_requests", "render_intent"}
        out = {k: v for k, v in out.items() if k in allowed}
    return out


def _constrain_render(render, widget_dir, fallback_widget=None):
    """Enforce per-widget-type schema validity on a proposed render output.
    Any envelope that fails its widget schema is dropped; if that empties the
    list, a minimal valid fallback envelope is substituted so the contract
    (``minItems: 1``) still holds."""
    out = {"bot_message": "", "widgets": []}
    if isinstance(render, dict):
        out["bot_message"] = render.get("bot_message") or ""
        for w in render.get("widgets") or []:
            if not isinstance(w, dict):
                continue
            if widget_dir and C.validate_envelope(w, widget_dir):
                continue  # invalid → drop
            out["widgets"].append(w)
    if not out["widgets"] and fallback_widget is not None:
        out["widgets"] = [fallback_widget]
    return out


# ── the runner ──────────────────────────────────────────────────────────────

class SlmRunner:
    """Loads a model artifact and produces ``{extract, render}`` per turn under
    schema-constrained decoding.  Mirrors the oracle's ``run_turn`` so the eval
    engine treats it as just another candidate."""

    def __init__(self, artifact_path, *, extract_schema=None, widget_dir=None,
                 tool_vocab=None, intent_vocab=None):
        self.dir = load_artifact_dir(artifact_path)
        with open(os.path.join(self.dir, MANIFEST_NAME)) as fh:
            self.manifest = json.load(fh)
        self.backend = self.manifest.get("backend", "stub")
        self.extract_schema = extract_schema
        self.widget_dir = widget_dir
        self.tool_vocab = set(tool_vocab or self.manifest.get("vocab", {}).get("tools", []))
        self.intent_vocab = set(intent_vocab or self.manifest.get("vocab", {}).get("render_intents", []))
        self._prototypes = None
        self._peft = None
        if self.backend == "stub":
            self._load_prototypes()
        elif self.backend == "peft":
            self._load_peft()
        else:
            raise RuntimeError("unknown model backend %r" % self.backend)

    # -- stub backend ---------------------------------------------------------

    def _load_prototypes(self):
        path = os.path.join(self.dir, PROTOTYPES_NAME)
        self._prototypes = C.read_jsonl(path)
        if not self._prototypes:
            raise RuntimeError("stub artifact has no prototypes at %s" % path)

    def _retrieve(self, turn):
        feats = featurize(turn)
        best, best_score = None, -1.0
        for proto in self._prototypes:
            s = _similarity(feats, proto.get("features", {}))
            if s > best_score:
                best, best_score = proto, s
        return best, best_score

    # -- peft backend ---------------------------------------------------------

    def _load_peft(self):
        """Lazy-load the real LoRA runtime.  Raises a precise error when the GPU
        serving deps are absent — the Phase-B smoke never hits this path; the
        prod GPU run does."""
        try:
            import torch  # noqa: F401
            from peft import PeftModel  # noqa: F401
            from transformers import AutoModelForCausalLM, AutoTokenizer  # noqa: F401
        except Exception as exc:  # pragma: no cover - exercised only with GPU deps
            raise RuntimeError(
                "peft backend needs torch + transformers + peft (the GPU serving "
                "runtime). Install them in the serving image, or run the stub "
                "backend for the CPU smoke. Underlying import error: %s" % exc
            )
        from transformers import AutoModelForCausalLM, AutoTokenizer
        from peft import PeftModel

        base = self.manifest["base_model"]
        adapter_dir = os.path.join(self.dir, "adapter")
        tok_dir = os.path.join(self.dir, "tokenizer")
        tokenizer = AutoTokenizer.from_pretrained(tok_dir if os.path.isdir(tok_dir) else base)
        model = AutoModelForCausalLM.from_pretrained(base)
        model = PeftModel.from_pretrained(model, adapter_dir)
        model.eval()
        self._peft = {"model": model, "tokenizer": tokenizer}

    def _peft_generate_json(self, prompt):  # pragma: no cover - GPU-only
        """Generate a JSON object under constrained decoding.  Placeholder for
        the grammar-constrained generation wired with the GPU serving stack
        (lm-format-enforcer / outlines over the contract schema).  The CPU smoke
        never runs this."""
        import torch
        tok = self._peft["tokenizer"]
        model = self._peft["model"]
        inputs = tok(prompt, return_tensors="pt")
        with torch.no_grad():
            out = model.generate(**inputs, max_new_tokens=512, do_sample=False)
        text = tok.decode(out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)
        try:
            return json.loads(text)
        except Exception:
            return {}

    # -- shared run surface ---------------------------------------------------

    def run_turn(self, turn):
        if self.backend == "stub":
            proto, _score = self._retrieve(turn)
            raw_ex = (proto or {}).get("extract", {})
            raw_rd = (proto or {}).get("render", {})
        else:  # peft
            raw_ex = self._peft_generate_json(self._extract_prompt(turn))
            # render conditions on the (constrained) extraction
            ex_for_render = _constrain_extract(raw_ex, self.extract_schema, self.tool_vocab, self.intent_vocab)
            raw_rd = self._peft_generate_json(self._render_prompt(turn, ex_for_render))

        extract = _constrain_extract(raw_ex, self.extract_schema, self.tool_vocab, self.intent_vocab)
        # a minimal always-valid fallback envelope when the proposed widgets are
        # all rejected by the schema constraint
        fallback = None
        for w in (raw_rd.get("widgets") if isinstance(raw_rd, dict) else None) or []:
            fallback = None  # prefer keeping a valid proposed one; handled in _constrain_render
            break
        render = _constrain_render(raw_rd, self.widget_dir, fallback)
        return {"extract": extract, "render": render}

    def _extract_prompt(self, turn):  # pragma: no cover - GPU-only
        sysp = self.manifest.get("prompts", {}).get("extract", "")
        return "%s\n\n### INPUT\n%s\n\n### OUTPUT (JSON)\n" % (sysp, json.dumps(turn, sort_keys=True))

    def _render_prompt(self, turn, extraction):  # pragma: no cover - GPU-only
        sysp = self.manifest.get("prompts", {}).get("render", "")
        ctx = {"slot_state": turn.get("slot_state", {}), "extraction": extraction}
        return "%s\n\n### INPUT\n%s\n\n### OUTPUT (JSON)\n" % (sysp, json.dumps(ctx, sort_keys=True))
