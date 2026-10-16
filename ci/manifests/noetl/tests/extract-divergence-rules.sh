#!/usr/bin/env bash
# Project the cross-store-divergence conditions out of the Cloud Monitoring
# alert-policy file so `promtool` can evaluate them.
#
# WHY A PROJECTION AND NOT A SECOND COPY
#
# These two conditions ship as Cloud Monitoring alertPolicies — the one
# alerting path that actually delivers (noetl/ai-meta#238; the GMP `Rules`
# path is inert).  promtool cannot read that format, so the expressions have
# to be restated in prometheus form to be testable.
#
# Restating them BY HAND would make this file a representation of the policy
# file with nothing forcing the two to agree: edit the shipped query, and the
# test keeps passing against the stale expression it still holds.  That is the
# failure mode `agents/rules/representation-drift.md` is about, and it is
# exactly how the live `duration: 0s` survived against a committed 1800s
# (noetl/ai-meta#471).  So the expressions live in ONE place —
# ci/monitoring/alertpolicies.json, the artifact that is applied — and this
# reads them.
#
# Mirrors the sibling extract-rules.sh, which does the same for the GMP-hosted
# mirror-lag rules.
set -euo pipefail
cd "$(dirname "$0")"
src="../../../monitoring/alertpolicies.json"
out="rules-ehdb-divergence.promql.yaml"
python3 - "$src" "$out" <<'PY'
import json, sys, yaml

# displayName -> alertname used by alerts-ehdb-divergence.test.yaml.
# Explicit rather than derived so that renaming a policy fails loudly here
# instead of silently orphaning its tests.
WANT = {
    "NoETL EHDB: tier diverged from the authoritative event log":
        "EhdbTierDiverged",
    "NoETL EHDB: tier content diverged from the authoritative event log":
        "EhdbTierContentDiverged",
    "NoETL EHDB: the mirror is re-delivering events in bulk":
        "EhdbMirrorRedeliveringInBulk",
}
MARKER = "noetl_ehdb_crossstore_divergence_total"

policies = json.load(open(sys.argv[1]))["policies"]
by_name = {p.get("displayName"): p for p in policies}

# Print the denominator: a projection that examined nothing must not read the
# same as a clean one.
matched = [n for n in WANT if n in by_name]
found = [p.get("displayName") for p in policies
         if MARKER in json.dumps(p)]
print(f"  policies in file={len(policies)} "
      f"referencing {MARKER}={len(found)} mapped={len(matched)}")

missing = sorted(set(WANT) - set(by_name))
if missing:
    sys.exit("  FAIL: mapped policy absent from the file: "
             + "; ".join(missing))
unmapped = sorted(set(found) - set(WANT))
if unmapped:
    sys.exit("  FAIL: divergence policy with no test mapping (add it to WANT "
             "and write its cases): " + "; ".join(unmapped))

rules = []
for name, alertname in WANT.items():
    pol = by_name[name]
    expr = pol["query"]
    if MARKER not in expr:
        sys.exit(f"  FAIL: {name!r} no longer queries {MARKER}")
    rules.append({
        "alert": alertname,
        "expr": expr,
        "for": pol["duration"],          # verbatim; no re-expression
        "labels": {"severity": "page"},
        "annotations": {"displayName": name},
    })
    print(f"    {alertname}: for={pol['duration']} expr={expr}")

yaml.safe_dump(
    {"groups": [{"name": "ehdb-crossstore-divergence",
                 "interval": "30s",
                 "rules": rules}]},
    open(sys.argv[2], "w"), sort_keys=False, default_flow_style=False,
    width=10000)
PY
echo "wrote $out"
