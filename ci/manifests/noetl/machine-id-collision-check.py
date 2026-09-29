#!/usr/bin/env python3
"""Flag any two workloads that could run CONCURRENTLY with the same NOETL_SERVER_MACHINE_ID.

⚠⚠ WHY THIS EXISTS

`NOETL_SERVER_MACHINE_ID` picks the machine bits of the server's snowflake
generator.  Two server processes sharing a value mint overlapping `event_id`s, and
`noetl.event` is APPEND-ONLY — so the damage is not a failed request, it is a
corrupted log that nothing rejects (noetl/ai-meta#332).

On 2026-09-29 the committed prod manifest declared `Deployment/noetl-server-rust`
with `replicas: 1` and `MACHINE_ID=2`, while the serving
`StatefulSet/noetl-server-rust-embedded` also ran `MACHINE_ID=2`.  A routine
`kubectl apply -f` of that file would have created the collision — and two
runbooks instructed exactly that apply, so it was reachable by following
documented steps, not only by accident (noetl/ai-meta#359).

⚠ A workload with `replicas: 0` cannot run, so it cannot collide.  That is why
`replicas: 0` is the fix rather than a comment asking people not to.

⚠⚠ FILE MODE IS CURRENTLY BLIND TO THE COLLISION THIS WAS WRITTEN FOR, and that is
worth stating rather than discovering later.  The two colliding parties were the
prod `Deployment` (in the repo) and the serving `StatefulSet` (NOT in the repo —
it exists only in the live cluster).  A scan of committed manifests can only ever
see one of them, so restoring `replicas: 1` does NOT make file mode fail:
verified 2026-09-29, the RED control passed when it should have failed.

  * `--live` mode DOES see both and is the effective check today.
  * ✅ RESOLVED: `server-rust-embedded-sts-prod.yaml` now commits the serving
    StatefulSet, so file mode sees both parties.  Verified — restoring
    `replicas: 1` on the Deployment reports COLLISION and exits 1; `replicas: 0`
    exits 0.

So the real protection right now is `replicas: 0` itself, which is structural and
does not depend on anything running this script.  Run `--live` in review.

Usage:
    ./machine-id-collision-check.py [DIR]          # committed manifests (default .)
    ./machine-id-collision-check.py --live CONTEXT # the live cluster

Exit 1 on a collision or on an empty scan, 0 when clean.  Always prints the
population examined: "0 collisions" after examining 0 workloads is
indistinguishable from a healthy result, so the denominator is part of the output.
"""
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

MID = "NOETL_SERVER_MACHINE_ID"


def from_live(ctx):
    out = subprocess.run(
        ["kubectl", "--context", ctx, "-n", "noetl", "get",
         "deploy,statefulset", "-o", "json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        print(f"kubectl failed: {out.stderr.strip()[:300]}", file=sys.stderr)
        sys.exit(2)
    rows = []
    for it in json.loads(out.stdout)["items"]:
        reps = it["spec"].get("replicas")
        reps = 1 if reps is None else reps
        for c in it["spec"]["template"]["spec"].get("containers") or []:
            for e in c.get("env") or []:
                if e.get("name") == MID:
                    rows.append((f"{it['kind']}/{it['metadata']['name']}",
                                 reps, e.get("value"), "live"))
    return rows


def from_files(root):
    # ⚠ Regex, not a YAML parse: ops pins no PyYAML, and an ImportError must not
    # turn this check into a silent pass.
    rows = []
    for dp, _, fns in os.walk(root):
        for fn in fns:
            if not fn.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dp, fn)
            try:
                txt = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for doc in txt.split("\n---"):
                k = re.search(r"^kind:\s*(Deployment|StatefulSet)\s*$", doc, re.M)
                mid = re.search(
                    r"name:\s*" + MID + r"\s*\n\s*value:\s*['\"]?(\d+)", doc)
                if not k or not mid:
                    continue
                nm = re.search(r"^\s{0,2}name:\s*(\S+)\s*$", doc, re.M)
                rp = re.search(r"^\s+replicas:\s*(\d+)\s*$", doc, re.M)
                rows.append((
                    f"{k.group(1)}/{nm.group(1) if nm else '?'}",
                    int(rp.group(1)) if rp else 1,
                    mid.group(1),
                    path,
                ))
    return rows


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--live":
        if len(sys.argv) < 3:
            print("--live needs a kube context", file=sys.stderr)
            sys.exit(2)
        rows = from_live(sys.argv[2])
        where = f"live cluster {sys.argv[2]}"
    else:
        root = sys.argv[1] if len(sys.argv) > 1 else "."
        rows = from_files(root)
        where = f"committed manifests under {root}"

    print(f"scanned {where}")
    print(f"workloads declaring {MID}: {len(rows)}   <- the denominator")
    if not rows:
        print(f"\n⚠ examined ZERO workloads. That is not a pass — it means the scan "
              f"found nothing, which a real collision would look identical to.")
        return 1

    by = defaultdict(list)
    for nm, reps, mid, src in rows:
        by[mid].append((nm, reps, src))

    bad = False
    for mid in sorted(by):
        group = by[mid]
        runnable = [r for r in group if r[1] > 0]
        verdict = "COLLISION" if len(runnable) > 1 else "ok"
        print(f"  {MID}={mid}: {len(group)} workload(s), "
              f"{len(runnable)} runnable -> {verdict}")
        for nm, reps, src in group:
            note = "" if reps > 0 else "   (replicas=0 — cannot run, cannot collide)"
            print(f"      {nm:<46} replicas={reps}{note}   {src}")
        if len(runnable) > 1:
            bad = True

    if bad:
        print(f"\n✗ two or more RUNNABLE workloads share a {MID}. Two snowflake "
              f"generators on the same machine bits mint overlapping event_ids into "
              f"an APPEND-ONLY log (noetl/ai-meta#332). Set all but one to "
              f"replicas: 0, or give them distinct ids.")
        return 1
    print(f"\n✓ no {MID} is claimed by more than one runnable workload")
    return 0


if __name__ == "__main__":
    sys.exit(main())
