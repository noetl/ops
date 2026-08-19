#!/usr/bin/env bash
# Apply ci/monitoring/alertpolicies.json to Cloud Monitoring. Idempotent.
#
# noetl/ai-meta#238. Matches existing policies by displayName: PATCH when one
# is already there, POST when it is not. Never deletes -- a policy removed from
# the JSON stays live and is reported, because silently deleting a paging rule
# is a worse failure than leaving a stale one.
#
#   ./ci/monitoring/apply-alertpolicies.sh            # apply
#   ./ci/monitoring/apply-alertpolicies.sh --dry-run  # show what would change
#
# Requires: gcloud logged in as an account with monitoring.alertPolicies.*
# on the project. ⚠ shastaratech@gmail.com is the account for
# shastaratech-noetl-prod -- kadyapam@gmail.com owns the OLD project and will
# produce a confusing permission error here (noetl/ai-meta#204).
set -euo pipefail
cd "$(dirname "$0")/../.."
SPEC="ci/monitoring/alertpolicies.json"
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY=1

PROJECT=$(python3 -c "import json;print(json.load(open('$SPEC'))['project'])")
ACCOUNT="${GCLOUD_ACCOUNT:-shastaratech@gmail.com}"
TOKEN=$(gcloud auth print-access-token --account="$ACCOUNT")
BASE="https://monitoring.googleapis.com/v3/projects/$PROJECT/alertPolicies"

live=$(curl -sf -H "Authorization: Bearer $TOKEN" "$BASE")
# Positive control: a project with zero policies and a failed read look the
# same through `| jq length`. Refuse to proceed if the field is absent entirely.
echo "$live" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'alertPolicies' not in d and d != {}:
    sys.exit('refusing to apply: unexpected list response %s' % list(d)[:5])
" || exit 1

python3 - "$SPEC" "$DRY" "$PROJECT" "$TOKEN" "$live" <<'PY'
import json, subprocess, sys
spec_path, dry, project, token, live_raw = sys.argv[1:6]
spec = json.load(open(spec_path))
live = json.loads(live_raw).get('alertPolicies', [])
by_name = {p['displayName']: p['name'] for p in live}
base = f"https://monitoring.googleapis.com/v3/projects/{project}/alertPolicies"
created = updated = 0

for pol in spec['policies']:
    body = {
        "displayName": pol['displayName'],
        "combiner": "OR",
        "enabled": True,
        "conditions": [{
            "displayName": pol['displayName'],
            "conditionPrometheusQueryLanguage": {
                "query": pol['query'],
                "duration": pol.get('duration', '0s'),
                "evaluationInterval": pol.get('evaluationInterval', '60s'),
            },
        }],
        "notificationChannels": spec['notificationChannels'],
    }
    if pol.get('documentation'):
        body['documentation'] = {"content": pol['documentation'], "mimeType": "text/markdown"}

    existing = by_name.get(pol['displayName'])
    if dry:
        print(("  WOULD UPDATE " if existing else "  WOULD CREATE ") + pol['displayName'])
        continue
    if existing:
        url = f"https://monitoring.googleapis.com/v3/{existing}?updateMask=displayName,combiner,enabled,conditions,notificationChannels,documentation"
        method = "PATCH"; updated += 1
    else:
        url = base; method = "POST"; created += 1
    r = subprocess.run(
        ["curl", "-sf", "-X", method, "-H", f"Authorization: Bearer {token}",
         "-H", "Content-Type: application/json", "-d", json.dumps(body), url],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED {method} {pol['displayName']}: {r.stderr or r.stdout}")
    print(f"  {'updated' if existing else 'created'}: {pol['displayName']}")

if not dry:
    print(f"\n{created} created, {updated} updated, {len(spec['policies'])} declared")
    stale = set(by_name) - {p['displayName'] for p in spec['policies']}
    if stale:
        print("\n⚠ live policies NOT in this file (left untouched, declare or delete deliberately):")
        for s in sorted(stale): print("   ", s)
PY
