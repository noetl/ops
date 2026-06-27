"""True grammar-constrained decoding for the SLM runner (lever 1).

Post-hoc repair (``slm_infer._constrain_*``) keeps outputs *in-vocab* but only
AFTER the model has already committed to tokens — a turn whose generated JSON is
malformed, or whose enum value drifts mid-token, is salvaged by dropping/repair,
which costs widget envelopes and forces ``clarify`` fall-backs.  This module adds
**logit-level** constraint: at every decode step the model may only sample a
token consistent with the role's JSON schema, so the closed-vocab fields are
correct-by-construction at generation time:

  * extract: ``tool_requests[].tool`` ∈ the 4-tool enum, ``render_intent.kind``
    ∈ the 12-intent enum (both already enumerated in ``extract_output.schema``).
  * render: ``widgets[].widget_type`` ∈ the contract widget types (injected as an
    enum into a copy of ``render_output.schema``), envelope shape enforced.

Implementation: lm-format-enforcer's ``TokenEnforcer`` (tokenizer-agnostic,
torch-free core) wrapped in an ``mlx_lm`` logits processor.  lm-format-enforcer's
``integrations.transformers`` helper pulls in torch (absent in the MLX venv), so
the two tiny torch-free builders are replicated here verbatim from that module.

Import-guarded: absent ``lmformatenforcer`` the runner falls back to plain
generation + post-hoc repair (the v2 path), so this is a strictly additive,
flag-gated lever the eval can A/B.
"""

import functools
import json
import os

# ── torch-free tokenizer-data builders (replicated from
# lmformatenforcer.integrations.transformers, which is unimportable here because
# it imports torch at module load) ───────────────────────────────────────────

def _build_regular_tokens_list(tokenizer, vocab_size):
    token_0 = tokenizer.encode("0")[-1]
    special = set(tokenizer.all_special_ids)
    regular = []
    for tid in range(vocab_size):
        if tid in special:
            continue
        # prepend token "0" then drop its first char: reveals a leading space for
        # word-start tokens (lm-format-enforcer's exact heuristic).
        decoded_after_0 = tokenizer.decode([token_0, tid])[1:]
        decoded_regular = tokenizer.decode([tid])
        is_word_start = len(decoded_after_0) > len(decoded_regular)
        regular.append((tid, decoded_after_0, is_word_start))
    return regular


def _decode_function(tokenizer, tokens):
    return tokenizer.decode(tokens).rstrip("�")


_TOK_DATA_CACHE = {}


def _hf_tokenizer(mlx_tokenizer):
    """Unwrap the HF tokenizer from an mlx_lm TokenizerWrapper."""
    for attr in ("_tokenizer", "tokenizer"):
        t = getattr(mlx_tokenizer, attr, None)
        if t is not None and hasattr(t, "decode") and hasattr(t, "all_special_ids"):
            return t
    return mlx_tokenizer


def build_tokenizer_data(mlx_tokenizer):
    """Build (and cache) the TokenEnforcerTokenizerData for an mlx tokenizer."""
    from lmformatenforcer.tokenenforcer import TokenEnforcerTokenizerData
    hf = _hf_tokenizer(mlx_tokenizer)
    key = id(hf)
    if key not in _TOK_DATA_CACHE:
        vocab_size = len(hf)
        regular = _build_regular_tokens_list(hf, vocab_size)
        decode_fn = functools.partial(_decode_function, hf)
        _TOK_DATA_CACHE[key] = TokenEnforcerTokenizerData(
            regular, decode_fn, hf.eos_token_id, False, vocab_size)
    return _TOK_DATA_CACHE[key]


def available():
    try:
        import lmformatenforcer  # noqa: F401
        return True
    except Exception:
        return False


# ── schema sanitiser ─────────────────────────────────────────────────────────

def sanitize_for_lmfe(node):
    """Return a deep copy of a JSON-schema node with constructs lm-format-enforcer
    can't handle removed:

      * non-string ``const`` (e.g. ``schema_version`` const 1) — lmfe's enum/const
        completion does ``str.startswith`` and crashes on an int.
      * ``enum`` lists containing non-strings.

    These only affect numeric literals (which lmfe can't meaningfully constrain
    anyway); the string enums we care about (tool / render_intent / widget_type)
    are preserved."""
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k == "const" and not isinstance(v, str):
                continue
            if k == "enum" and isinstance(v, list) and not all(isinstance(x, str) for x in v):
                continue
            out[k] = sanitize_for_lmfe(v)
        return out
    if isinstance(node, list):
        return [sanitize_for_lmfe(x) for x in node]
    return node


# ── augmented render schema (inject widget_type enum) ────────────────────────

def render_schema_with_widget_enum(render_schema_path, widget_dir):
    """Load the render output schema and constrain widgets[].widget_type to the
    set of contract widget types (the per-type ``*.schema.json`` basenames),
    which the base render schema leaves as a free string."""
    with open(render_schema_path) as fh:
        schema = json.load(fh)
    types = []
    if widget_dir and os.path.isdir(widget_dir):
        for fn in sorted(os.listdir(widget_dir)):
            if fn.endswith(".schema.json") and not fn.startswith("_"):
                types.append(fn[: -len(".schema.json")])
    try:
        wt = schema["properties"]["widgets"]["items"]["properties"]["widget_type"]
        if types:
            wt["enum"] = types
    except Exception:
        pass
    return sanitize_for_lmfe(schema)


# ── per-widget-type payload-complete render schema (lever 2) ──────────────────
#
# ``render_schema_with_widget_enum`` constrains only the widget_type enum and
# leaves ``payload`` a free object — so the model can emit the RIGHT widget_type
# with an INCOMPLETE payload, which then fails the per-type envelope schema in
# ``slm_common.validate_envelope`` and gets DROPPED by ``slm_infer._constrain_render``.
# A dropped widget shortens the widget-type sequence → ``widget_type_match`` fails
# even though the type was correct.  That drop is the dominant ``widget_type_match``
# bottleneck on the data-bearing renders (flight_list / hotel_list / the two-widget
# summary), per noetl/travel#76 / ai-meta SLM v3 RESULTS.
#
# This builder closes it: each ``widgets[]`` item becomes an ``anyOf`` over
# per-widget-type ENVELOPE branches, where the chosen branch (discriminated by a
# single-value ``widget_type`` enum) carries that type's FULLY-INLINED payload
# schema with its ``required`` fields.  So once the decoder commits to a
# widget_type, lm-format-enforcer forces every mandatory payload field for THAT
# type before the object can close — the model can no longer emit a
# valid-type-but-incomplete-payload widget.  The model still CHOOSES the type
# (the anyOf discriminator); the constraint only makes the choice payload-complete.


def _load_schema_file(path, cache):
    ap = os.path.abspath(path)
    if ap not in cache:
        with open(ap) as fh:
            cache[ap] = json.load(fh)
    return cache[ap]


def _inline_refs(node, cur_doc, cur_dir, cache, stack):
    """Return a deep copy of ``node`` with every ``$ref`` fully inlined — both
    sibling-file refs (``flight_card.schema.json``) and internal-pointer refs
    (``#/definitions/calendar_event``) — so the result is a single self-contained
    JSON-schema with zero ``$ref`` (lm-format-enforcer can't resolve cross-file
    refs, and dangling internal refs would break once a sub-schema is lifted out
    of its file).  The widget-contract schemas are non-recursive; ``stack`` is a
    cycle guard that degrades a would-be cycle to an empty object rather than
    recursing forever."""
    if isinstance(node, dict):
        if "$ref" in node:
            ref = node["$ref"]
            if ref in stack:
                return {"type": "object"}  # cycle break (none expected)
            if ref.startswith("#"):
                target = cur_doc
                for part in ref[1:].lstrip("/").split("/"):
                    if part:
                        target = target[part]
                return _inline_refs(target, cur_doc, cur_dir, cache, stack + [ref])
            # sibling-file ref, optionally with a #fragment
            if "#" in ref:
                filename, frag = ref.split("#", 1)
            else:
                filename, frag = ref, ""
            new_path = os.path.join(cur_dir, filename)
            new_doc = _load_schema_file(new_path, cache)
            new_dir = os.path.dirname(os.path.abspath(new_path))
            target = new_doc
            if frag:
                for part in frag.lstrip("/").split("/"):
                    if part:
                        target = target[part]
            return _inline_refs(target, new_doc, new_dir, cache, stack + [ref])
        return {k: _inline_refs(v, cur_doc, cur_dir, cache, stack)
                for k, v in node.items()}
    if isinstance(node, list):
        return [_inline_refs(x, cur_doc, cur_dir, cache, stack) for x in node]
    return node


def _strip_unenforceable(node):
    """Remove JSON-schema keywords lm-format-enforcer can't parse, in place-safe
    deep-copy form:

      * ``additionalProperties`` — a boolean (or typed-dict) value here makes
        lmfe's ``get_parser`` dereference ``.anyOf`` on a ``bool`` and crash
        (``'bool' object has no attribute 'anyOf'``).  Dropping it makes objects
        open at decode time; the post-hoc ``validate_envelope`` still enforces
        ``additionalProperties: false`` exactly, so nothing is lost on the
        validity side.
      * ``format`` / ``$schema`` / ``$id`` / ``title`` / ``description`` /
        ``definitions`` — annotations lmfe ignores or that bloat the parser;
        ``definitions`` is already inlined away by ``_inline_refs``.
    """
    drop = {"additionalProperties", "format", "$schema", "$id", "title",
            "description", "definitions", "default", "examples"}
    if isinstance(node, dict):
        return {k: _strip_unenforceable(v) for k, v in node.items() if k not in drop}
    if isinstance(node, list):
        return [_strip_unenforceable(x) for x in node]
    return node


def _payload_schema(widget_type, widget_dir, cache):
    """The fully-inlined, lmfe-safe payload schema for one widget type."""
    payload_path = os.path.join(widget_dir, "%s.schema.json" % widget_type)
    payload_doc = _load_schema_file(payload_path, cache)
    return _strip_unenforceable(_inline_refs(
        payload_doc, payload_doc, os.path.dirname(os.path.abspath(payload_path)),
        cache, []))


def render_schema_payload_complete(render_schema_path, widget_dir, types=None):
    """Build the render output schema whose ``widgets[]`` items are a FIXED
    envelope object whose ``payload`` is an ``anyOf`` over the per-widget-type
    payload schemas (lever 2).

    Why fixed-envelope + anyOf-on-payload (not anyOf-of-envelopes): with an
    anyOf of whole envelopes, ``force_json_field_order`` can't act — the parser
    doesn't know which branch's field order to force until the discriminator is
    set, so the model is free to emit the long ``payload`` FIRST and then truncate
    before it ever writes ``widget_type`` / the closing braces (the JSON never
    parses → the widget is dropped → ``widget_type_match`` fails on exactly the
    data-bearing renders we're trying to fix).  Keeping the envelope a single
    object lets ``force_json_field_order`` push ``schema_version`` → ``widget_type``
    → ``variant`` → ``payload``, so the small envelope keys (incl. the chosen
    ``widget_type``) are emitted FIRST and only the trailing ``payload`` is at risk
    of the token budget — which the larger render budget + array cap then cover.
    ``widget_type`` is enum-constrained to the producible set, and the payload is
    constrained to be a complete instance of SOME producible type's schema; the
    model's training aligns the payload with the type it just chose.

    ``types`` restricts the type set (default: every ``*.schema.json`` in
    ``widget_dir``)."""
    with open(render_schema_path) as fh:
        schema = json.load(fh)
    cache = {}
    if not types:
        types = []
        if widget_dir and os.path.isdir(widget_dir):
            for fn in sorted(os.listdir(widget_dir)):
                if fn.endswith(".schema.json") and not fn.startswith("_"):
                    types.append(fn[: -len(".schema.json")])
    payload_branches = []
    kept_types = []
    for t in types:
        try:
            payload_branches.append(_payload_schema(t, widget_dir, cache))
            kept_types.append(t)
        except Exception:
            continue
    if payload_branches:
        item_schema = {
            "type": "object",
            # order forced by force_json_field_order: widget_type (the
            # discriminator the eval reads) FIRST, the long payload LAST — and it
            # MUST match the training serialization order in
            # slm_finetune._ENVELOPE_KEY_ORDER so the model's learned generation
            # order and the constraint agree.
            "required": ["widget_type", "variant", "schema_version", "payload"],
            "properties": {
                "widget_type": {"type": "string", "enum": kept_types},
                "variant": {"type": "string"},
                "schema_version": {"type": "integer"},
                "payload": ({"anyOf": payload_branches} if len(payload_branches) > 1
                            else payload_branches[0]),
            },
        }
        try:
            schema["properties"]["widgets"]["items"] = item_schema
        except Exception:
            pass
    return sanitize_for_lmfe(schema)


# ── the mlx logits processor ─────────────────────────────────────────────────

def make_logits_processor(schema_dict, tokenizer_data, *, force_field_order=False,
                          max_whitespaces=None, max_array_length=None):
    """Return an mlx_lm logits processor ``(tokens, logits) -> logits`` that masks
    every token disallowed by ``schema_dict`` at the current decode position.

    Robust to mlx's chunked prefill: the first invocation's token-array length is
    captured as the baseline, so the *generated* suffix is ``tokens[baseline:]``
    regardless of how much prompt the accumulator carries.

    The render (payload-complete anyOf) path passes ``force_field_order=True`` so
    the widget_type discriminator is emitted first (see ``_envelope_branch``),
    ``max_whitespaces`` to stop the post-payload whitespace degeneration that
    truncated deep list payloads, and ``max_array_length`` to bound the number of
    list items the model copies so a flight/hotel list completes within the
    render token budget instead of running off the end."""
    import mlx.core as mx
    import numpy as np
    from lmformatenforcer import JsonSchemaParser
    from lmformatenforcer.tokenenforcer import TokenEnforcer

    config = None
    try:
        from lmformatenforcer import CharacterLevelParserConfig
        kwargs = {}
        if force_field_order:
            kwargs["force_json_field_order"] = True
        if max_whitespaces is not None:
            kwargs["max_consecutive_whitespaces"] = max_whitespaces
        if max_array_length is not None:
            kwargs["max_json_array_length"] = max_array_length
        if kwargs:
            config = CharacterLevelParserConfig(**kwargs)
    except Exception:
        config = None

    parser = JsonSchemaParser(schema_dict, config=config) if config else JsonSchemaParser(schema_dict)
    enforcer = TokenEnforcer(tokenizer_data, parser)
    state = {"baseline": None}
    neg = -1e30

    def processor(tokens, logits):
        n = int(tokens.shape[0]) if hasattr(tokens, "shape") else len(tokens)
        if state["baseline"] is None:
            state["baseline"] = n  # length at first call == prompt suffix length
        gen = tokens[state["baseline"]:]
        seq = gen.tolist() if hasattr(gen, "tolist") else list(gen)
        try:
            allowed = enforcer.get_allowed_tokens(seq).allowed_tokens
        except Exception:
            return logits  # parser hiccup → don't break generation
        if not allowed:
            return logits
        vocab = logits.shape[-1]
        keep = np.zeros(vocab, dtype=np.bool_)
        valid = [t for t in allowed if 0 <= t < vocab]
        if not valid:
            return logits
        keep[valid] = True
        keep_mx = mx.array(keep)
        return mx.where(keep_mx, logits, mx.array(neg, dtype=logits.dtype))

    return processor
