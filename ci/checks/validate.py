#!/usr/bin/env python3
"""Pre-merge validation for noetl/ops.

noetl/ai-meta#375.  This repo had no CI at all, while holding the prod
manifests, the Helm charts and the automation playbooks -- a broken YAML
here is not a style problem, it is a deploy that fails at apply time.

Design notes, because both were learned the hard way elsewhere in the fleet:

* **Populations are DISCOVERED, never listed.**  An enumerated file list is
  itself a representation: it drifts the moment someone adds a chart, and a
  check that silently stops covering half the repo reports the same green as
  a healthy one.  (ops#252's PodMonitoring enumerated four worker names, two
  of which never existed, while omitting one that did.)

* **Every check prints its denominator, and FAILS if that denominator is
  implausible.**  "0 failures" is also what a check that examined nothing
  looks like.  Each check here asserts a non-zero population, so a broken
  glob is a red build rather than a clean one.

Helm templates are deliberately excluded from the plain-YAML check: they
carry Go template syntax and are NOT valid YAML by design.  All 36 of them
"fail" a naive yaml.safe_load, which is exactly the false-positive flood that
would get this gate switched off.  They are validated by `helm lint` instead,
which understands the templating.
"""
from __future__ import annotations
import os
import subprocess
import sys

MIN = {"yaml": 200, "shell": 15, "python": 15, "charts": 1, "iap-shell": 10, "iap-labels": 10}


def tracked(*globs: str) -> list[str]:
    out = subprocess.run(["git", "ls-files", *globs], capture_output=True, text=True)
    out.check_returncode()
    return [p for p in out.stdout.split("\n") if p]


def is_helm_template(path: str) -> bool:
    """A file inside a chart's templates/ dir -- identified by a sibling
    Chart.yaml, not by matching a path pattern."""
    parts = path.split("/")
    if "templates" not in parts:
        return False
    chart_root = "/".join(parts[: parts.index("templates")])
    return os.path.exists(os.path.join(chart_root, "Chart.yaml"))


def report(name: str, population: int, failures: list[str]) -> bool:
    floor = MIN.get(name, 1)
    print(f"\n── {name}: examined {population}, failures {len(failures)}")
    if population < floor:
        print(f"   ✗ POPULATION {population} IS BELOW THE FLOOR OF {floor}.")
        print("     The check did not look at what it claims to cover -- a broken")
        print("     glob, a moved directory, or a bad checkout.  Treating a result")
        print("     computed from too few files as a pass is how a gate goes inert.")
        return False
    for f in failures:
        print(f"   ✗ {f}")
    if not failures:
        print("   ✓ clean")
    return not failures


def check_yaml() -> bool:
    try:
        import yaml
    except ImportError:
        print("── yaml: PyYAML is not installed; cannot validate")
        return False
    files = [f for f in tracked("*.yaml", "*.yml") if not is_helm_template(f)]
    skipped = len(tracked("*.yaml", "*.yml")) - len(files)
    print(f"   (excluded {skipped} Helm templates -- Go-templated, not valid YAML;"
          f" helm lint covers them)")
    failures = []
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                list(yaml.safe_load_all(fh))
        except Exception as exc:
            failures.append(f"{f}: {str(exc).splitlines()[0]}")
    return report("yaml", len(files), failures)


def check_charts() -> bool:
    charts = [c[: -len("/Chart.yaml")] for c in tracked("*/Chart.yaml")]
    if not subprocess.run(["which", "helm"], capture_output=True).returncode == 0:
        print("── charts: helm not on PATH; cannot validate")
        return False
    failures = []
    for c in charts:
        r = subprocess.run(["helm", "lint", c], capture_output=True, text=True)
        if r.returncode != 0:
            first = next((ln for ln in r.stdout.splitlines() if "[ERROR]" in ln), "lint failed")
            failures.append(f"{c}: {first.strip()}")
    return report("charts", len(charts), failures)


def check_shell() -> bool:
    files = tracked("*.sh")
    failures = []
    for f in files:
        r = subprocess.run(["bash", "-n", f], capture_output=True, text=True)
        if r.returncode != 0:
            failures.append(f"{f}: {r.stderr.strip().splitlines()[0] if r.stderr.strip() else 'syntax error'}")
    return report("shell", len(files), failures)


def check_python() -> bool:
    files = tracked("*.py")
    failures = []
    for f in files:
        r = subprocess.run([sys.executable, "-m", "py_compile", f], capture_output=True, text=True)
        if r.returncode != 0:
            tail = r.stderr.strip().splitlines()
            failures.append(f"{f}: {tail[-1] if tail else 'compile error'}")
    ok = report("python", len(files), failures)
    subprocess.run(["find", ".", "-name", "__pycache__", "-prune", "-exec", "rm", "-rf", "{}", "+"],
                   capture_output=True)
    return ok


def _iap_playbooks() -> list[str]:
    """Infrastructure-as-Playbook playbooks that drive kubectl: every *.yaml
    under automation/iap/kind/ (discovered)."""
    return [p for p in tracked("automation/iap/kind/*.yaml", "automation/iap/kind/**/*.yaml")]


def check_iap_shell() -> bool:
    """Every `kind: shell` block in an IaP playbook parses as bash once its
    `{{ ... }}` templates are rendered to a placeholder, and every arc points at
    a step that exists.  A shell syntax error in a provisioning playbook is
    otherwise found mid-apply, with half the stack converged."""
    import re
    import yaml
    blocks, failures = 0, []
    for f in _iap_playbooks():
        doc = yaml.safe_load(open(f))
        steps = doc.get("workflow") or []
        names = {s["step"] for s in steps}
        for s in steps:
            for arc in ((s.get("next") or {}).get("arcs") or []):
                if arc["step"] not in names:
                    failures.append(f"{f}: step {s['step']} -> unknown step {arc['step']}")
            tool = s.get("tool") or {}
            if tool.get("kind") != "shell":
                continue
            cmds = tool.get("cmds") or []
            for i, cmd in enumerate(cmds if isinstance(cmds, list) else [cmds]):
                blocks += 1
                rendered = re.sub(r"\{\{.*?\}\}", "X", cmd, flags=re.S)
                r = subprocess.run(["bash", "-n"], input=rendered, capture_output=True, text=True)
                if r.returncode != 0:
                    failures.append(f"{f}: step {s['step']} cmd {i}: {r.stderr.strip().splitlines()[0]}")
    return report("iap-shell", blocks, failures)


def check_iap_labels() -> bool:
    """Every object in a NoETL-provisioned stack carries the ownership labels:
    they are the inventory that drift (orphans) and destroy select on, so an
    unlabelled object is one destroy would silently leave behind."""
    import yaml
    objs, failures = 0, []
    for f in tracked("ci/manifests/log-analytics/*.yaml"):
        for d in yaml.safe_load_all(open(f)):
            if not d:
                continue
            objs += 1
            labels = (d.get("metadata") or {}).get("labels") or {}
            name = f"{f}: {d.get('kind')}/{(d.get('metadata') or {}).get('name')}"
            if labels.get("noetl.io/stack") != "log-analytics" or labels.get("app.kubernetes.io/managed-by") != "noetl":
                failures.append(f"{name}: missing noetl.io/stack / managed-by labels")
            tmpl = ((d.get("spec") or {}).get("template") or {}).get("metadata")
            if tmpl is not None and (tmpl.get("labels") or {}).get("noetl.io/stack") != "log-analytics":
                failures.append(f"{name}: pod template not labelled noetl.io/stack")
    return report("iap-labels", objs, failures)


def main() -> int:
    print("noetl/ops pre-merge validation (noetl/ai-meta#375)")
    results = {
        "yaml": check_yaml(),
        "charts": check_charts(),
        "shell": check_shell(),
        "python": check_python(),
        "iap-shell": check_iap_shell(),
        "iap-labels": check_iap_labels(),
    }
    print("\n" + "─" * 60)
    for name, ok in results.items():
        print(f"  {name:<8} {'OK' if ok else 'FAIL'}")
    failed = [n for n, ok in results.items() if not ok]
    if failed:
        print(f"\nFAILED: {', '.join(failed)}")
        return 1
    print("\nAll checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
