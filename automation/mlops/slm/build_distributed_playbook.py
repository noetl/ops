#!/usr/bin/env python3
"""Generate the distributed-capable SLM dataset_build playbook.

The committed ``dataset_build.yaml`` runs a ``kind: shell`` step that invokes
``slm_dataset_build.py`` against on-disk lib + config + schemas + seed.  That is
fine for ``noetl ... -r local`` (the files are on the box running the CLI), but
it **cannot run ``-r distributed``**: the command is dispatched over NATS to a
worker pod that does not have the ops/travel repos on its filesystem, so the
shell step fails with file-not-found.

This generator produces a self-contained ``kind: python`` playbook (the same
embed pattern ``playbooks/itinerary-planner.yaml`` uses for its extract/render
steps) that carries everything the engine needs as a base64-packed file tree.
The worker unpacks it to a tmp dir, runs the **unmodified** engine
(``slm_dataset_build.build``), and returns the manifest + labels as structured
JSON — so the distributed run is repeatable and stays in lockstep with the
source-of-truth lib (no forked logic to drift).

Domain-agnostic: every file it packs is discovered from the org
``slm.config.yaml`` (the same config the generic engine reads), plus the ops lib
modules.  A second domain regenerates its own playbook by pointing ``--config``
at its instance.

Usage (from the ops repo root, with the travel submodule checked out as a
sibling so the config's ``../../../../playbooks/...`` refs resolve)::

    python3 automation/mlops/slm/build_distributed_playbook.py \
        --config ../travel/automation/mlops/slm/travel/slm.config.yaml \
        --out automation/mlops/slm/dataset_build_distributed.yaml \
        --path muno/slm/dataset-build-constrained

The emitted playbook is what gets registered to the catalog and run
``-r distributed`` against the worker pool (the worker already has Vertex
Workload-Identity access for the teacher's in-python token mint).
"""

import argparse
import base64
import json
import os
import sys

_LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib")
sys.path.insert(0, _LIB)
import slm_common as C  # noqa: E402

# ops lib modules the engine imports (kept explicit so a stray test file or
# __pycache__ never rides along).
_LIB_MODULES = ["slm_common.py", "slm_schema.py", "slm_teacher.py", "slm_dataset_build.py"]


def _read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def _collect_referenced_files(cfg, cfg_dir):
    """Every on-disk file the engine touches, discovered from the config."""
    dom = cfg["slm_domain"]
    roles = dom.get("roles", [])
    data = dom.get("data", {})
    paths = set()
    # the config file itself
    cfg_path = None
    for r in roles:
        for key in ("output_schema", "system_prompt", "decoding_grammar"):
            p = C.resolve(cfg_dir, r.get(key))
            if p and os.path.isfile(p):
                paths.add(p)
        oref = r.get("deterministic_oracle", {}) or {}
        mod = C.resolve(cfg_dir, oref.get("module"))
        if mod and os.path.isfile(mod):
            paths.add(mod)
        wdir = C.resolve(cfg_dir, r.get("widget_schema_dir"))
        if wdir and os.path.isdir(wdir):
            for fn in sorted(os.listdir(wdir)):
                if fn.endswith(".json"):
                    paths.add(os.path.join(wdir, fn))
    seed = C.resolve(cfg_dir, data.get("seed_corpus"))
    if seed and os.path.isfile(seed):
        paths.add(seed)
    return sorted(paths)


def build_pack(config_path):
    cfg, cfg_dir = C.load_config(config_path)
    config_abs = os.path.abspath(config_path)
    referenced = _collect_referenced_files(cfg, cfg_dir)
    all_paths = referenced + [config_abs]
    # common ancestor so the config's relative refs (../../../../playbooks/...)
    # still resolve once unpacked under <root>/data/<relpath>.
    common = os.path.commonpath(all_paths)
    if os.path.isfile(common):
        common = os.path.dirname(common)

    files = {}
    for p in all_paths:
        if p == config_abs:
            continue  # the config is packed as pre-parsed JSON (see below)
        rel = os.path.relpath(p, common)
        files["data/" + rel] = base64.b64encode(_read_bytes(p)).decode("ascii")
    for mod in _LIB_MODULES:
        files["lib/" + mod] = base64.b64encode(_read_bytes(os.path.join(_LIB, mod))).decode("ascii")

    # The worker image has no PyYAML, so the config travels as pre-parsed JSON
    # (parsed here, where PyYAML exists).  load_config reads .json without yaml.
    # The JSON sits at the SAME relative location as the .yaml so its relative
    # refs (../../../../playbooks/...) still resolve once unpacked.
    cfg_rel_yaml = os.path.relpath(config_abs, common)
    cfg_rel_json = os.path.splitext(cfg_rel_yaml)[0] + ".json"
    files["data/" + cfg_rel_json] = base64.b64encode(
        json.dumps(cfg).encode("utf-8")
    ).decode("ascii")

    config_rel = "data/" + cfg_rel_json
    pack = {"files": files, "config_rel": config_rel}
    return pack


# The embedded worker code.  Pure stdlib; unpacks the tree, runs the real engine,
# returns structured JSON.  No braces-in-templating hazards ({{ / {% absent).
_WORKER_CODE = r'''
import base64
import json
import os
import sys
import tempfile

packed = json.loads(base64.b64decode(PACKED_B64).decode("utf-8"))
root = tempfile.mkdtemp(prefix="slm_dist_")
for rel, content_b64 in packed["files"].items():
    dest = os.path.join(root, rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as fh:
        fh.write(base64.b64decode(content_b64))

sys.path.insert(0, os.path.join(root, "lib"))
import slm_dataset_build as D
import slm_common as CC

def _clean(v):
    # minijinja can deliver an unset templated input as the literal string
    # "None" (not "") — treat that and empties as "not provided".
    s = str(v).strip()
    return "" if s.lower() in ("", "none", "null") else s

config_path = os.path.join(root, packed["config_rel"])
use_teacher = _clean(no_teacher) not in ("1", "true", "yes", "on")
ver = _clean(version) or "v1_constrained"
lim = _clean(limit)
manifest, ds_dir = D.build(
    config_path,
    out_override=os.path.join(root, "out"),
    version_override=ver,
    limit=int(lim) if lim else None,
    use_teacher=use_teacher,
)
train = CC.read_jsonl(manifest["files"]["train"])
ev = CC.read_jsonl(manifest["files"]["eval"])
# strip the worker tmp prefix from file paths so the manifest is portable
manifest["files"] = {"train": "train.jsonl", "eval": "eval.jsonl"}
result = {
    "ok": True,
    "manifest": manifest,
    "validity": manifest.get("validity"),
    "teacher": manifest.get("teacher"),
    "counts": manifest.get("counts"),
    "train": train,
    "eval": ev,
}
'''


def render_playbook(pack, path, description):
    packed_b64 = base64.b64encode(json.dumps(pack).encode("utf-8")).decode("ascii")
    # indent the worker code under the YAML `code: |` block (6 spaces)
    code_lines = []
    code_lines.append('        PACKED_B64 = "%s"' % packed_b64)
    for line in _WORKER_CODE.strip("\n").splitlines():
        code_lines.append("        " + line if line else "")
    code_block = "\n".join(code_lines)

    return PLAYBOOK_TEMPLATE.format(
        path=path,
        description=description,
        code_block=code_block,
    )


PLAYBOOK_TEMPLATE = '''apiVersion: noetl.io/v2
kind: Playbook

metadata:
  name: slm_dataset_build_distributed
  path: {path}
  description: |
    {description}

    GENERATED FILE — do not edit by hand.  Regenerate with
    automation/mlops/slm/build_distributed_playbook.py (it packs the ops lib +
    the org config + contract schemas + seed corpus as a base64 file tree and
    runs the unmodified slm_dataset_build engine on the worker).  Distributed-
    capable: unlike the kind:shell dataset_build.yaml, this carries every file
    the engine needs, so `noetl ... -r distributed` works on a worker pod that
    does not have the repos on disk.  The teacher mints its Vertex Workload-
    Identity token in-python from the pod metadata server (no API key).
    Tracks noetl/ai-meta#140 / #141.

executor:
  profile: local
  version: noetl-runtime/1

workload:
  version: "v1_constrained"
  limit: ""
  no_teacher: ""

workflow:
  - step: start
    desc: Entry point
    tool:
      kind: noop
    next:
      spec: {{ mode: exclusive }}
      arcs:
        - step: build_dataset

  - step: build_dataset
    desc: Unpack the engine + config + corpus and run the real dataset_build
    tool:
      kind: python
      input:
        version: "{{{{ workload.version | default('v1_constrained') }}}}"
        limit: "{{{{ workload.limit | default('') }}}}"
        no_teacher: "{{{{ workload.no_teacher | default('') }}}}"
      code: |
{code_block}
    next:
      spec: {{ mode: exclusive }}
      arcs:
        - step: end

  - step: end
    desc: Done
    tool:
      kind: noop
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True, help="org slm.config.yaml")
    ap.add_argument("--out", required=True, help="output playbook path")
    ap.add_argument("--path", default="muno/slm/dataset-build-constrained",
                    help="catalog path for the generated playbook")
    ap.add_argument("--description",
                    default="Generic SLM dataset_build, distributed-capable (kind:python embed).")
    args = ap.parse_args()

    pack = build_pack(args.config)
    yaml_text = render_playbook(pack, args.path, args.description)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as fh:
        fh.write(yaml_text)
    n_files = len(pack["files"])
    print("wrote %s (%d packed files, %d bytes)" % (args.out, n_files, len(yaml_text)))


if __name__ == "__main__":
    main()
