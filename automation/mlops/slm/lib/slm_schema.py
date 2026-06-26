"""draft-07 (subset) → Vertex Gemini ``responseSchema`` converter.

The SLM teacher's failure mode in the first on-cluster ceiling run was NOT a
weak model — it was an unconstrained one.  ``gemini-2.5-pro`` picked valid
widget *types* but emitted the wrong tool-request keys (``tool_id`` /
``tool_name`` instead of ``tool``) and empty widget payloads, so 0% of widget
envelopes and only 49% of extractions validated.  The fix the finding implies is
*schema-constrained decoding*: hand the teacher the contract as a Vertex
``generationConfig.responseSchema`` so its output is schema-valid by
construction (noetl/ai-meta#140 Phase 1).

Vertex's ``responseSchema`` is a subset of OpenAPI 3.0 Schema, not draft-07, so
the contract schemas (draft-07, ``additionalProperties:false`` / ``const`` /
sibling ``$ref``) have to be down-converted.  This module does that conversion
for exactly the keyword subset the muno contracts + widget schemas use:

  type · properties · required · items · enum · const(→enum) ·
  minimum · maximum · $ref(sibling file + ``#/definitions``) ·
  (additionalProperties / minItems / maxLength / format are dropped — Vertex's
  structured-output decoder only emits declared properties, and the post-hoc
  ``slm_common`` validator re-checks everything the grammar can't express.)

Pure stdlib.  Importable by ``slm_teacher`` (the provider passes the converted
schema) and by the generic engine.  Conversion failures raise ``SchemaError``
so a caller can fall back to envelope-level-only constraint + repair rather than
shipping a broken grammar.
"""

import json
import os


class SchemaError(ValueError):
    pass


# Vertex responseSchema understands these OpenAPI types verbatim.
_TYPE_MAP = {
    "object": "object",
    "array": "array",
    "string": "string",
    "integer": "integer",
    "number": "number",
    "boolean": "boolean",
    # OpenAPI/Vertex has no "null" type; nullability is expressed via the
    # ``nullable`` flag.  A bare {"type": "null"} is rare in these contracts.
}

# keywords we intentionally drop on the way to Vertex (decoder-enforced or
# re-checked post-hoc by slm_common.validate_*):
_DROP = {
    "$schema", "$id", "title", "description", "additionalProperties",
    "minItems", "maxItems", "minLength", "maxLength", "format", "default",
}


def _load_ref(ref, base_dir, root):
    """Resolve a draft-07 $ref to (subschema, new_root, new_base_dir)."""
    if ref.startswith("#/"):
        node = root
        for part in ref[2:].split("/"):
            node = node[part]
        return node, root, base_dir
    if "#" in ref:
        filename, frag = ref.split("#", 1)
    else:
        filename, frag = ref, ""
    if base_dir is None:
        raise SchemaError("sibling $ref %r needs a base_dir to resolve" % ref)
    path = os.path.join(base_dir, filename)
    with open(path, "r") as fh:
        doc = json.load(fh)
    node = doc
    if frag:
        for part in frag.lstrip("/").split("/"):
            if part:
                node = node[part]
    return node, doc, os.path.dirname(os.path.abspath(path))


def to_vertex_schema(schema, base_dir=None, root=None, _depth=0):
    """Convert a draft-07 (subset) schema dict to a Vertex responseSchema dict.

    ``base_dir`` is where sibling ``$ref`` files live (the widget-contract dir).
    ``root`` carries the top document for local ``#/definitions`` refs.
    """
    if _depth > 40:
        raise SchemaError("schema nesting too deep (cyclic $ref?)")
    if not isinstance(schema, dict):
        raise SchemaError("schema node is not an object: %r" % (schema,))
    if root is None:
        root = schema

    if "$ref" in schema:
        target, new_root, new_base = _load_ref(schema["$ref"], base_dir, root)
        return to_vertex_schema(target, new_base, new_root, _depth + 1)

    out = {}

    # const → single-value enum (Vertex has no const).  Vertex's `enum` only
    # accepts STRING values (an integer enum is rejected with HTTP 400
    # "Invalid value ... enum[0] (TYPE_STRING)"), so a non-string const keeps
    # only its type — the post-hoc slm_common validator still enforces the exact
    # value (e.g. schema_version const 1).
    if "const" in schema:
        out["type"] = _vertex_type_of(schema["const"])
        if isinstance(schema["const"], str):
            out["enum"] = [schema["const"]]
        return out

    if "enum" in schema:
        # only string enums survive to Vertex; a mixed/non-string enum drops the
        # constraint (type still applies, value re-checked post-hoc).
        if all(isinstance(v, str) for v in schema["enum"]):
            out["enum"] = list(schema["enum"])

    t = schema.get("type")
    if isinstance(t, list):
        # draft-07 allows a type union (commonly [..., "null"]); take the first
        # concrete type and mark nullable when "null" is present.
        concrete = [x for x in t if x != "null"]
        if "null" in t:
            out["nullable"] = True
        t = concrete[0] if concrete else None
    if t is not None:
        if t not in _TYPE_MAP:
            raise SchemaError("unsupported type %r" % t)
        out["type"] = _TYPE_MAP[t]
    elif "enum" in schema and "type" not in out:
        out["type"] = _vertex_type_of(schema["enum"][0])

    for k in ("minimum", "maximum"):
        if k in schema:
            out[k] = schema[k]

    if schema.get("type") == "object" or "properties" in schema:
        props = schema.get("properties", {})
        if props:
            out["type"] = "object"
            out["properties"] = {
                name: to_vertex_schema(sub, base_dir, root, _depth + 1)
                for name, sub in props.items()
            }
            req = [r for r in schema.get("required", []) if r in props]
            if req:
                out["required"] = req
            # Stabilise field order so the decoder emits required keys reliably.
            out["propertyOrdering"] = list(props.keys())

    if schema.get("type") == "array" or "items" in schema:
        out["type"] = "array"
        items = schema.get("items")
        if isinstance(items, dict):
            out["items"] = to_vertex_schema(items, base_dir, root, _depth + 1)
        else:
            # untyped array — Vertex needs *some* items schema
            out["items"] = {"type": "string"}

    if "type" not in out and "enum" not in out and "anyOf" not in out:
        # An empty / open object schema ({"type":"object"} with no props) is
        # valid — Vertex accepts a bare object type.
        out["type"] = "object"
    return out


def _vertex_type_of(value):
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return "string"


# ── pass-level response schema builders ─────────────────────────────────────

def extract_response_schema(extract_schema_path):
    """Vertex responseSchema for the extraction pass, from the contract file."""
    with open(extract_schema_path, "r") as fh:
        draft = json.load(fh)
    base = os.path.dirname(os.path.abspath(extract_schema_path))
    return to_vertex_schema(draft, base)


def _widget_envelope_schema(widget_type, payload_schema):
    """One envelope object schema pinned to a single widget_type, with its
    payload enforced."""
    return {
        "type": "object",
        "properties": {
            "schema_version": {"type": "integer"},
            "widget_type": {"type": "string", "enum": [widget_type]},
            "variant": {"type": "string"},
            "payload": payload_schema,
        },
        "required": ["schema_version", "widget_type", "variant", "payload"],
        "propertyOrdering": ["schema_version", "widget_type", "variant", "payload"],
    }


def render_response_schema(widget_dir, allowed_widget_types):
    """Vertex responseSchema for the render pass for ONE turn.

    ``allowed_widget_types`` are the widget types the authoritative oracle chose
    for this turn (the intent is authoritative; the teacher fills the payload in
    the required shape).  Each type's draft-07 payload schema is converted and
    pinned, so the teacher's widgets validate against the per-type contract by
    construction.  ``widgets.items`` is the single type's envelope schema, or an
    ``anyOf`` over the envelope schemas when a turn uses more than one type.

    Raises ``SchemaError`` if any payload schema can't be converted, so the
    caller can fall back to the envelope-level-only constraint + repair.
    """
    types = list(dict.fromkeys(allowed_widget_types)) or []
    envelope_schemas = []
    for wt in types:
        payload_path = os.path.join(widget_dir, "%s.schema.json" % wt)
        if not os.path.exists(payload_path):
            raise SchemaError("no payload schema for widget_type %r" % wt)
        with open(payload_path, "r") as fh:
            payload_draft = json.load(fh)
        payload_vertex = to_vertex_schema(payload_draft, widget_dir)
        envelope_schemas.append(_widget_envelope_schema(wt, payload_vertex))

    if not envelope_schemas:
        # no oracle widgets to pin (shouldn't happen — render always emits ≥1);
        # leave the item schema open so the decoder still produces an envelope.
        item_schema = {
            "type": "object",
            "properties": {
                "schema_version": {"type": "integer"},
                "widget_type": {"type": "string"},
                "variant": {"type": "string"},
                "payload": {"type": "object"},
            },
            "required": ["schema_version", "widget_type", "variant", "payload"],
        }
    elif len(envelope_schemas) == 1:
        item_schema = envelope_schemas[0]
    else:
        item_schema = {"anyOf": envelope_schemas}

    return {
        "type": "object",
        "properties": {
            "bot_message": {"type": "string"},
            "widgets": {"type": "array", "items": item_schema},
        },
        "required": ["bot_message", "widgets"],
        "propertyOrdering": ["bot_message", "widgets"],
    }
