#!/usr/bin/env bash
# Compare the EHDB environment these manifests DECLARE against what the cluster
# is actually RUNNING. Read-only.
#
# Why this exists: noetl/ai-meta#265 G5 added EHDB env blocks whose values were
# captured off prod, and a captured value is a representation — true only while
# something forces it to agree. Nothing does. So the claim "applying this is a
# no-op" is checkable rather than asserted, which is the whole of
# `agents/rules/representation-drift.md`.
#
# It reports EVIDENCE, not a verdict: three of the four difference classes below
# have different right answers (a manifest-only variable may be a deliberate
# default-off declaration; a cluster-only variable may be an undeclared live
# setting, which is the ai-meta#267 defect).
#
#   usage: ehdb-env-drift-check.sh [context] [namespace]
set -uo pipefail
CTX="${1:-}"; NS="${2:-noetl}"
K="kubectl"; [ -n "$CTX" ] && K="kubectl --context $CTX"
cd "$(dirname "$0")"

# ⚠ An explicit context is not optional in this repo: the DEFAULT kubectl
# context is PRODUCTION. This script only reads, but say which cluster the
# answer is about.
echo "context: $($K config current-context 2>/dev/null)  namespace: $NS"
echo

pairs() {  # pairs <file> <workload-kind/name>
  local file="$1" obj="$2"
  local declared live
  declared=$(python3 - "$file" <<'PY'
import sys,yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get('kind') not in ('Deployment','StatefulSet'): continue
    for c in d['spec']['template']['spec'].get('containers',[]):
        for e in c.get('env',[]) or []:
            if e['name'].startswith('NOETL_EHDB'):
                print(f"{e['name']}={e.get('value','<ref>')}")
PY
)
  live=$($K -n "$NS" get "$obj" -o json 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for c in d['spec']['template']['spec'].get('containers',[]):
    for e in c.get('env',[]) or []:
        if e['name'].startswith('NOETL_EHDB'):
            print(f\"{e['name']}={e.get('value','<ref>')}\")
")
  if [ -z "$live" ]; then
    echo "  [no such workload in this cluster — nothing to compare]"
    return
  fi
  local only_live only_man
  only_live=$(comm -13 <(printf '%s\n' "$declared" | sort) <(printf '%s\n' "$live" | sort))
  only_man=$(comm -23 <(printf '%s\n' "$declared" | sort) <(printf '%s\n' "$live" | sort))
  if [ -z "$only_live" ] && [ -z "$only_man" ]; then
    echo "  agree ($(printf '%s\n' "$live" | grep -c .) EHDB variables)"
  fi
  # LIVE-ONLY is the ai-meta#267 defect: a re-apply would remove it.
  [ -n "$only_live" ] && { echo "  LIVE but NOT declared (a re-apply would REMOVE these):"; printf '%s\n' "$only_live" | sed 's/^/    - /'; }
  # MANIFEST-ONLY is usually fine — a default-off declaration the cluster has
  # never been given. It is still reported, because "usually" is not "always".
  [ -n "$only_man" ] && { echo "  declared but NOT live (default-off declarations, or drift):"; printf '%s\n' "$only_man" | sed 's/^/    + /'; }
}

for row in \
  "server-rust-deployment-prod.yaml|deploy/noetl-server-rust" \
  "worker-rust-deployment-prod.yaml|deploy/noetl-worker-rust" \
  "worker-system-pool-deployment-prod.yaml|deploy/noetl-worker-system-pool" \
  "cmdbus-writer-statefulset-prod.yaml|sts/noetl-cmdbus-writer" ; do
  f="${row%%|*}"; o="${row##*|}"
  echo "== $f  vs  $o"
  pairs "$f" "$o"
  echo
done

# Positive control. Every check above can report "agree" by finding nothing on
# both sides — a stripped selector, a renamed prefix, a python that failed. If
# the server manifest does not parse to at least one EHDB variable, nothing
# above is evidence.
n=$(python3 - server-rust-deployment-prod.yaml <<'PY'
import sys,yaml
n=0
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get('kind')!='Deployment': continue
    for c in d['spec']['template']['spec'].get('containers',[]):
        n+=sum(1 for e in (c.get('env') or []) if e['name'].startswith('NOETL_EHDB'))
print(n)
PY
)
if [ "${n:-0}" -lt 1 ]; then
  echo "POSITIVE CONTROL FAILED: the server manifest parsed to $n EHDB variables."
  echo "Every 'agree' above was two empty sets agreeing. Fix the parser first."
  exit 2
fi
echo "positive control: the server manifest declares $n EHDB variables (so 'agree' means something)"
