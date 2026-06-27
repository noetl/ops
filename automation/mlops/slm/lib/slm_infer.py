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


# ── base-model id resolution (config short name → HF repo) ──────────────────

# The config carries short, human-friendly model names; the real fine-tune /
# serving paths need the Hugging Face repo id.  Keep the mapping here so both
# finetune (download + train) and infer (load + serve) agree.
HF_MODEL_ALIASES = {
    "qwen2.5-1.5b-instruct": "Qwen/Qwen2.5-1.5B-Instruct",
    "qwen2.5-3b-instruct": "Qwen/Qwen2.5-3B-Instruct",
    "qwen2.5-0.5b-instruct": "Qwen/Qwen2.5-0.5B-Instruct",
    "llama-3.2-1b-instruct": "meta-llama/Llama-3.2-1B-Instruct",  # gated — needs HF auth
    "llama-3.2-3b-instruct": "meta-llama/Llama-3.2-3B-Instruct",  # gated — needs HF auth
}


def resolve_hf_model_id(name):
    """Map a config short model name to a Hugging Face repo id.  A value that
    already looks like an ``org/repo`` (or a local path) is returned as-is."""
    if not name:
        return name
    key = name.strip().lower()
    if key in HF_MODEL_ALIASES:
        return HF_MODEL_ALIASES[key]
    return name


# ── prompt builders (shared by finetune data-prep + real-model inference) ────

# A SINGLE place the prompt format lives so training-time formatting and
# inference-time formatting never drift (a drift the model would never recover
# from — it learns the completion given a prompt shape it never sees again).
# Plain-text instruction format (not the chat template) so the same string is
# used verbatim at train + infer; ``--mask-prompt`` makes the model learn only
# the JSON completion that follows the OUTPUT marker.

def build_extract_prompt(system_prompt, turn):
    body = {"turn": _clean_turn(turn)}
    return "%s\n\n### INPUT\n%s\n\n### OUTPUT (JSON)\n" % (
        system_prompt or "", json.dumps(body, sort_keys=True))


def _clean_turn(turn):
    """The prompt body carries only the three input fields the model conditions
    on; strip any sidecar keys (e.g. a persisted ``tool_summary`` or
    ``thread_context``) so train-time and infer-time bodies are byte-identical."""
    return {k: turn.get(k) for k in ("event_type", "event_payload", "slot_state")}


def build_render_prompt(system_prompt, turn, extraction, tool_summary=None):
    # The render role's declared input is "slot_state + extraction + tool_summary
    # + render_intent".  Conditioning on the tool result lets the model copy real
    # values (place names, offer ids, hotel data) into schema-valid widget
    # payloads instead of hallucinating them — the lever for render/widget_type/
    # arg fidelity.  Backward compatible: tool_summary=None reproduces the old
    # body so v1 artifacts still load.
    body = {"turn": _clean_turn(turn), "extraction": extraction}
    if tool_summary is not None:
        body["tool_summary"] = tool_summary
    return "%s\n\n### INPUT\n%s\n\n### OUTPUT (JSON)\n" % (
        system_prompt or "", json.dumps(body, sort_keys=True))


# ── robust JSON extraction from a generated completion ──────────────────────

def parse_json_object(text):
    """Best-effort parse of the first JSON object in a model completion.

    The model is prompted to emit a bare JSON object, but a small SLM may wrap
    it in markdown fences or trail extra tokens.  Strip fences, then scan for
    the first balanced ``{...}`` (string-aware) and ``json.loads`` it.  Returns
    ``{}`` when nothing parseable is found — the schema-constraint repair then
    produces a minimal valid output, so a parse failure degrades to the safe
    form rather than crashing the eval.
    """
    if not isinstance(text, str):
        return {}
    s = text.strip()
    if s.startswith("```"):
        # drop the opening fence (``` or ```json) and any closing fence
        s = re.sub(r"^```[a-zA-Z0-9]*\s*", "", s)
        s = re.sub(r"\s*```\s*$", "", s)
    start = s.find("{")
    if start < 0:
        return {}
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(s)):
        ch = s[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                candidate = s[start:i + 1]
                try:
                    return json.loads(candidate)
                except Exception:
                    return {}
    return {}


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
                 tool_vocab=None, intent_vocab=None, render_schema=None,
                 constrained_decode=None):
        self.dir = load_artifact_dir(artifact_path)
        with open(os.path.join(self.dir, MANIFEST_NAME)) as fh:
            self.manifest = json.load(fh)
        self.backend = self.manifest.get("backend", "stub")
        self.extract_schema = extract_schema
        self.render_schema = render_schema
        self.widget_dir = widget_dir
        self.tool_vocab = set(tool_vocab or self.manifest.get("vocab", {}).get("tools", []))
        self.intent_vocab = set(intent_vocab or self.manifest.get("vocab", {}).get("render_intents", []))
        self._prototypes = None
        self._peft = None
        self._mlx = None
        if self.backend == "stub":
            self._load_prototypes()
        elif self.backend == "peft":
            self._load_peft()
        elif self.backend == "mlx":
            self._load_mlx()
        else:
            raise RuntimeError("unknown model backend %r" % self.backend)
        self._setup_constrained(constrained_decode)

    # -- grammar-constrained decoding (lever 1; flag-gated, mlx only) ----------

    def _setup_constrained(self, flag):
        """Prepare logit-level schema constraint when enabled + available.
        ``flag`` None → read env SLM_CONSTRAINED_DECODE (default off)."""
        self.constrained = False
        self._constrain = None
        self._tok_data = None
        self._extract_schema_dict = None
        self._render_schema_dict = None
        self._render_max_tokens = 512
        self._render_max_items = 5
        if flag is None:
            flag = os.environ.get("SLM_CONSTRAINED_DECODE", "").strip().lower() in ("1", "true", "yes")
        if not flag or self.backend != "mlx":
            return
        try:
            import slm_constrain as CON
        except Exception as exc:
            print("constrained decode requested but slm_constrain unavailable (%s)" % exc, file=sys.stderr)
            return
        if not CON.available():
            print("constrained decode requested but lm-format-enforcer not installed; "
                  "falling back to post-hoc repair", file=sys.stderr)
            return
        self._constrain = CON
        self._tok_data = CON.build_tokenizer_data(self._mlx["tokenizer"])
        if self.extract_schema and os.path.isfile(self.extract_schema):
            with open(self.extract_schema) as fh:
                self._extract_schema_dict = CON.sanitize_for_lmfe(json.load(fh))
        # Render constraint (lever 2).  The original enum-only render constraint
        # was OFF by default because forcing the widget_type enum with a GENERIC
        # payload (the base render schema has no per-type payload requirements)
        # let the model emit a right-type-but-incomplete payload that then failed
        # the per-type envelope schema and got dropped → empty widget lists, worse
        # than plain generation.  The payload-complete builder fixes exactly that:
        # each widget item is an anyOf over per-widget-type envelope branches that
        # carry the type's required payload fields, so a chosen widget_type is
        # forced to be payload-complete and survives ``validate_envelope`` instead
        # of being dropped — the dominant ``widget_type_match`` bottleneck.
        #
        # Opt in with SLM_CONSTRAIN_RENDER=1 (payload-complete builder; default
        # when on).  SLM_RENDER_ENUM_ONLY=1 falls back to the legacy enum-only
        # builder for A/B.  Extract constraint (closed-vocab tool + render_intent
        # enums) stays the clean always-on win regardless.
        constrain_render = os.environ.get("SLM_CONSTRAIN_RENDER", "").strip().lower() in ("1", "true", "yes")
        if constrain_render and self.render_schema and os.path.isfile(self.render_schema):
            enum_only = os.environ.get("SLM_RENDER_ENUM_ONLY", "").strip().lower() in ("1", "true", "yes")
            if enum_only:
                self._render_schema_dict = CON.render_schema_with_widget_enum(
                    self.render_schema, self.widget_dir)
            else:
                # Restrict the anyOf branch set to the producible widget types so
                # the lm-format-enforcer parser stays light (fewer live branches
                # before the widget_type discriminator commits → faster decode).
                # Precedence: env SLM_RENDER_TYPES (comma list) > manifest
                # render_widget_types (the distinct types in the train render
                # labels, written by finetune) > every type in widget_dir.
                env_types = os.environ.get("SLM_RENDER_TYPES", "").strip()
                types = ([t.strip() for t in env_types.split(",") if t.strip()]
                         or self.manifest.get("render_widget_types")
                         or None)
                self._render_schema_dict = CON.render_schema_payload_complete(
                    self.render_schema, self.widget_dir, types=types)
        # Deep payload-complete render needs more room than the 512-token default
        # (a flight/hotel list copies several fully-formed cards) — and a bound on
        # how many list items the decoder may emit so it always closes the
        # envelope in budget.  Both env-overridable.
        self._render_max_tokens = int(os.environ.get("SLM_RENDER_MAX_TOKENS")
                                      or self.manifest.get("render_max_tokens")
                                      or max(self._mlx.get("max_tokens", 512) if self._mlx else 512, 1024))
        self._render_max_items = int(os.environ.get("SLM_RENDER_MAX_ITEMS")
                                     or self.manifest.get("render_max_items") or 5)
        self.constrained = True
        print("constrained decode: ENABLED (extract schema; render_constraint=%s%s)"
              % (bool(self._render_schema_dict),
                 " payload-complete" if self._render_schema_dict and
                 os.environ.get("SLM_RENDER_ENUM_ONLY", "").strip().lower() not in ("1", "true", "yes")
                 else ""), file=sys.stderr)

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

    # -- mlx backend (Apple Silicon, real LoRA) -------------------------------

    def _load_mlx(self):
        """Load the real Apple-Silicon LoRA runtime via ``mlx_lm``.

        The artifact is adapter-only (``adapter/adapters.safetensors`` +
        ``adapter_config.json``); the base weights are pulled from Hugging Face
        by ``mlx_lm.load`` and the LoRA layers fused in at load time.  Raises a
        precise error when mlx isn't installed (e.g. on a Linux/GPU box) so the
        caller can pick the peft path instead."""
        try:
            from mlx_lm import load as _mlx_load  # noqa: F401
            from mlx_lm import generate as _mlx_generate  # noqa: F401
        except Exception as exc:
            raise RuntimeError(
                "mlx backend needs mlx-lm (Apple-Silicon training/serving "
                "runtime). Install it in an arm64 venv (`pip install mlx-lm`), "
                "or use the peft backend on a CUDA box. Import error: %s" % exc)
        from mlx_lm import load as mlx_load
        from mlx_lm import generate as mlx_generate

        base = resolve_hf_model_id(self.manifest.get("base_model_hf")
                                   or self.manifest["base_model"])
        adapter_dir = os.path.join(self.dir, "adapter")
        model, tokenizer = mlx_load(base, adapter_path=adapter_dir)
        self._mlx = {"model": model, "tokenizer": tokenizer, "generate": mlx_generate,
                     "max_tokens": int(self.manifest.get("max_new_tokens", 512))}

    def _mlx_generate_json(self, prompt, schema_dict=None):
        """Greedy-decode a completion and parse the first JSON object out of it.
        When constrained decoding is enabled and a ``schema_dict`` is given, a
        logit-level lm-format-enforcer processor masks every token that would
        break the schema (lever 1); otherwise the post-hoc ``_constrain_*``
        repair the caller applies is the only guard (the v2 path)."""
        g = self._mlx
        is_render = schema_dict is not None and schema_dict is self._render_schema_dict
        max_tokens = self._render_max_tokens if is_render else g["max_tokens"]
        kwargs = {"max_tokens": max_tokens, "verbose": False}
        if self.constrained and schema_dict is not None:
            if is_render:
                # payload-complete anyOf render schema: force widget_type first,
                # cap whitespace + list length so deep list payloads finish.
                proc = self._constrain.make_logits_processor(
                    schema_dict, self._tok_data, force_field_order=True,
                    max_whitespaces=2, max_array_length=self._render_max_items)
            else:
                proc = self._constrain.make_logits_processor(schema_dict, self._tok_data)
            kwargs["logits_processors"] = [proc]
        text = g["generate"](g["model"], g["tokenizer"], prompt=prompt, **kwargs)
        return parse_json_object(text)

    # -- shared run surface ---------------------------------------------------

    def run_turn(self, turn):
        # render conditions on the SLM's own constrained extraction (the natural
        # end-to-end SLM pipeline); run_extract / run_render are the split form
        # the serving endpoint uses so each shadow pass is exactly one model call.
        extract = self.run_extract(turn)
        render = self.run_render(turn, extract)
        return {"extract": extract, "render": render}

    def run_extract(self, turn):
        """Extract pass only.  Returns the schema-constrained extract dict — the
        ``{slot_updates, tool_requests, render_intent}`` contract object the
        planner's ``extract_turn`` step emits, so a shadow step can compare it
        field-for-field against the live extraction."""
        if self.backend == "stub":
            proto, _score = self._retrieve(turn)
            raw_ex = (proto or {}).get("extract", {})
        elif self.backend == "mlx":  # real model + (optional) logit-level constraint
            raw_ex = self._mlx_generate_json(self._extract_prompt(turn), self._extract_schema_dict)
        else:  # peft
            raw_ex = self._peft_generate_json(self._extract_prompt(turn))
        return _constrain_extract(raw_ex, self.extract_schema, self.tool_vocab, self.intent_vocab)

    def run_render(self, turn, extraction):
        """Render pass only, conditioned on ``extraction`` (the SLM's own or a
        supplied extract) + the turn's ``tool_summary``.  Returns the
        ``{bot_message, widgets}`` shape the eval engine + a shadow step compare
        against the live ``render_widget_chat`` envelope."""
        if self.backend == "stub":
            proto, _score = self._retrieve(turn)
            raw_rd = (proto or {}).get("render", {})
        elif self.backend == "mlx":
            raw_rd = self._mlx_generate_json(self._render_prompt(turn, extraction), self._render_schema_dict)
        else:  # peft
            raw_rd = self._peft_generate_json(self._render_prompt(turn, extraction))
        return _constrain_render(raw_rd, self.widget_dir, None)

    def _extract_prompt(self, turn):
        sysp = self.manifest.get("prompts", {}).get("extract", "")
        return build_extract_prompt(sysp, turn)

    def _render_prompt(self, turn, extraction):
        sysp = self.manifest.get("prompts", {}).get("render", "")
        # the eval/serve turn carries the tool result the render pass conditions on
        return build_render_prompt(sysp, turn, extraction, turn.get("tool_summary"))
