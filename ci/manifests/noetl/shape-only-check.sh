#!/usr/bin/env bash
# noetl/ai-meta#323 — keep the prod manifests declaring SHAPE, not version.
#
# The hazard this replaces: every image pin in this directory was BEHIND live,
# because prod is rolled by digest and nothing wrote the digest back. A re-apply
# rolled prod past shipped incident fixes, silently, and only at the moment the
# manifests were load-bearing.
#
# Removing the pins fixes that. This check keeps it fixed — the new failure mode
# is someone re-adding one, which looks like a perfectly ordinary commit.
#
# It also rejects RUNTIME-owned fields. Declaring one makes the manifest fight
# its writer for ownership, and server-side apply then REFUSES the whole object.
# Both `restartedAt` and the watchdog counters were found exactly this way.
#
# Read-only. Exits non-zero on a finding. No cluster access required.
set -uo pipefail
cd "$(dirname "$0")"

PROD_WORKLOADS=(
  server-rust-deployment-prod.yaml
  worker-rust-deployment-prod.yaml
  worker-system-pool-deployment-prod.yaml
  worker-system-pool-shard1-deployment-prod.yaml
  cmdbus-writer-statefulset-prod.yaml
)

# Runtime-owned: written by an operator or a controller, never declared.
RUNTIME_FIELDS='kubectl\.kubernetes\.io/restartedAt|noetl\.io/watchdog-'

fail=0
checked=0
echo "shape-only check — ${#PROD_WORKLOADS[@]} prod workload manifests"

for f in "${PROD_WORKLOADS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "  MISSING: $f — the list is stale, which makes a clean result meaningless"
    fail=1; continue
  fi
  checked=$((checked + 1))

  # An image pin is only a finding when it is UNCOMMENTED.
  if grep -vE '^\s*#' "$f" | grep -qE '^\s*image:.*docker\.pkg\.dev'; then
    echo "  PIN: $f declares a noetl image. Prod is rolled by digest; a pin here"
    echo "       goes stale the moment it is written and rolls prod back on apply."
    fail=1
  fi

  if grep -vE '^\s*#' "$f" | grep -qE "$RUNTIME_FIELDS"; then
    echo "  RUNTIME FIELD: $f declares a field its writer owns. Server-side apply"
    echo "       will refuse the object rather than clobber it."
    fail=1
  fi
done

# ⚠ Print the denominator. A pass computed over zero files is not a pass, and
# without this line it reads exactly like a clean one.
echo "  checked=$checked/${#PROD_WORKLOADS[@]}"
if [[ "$checked" -ne "${#PROD_WORKLOADS[@]}" ]]; then
  echo "  ABORT: did not check every declared workload"
  exit 2
fi

if [[ "$fail" -eq 0 ]]; then
  echo "  OK — manifests declare shape only"
else
  echo "  FAILED — see findings above (noetl/ai-meta#323)"
fi
exit "$fail"
