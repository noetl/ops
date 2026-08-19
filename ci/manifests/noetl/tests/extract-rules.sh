#!/usr/bin/env bash
# Extract the prometheus-native rule groups out of a GMP `Rules` object so
# promtool can read them.
#
# GMP wraps the standard prometheus rule format in a Kubernetes object
# (`spec.groups`), and `promtool` only understands the bare `groups:` form.
# This is a projection, not a second copy — the rules live in exactly one file
# and this reads them.
set -euo pipefail
cd "$(dirname "$0")"
src="../gmp/rules-ehdb-mirror-lag.yaml"
out="rules-ehdb-mirror-lag.promql.yaml"
python3 - "$src" "$out" <<'PY'
import sys, yaml
doc = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d][0]
yaml.safe_dump({"groups": doc["spec"]["groups"]}, open(sys.argv[2], "w"),
               sort_keys=False, default_flow_style=False, width=10000)
PY
echo "wrote $out"
