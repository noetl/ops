#!/usr/bin/env bash
# Compare the container IMAGE every workload manifest in ci/manifests declares
# against what the cluster is actually RUNNING. Read-only.
#
# Why this exists (noetl/ai-meta#323): prod is deployed by digest with
# `kubectl set image` / crane, so an `image:` in a manifest is a COPY of a value
# nothing forces it to track. On 2026-09-04 every prod pin was 8-11 releases
# behind live, and a DR re-apply -- the scenario these files exist for -- would
# have rolled prod back past two incident fixes. Reconciling a pin fixes it
# once; this makes the next drift VISIBLE (#323 option 3), which is the honest
# answer to "what forces this to agree?" until something does.
#
# It reports EVIDENCE, not a verdict:
#   agree       the manifest's image equals the running one
#   DIFFERS     an apply would CHANGE the running image (usually a rollback)
#   undeclared  the manifest omits `image:` on purpose (deploy tooling owns it,
#               e.g. the writer STS, noetl/ops#347); an apply keeps live's
#   absent      no such workload in this cluster
#   dev-only    the manifest's image is `localhost/...`, a kind build that can
#               never be a prod pin. dev/ manifests reuse prod workload names, so
#               without this bucket every one of them reads as DIFFERS on prod.
#
#   usage: image-drift-check.sh <context> [manifest-root]
#   exit:  0 nothing differs, 1 something DIFFERS, 2 positive control failed
#
# ⚠ The context is REQUIRED. The default kubectl context in this repo is
# PRODUCTION; this script only reads, but the answer is about one cluster and
# must say which.
set -uo pipefail
CTX="${1:-}"
ROOT="${2:-$(dirname "$0")}"
if [ -z "$CTX" ]; then
  echo "usage: $0 <kube-context> [manifest-root]" >&2
  exit 64
fi
# Python, not bash: macOS ships bash 3.2 (no associative arrays), and a
# heredoc-fed `xargs python3 -` silently parsed ZERO manifests on the first
# draft -- caught only by the positive control below.
exec python3 - "$CTX" "$ROOT" <<'PY'
import json, pathlib, subprocess, sys
import yaml

ctx, root = sys.argv[1], pathlib.Path(sys.argv[2])
print(f"context: {ctx}   manifests: {root}\n")

declared, parse_errors = [], []
for path in sorted(root.rglob("*.yaml")):
    try:
        docs = list(yaml.safe_load_all(path.read_text()))
    except Exception as e:
        parse_errors.append(f"{path}: {e}")
        continue
    for d in docs:
        if not isinstance(d, dict) or d.get("kind") not in ("Deployment", "StatefulSet"):
            continue
        md = d.get("metadata") or {}
        spec = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
        for c in spec.get("containers") or []:
            declared.append((path.relative_to(root), d["kind"], md.get("namespace") or "default",
                             md.get("name"), c.get("name"), c.get("image")))

live_cache = {}
def live_images(kind, ns, name):
    key = (kind, ns, name)
    if key not in live_cache:
        r = subprocess.run(["kubectl", "--context", ctx, "-n", ns, "get", kind.lower(), name, "-o", "json"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            live_cache[key] = None
        else:
            spec = json.loads(r.stdout)["spec"]["template"]["spec"]
            live_cache[key] = {c["name"]: c.get("image") for c in spec.get("containers") or []}
    return live_cache[key]

counts = dict(agree=0, differs=0, undeclared=0, absent=0, dev_only=0)
for rel, kind, ns, name, cont, image in declared:
    live = live_images(kind, ns, name)
    where = f"{rel}  {kind}/{ns}/{name}[{cont}]"
    if live is None:
        counts["absent"] += 1
    elif image and image.startswith("localhost/"):
        counts["dev_only"] += 1
    elif not image:
        counts["undeclared"] += 1
        print(f"  undeclared  {where}  (live: {live.get(cont, '<no such container live>')})")
    elif live.get(cont) == image:
        counts["agree"] += 1
        print(f"  agree       {where}")
    else:
        counts["differs"] += 1
        print(f"  DIFFERS     {where}\n                declared: {image}\n"
              f"                live:     {live.get(cont, '<no such container live>')}")
for e in parse_errors:
    print(f"  PARSE ERROR {e}")

print(f"\ncontainers declared: {len(declared)}   agree: {counts['agree']}   DIFFERS: {counts['differs']}"
      f"   undeclared: {counts['undeclared']}   dev-only: {counts['dev_only']}"
      f"   absent from this cluster: {counts['absent']}"
      f"   parse errors: {len(parse_errors)}")

# Positive control. "0 DIFFERS" is also what a broken parser or an unreachable
# cluster reports, so it is evidence only if something was actually compared.
compared = counts["agree"] + counts["differs"] + counts["undeclared"]
if not declared or compared == 0:
    print(f"POSITIVE CONTROL FAILED: parsed {len(declared)} containers and compared {compared} "
          f"against {ctx}. A clean result means nothing was checked.")
    sys.exit(2)
print(f"positive control: {compared} containers compared against live (so 'agree' means something)")
sys.exit(1 if counts["differs"] else 0)
PY
