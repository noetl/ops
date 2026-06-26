"""Shared helpers for the generic SLM MLOps template pack.

Domain-agnostic.  Nothing in this module knows about travel — every
domain-specific input (the I/O contract schemas, the labeling oracle, the seed
corpus, the metric targets) arrives through the org's ``slm.config.yaml``.

Pure stdlib (Python 3.9+): config load (PyYAML), config-relative path
resolution, JSONL IO, dynamic oracle import, and a minimal draft-07 JSON-Schema
validator (the runtime has no ``jsonschema`` package; the validator covers the
subset the widget + contract schemas use: type / required / properties /
additionalProperties / enum / const / items / $ref (sibling file + local
``#/definitions``) / minItems / minimum / maximum / minLength / maxLength).
"""

import importlib.util
import json
import os

try:
    import yaml  # PyYAML — present in the runtime
except Exception as exc:  # pragma: no cover
    raise SystemExit("PyYAML is required: %s" % exc)


# ── config + paths ─────────────────────────────────────────────────────────

def load_config(config_path):
    with open(config_path, "r") as fh:
        cfg = yaml.safe_load(fh)
    cfg_dir = os.path.dirname(os.path.abspath(config_path))
    return cfg, cfg_dir


def resolve(cfg_dir, rel):
    """Resolve a config-relative path to an absolute path."""
    if rel is None:
        return None
    if os.path.isabs(rel):
        return rel
    return os.path.normpath(os.path.join(cfg_dir, rel))


# ── JSONL IO ───────────────────────────────────────────────────────────────

def read_jsonl(path):
    rows = []
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as fh:
        for row in rows:
            fh.write(json.dumps(row, sort_keys=True) + "\n")


def write_json(path, obj):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=2, sort_keys=True)
        fh.write("\n")


# ── dynamic oracle import ──────────────────────────────────────────────────

def import_module_from_path(module_path, alias="slm_oracle"):
    spec = importlib.util.spec_from_file_location(alias, module_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ── minimal draft-07 JSON-Schema validator ─────────────────────────────────

class _SchemaStore:
    """Loads + caches sibling schema files for $ref resolution."""

    def __init__(self, base_dir):
        self.base_dir = base_dir
        self.cache = {}

    def get_file(self, filename):
        if filename not in self.cache:
            with open(os.path.join(self.base_dir, filename), "r") as fh:
                self.cache[filename] = json.load(fh)
        return self.cache[filename]


def _types_ok(value, type_spec):
    types = type_spec if isinstance(type_spec, list) else [type_spec]
    for t in types:
        if t == "object" and isinstance(value, dict):
            return True
        if t == "array" and isinstance(value, list):
            return True
        if t == "string" and isinstance(value, str):
            return True
        if t == "integer" and isinstance(value, int) and not isinstance(value, bool):
            return True
        if t == "number" and isinstance(value, (int, float)) and not isinstance(value, bool):
            return True
        if t == "boolean" and isinstance(value, bool):
            return True
        if t == "null" and value is None:
            return True
    return False


def _resolve_ref(ref, root_schema, store):
    if ref.startswith("#/"):
        node = root_schema
        for part in ref[2:].split("/"):
            node = node[part]
        return node, root_schema
    # sibling file ref (optionally with a fragment)
    if "#" in ref:
        filename, frag = ref.split("#", 1)
    else:
        filename, frag = ref, ""
    doc = store.get_file(filename)
    node = doc
    if frag:
        for part in frag.lstrip("/").split("/"):
            if part:
                node = node[part]
    return node, doc


def _validate(value, schema, root_schema, store, path, errors):
    if "$ref" in schema:
        target, new_root = _resolve_ref(schema["$ref"], root_schema, store)
        _validate(value, target, new_root, store, path, errors)
        return

    if "type" in schema and not _types_ok(value, schema["type"]):
        errors.append("%s: expected type %s, got %s" % (path, schema["type"], type(value).__name__))
        return

    if "const" in schema and value != schema["const"]:
        errors.append("%s: expected const %r, got %r" % (path, schema["const"], value))

    if "enum" in schema and value not in schema["enum"]:
        errors.append("%s: %r not in enum %s" % (path, value, schema["enum"]))

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append("%s: shorter than minLength %d" % (path, schema["minLength"]))
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append("%s: longer than maxLength %d" % (path, schema["maxLength"]))

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append("%s: below minimum %s" % (path, schema["minimum"]))
        if "maximum" in schema and value > schema["maximum"]:
            errors.append("%s: above maximum %s" % (path, schema["maximum"]))

    if isinstance(value, dict):
        props = schema.get("properties", {})
        for req in schema.get("required", []):
            if req not in value:
                errors.append("%s: missing required '%s'" % (path, req))
        add = schema.get("additionalProperties", True)
        for key, val in value.items():
            if key in props:
                _validate(val, props[key], root_schema, store, "%s.%s" % (path, key), errors)
            elif add is False:
                errors.append("%s: additional property '%s' not allowed" % (path, key))
            elif isinstance(add, dict):
                _validate(val, add, root_schema, store, "%s.%s" % (path, key), errors)

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append("%s: fewer than minItems %d" % (path, schema["minItems"]))
        items = schema.get("items")
        if isinstance(items, dict):
            for i, item in enumerate(value):
                _validate(item, items, root_schema, store, "%s[%d]" % (path, i), errors)


def validate_against_schema(value, schema_path):
    """Validate ``value`` against the JSON schema at ``schema_path``.
    Returns a list of error strings ([] == valid)."""
    base_dir = os.path.dirname(os.path.abspath(schema_path))
    store = _SchemaStore(base_dir)
    with open(schema_path, "r") as fh:
        schema = json.load(fh)
    errors = []
    _validate(value, schema, schema, store, "$", errors)
    return errors


def validate_envelope(envelope, widget_schema_dir):
    """Validate one widget envelope: the envelope shape against
    ``_envelope.schema.json`` plus the payload against the per-widget-type
    schema.  Returns [] when valid."""
    store = _SchemaStore(widget_schema_dir)
    errors = []
    env_schema = store.get_file("_envelope.schema.json")
    _validate(envelope, env_schema, env_schema, store, "$", errors)
    wt = envelope.get("widget_type") if isinstance(envelope, dict) else None
    if wt:
        fname = "%s.schema.json" % wt
        try:
            payload_schema = store.get_file(fname)
        except FileNotFoundError:
            errors.append("$: no payload schema for widget_type '%s'" % wt)
            return errors
        _validate(
            envelope.get("payload", {}),
            payload_schema,
            payload_schema,
            store,
            "$.payload",
            errors,
        )
    return errors
