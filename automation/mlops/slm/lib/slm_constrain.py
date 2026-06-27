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


# ── the mlx logits processor ─────────────────────────────────────────────────

def make_logits_processor(schema_dict, tokenizer_data):
    """Return an mlx_lm logits processor ``(tokens, logits) -> logits`` that masks
    every token disallowed by ``schema_dict`` at the current decode position.

    Robust to mlx's chunked prefill: the first invocation's token-array length is
    captured as the baseline, so the *generated* suffix is ``tokens[baseline:]``
    regardless of how much prompt the accumulator carries."""
    import mlx.core as mx
    import numpy as np
    from lmformatenforcer import JsonSchemaParser
    from lmformatenforcer.tokenenforcer import TokenEnforcer

    parser = JsonSchemaParser(schema_dict)
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
