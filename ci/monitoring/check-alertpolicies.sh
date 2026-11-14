#!/usr/bin/env bash
# Guard `alertpolicies.json` against the shapes that make a policy silently
# useless (noetl/ai-meta#471).
#
# ⚠ WHY THIS EXISTS. Applying this file is a MANUAL step, so the file is a
# representation with no forcing function — exactly the shape
# agents/rules/representation-drift.md describes. On 2026-10-15 the live policy
# had `duration: "0s"` where the committed file documented a 30-minute settle
# window, and a STABLE divergence count of 35 paged immediately and kept paging.
# The mechanism was a missing `duration` key, which `apply-alertpolicies.sh`
# defaults to `0s`.
#
# ⚠⚠ This checks the FILE, not the cloud. A clean run says the committed
# definitions are well-formed; it says NOTHING about whether they are applied.
# Use `--live` for that, and read the skip message rather than the exit code when
# credentials are absent.
#
# Every check prints its denominator, because a guard that examined zero policies
# and a guard that found zero problems produce the same exit code.
set -uo pipefail

FILE="${FILE:-ci/monitoring/alertpolicies.json}"
LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

[ -f "$FILE" ] || { echo "FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" <<'PYEOF'
import json, sys, collections, re
path = sys.argv[1]
raw = json.load(open(path))
pol = raw if isinstance(raw, list) else raw.get("policies", raw)
if not isinstance(pol, list):
    print("FAIL: could not find a policy list in", path); sys.exit(1)

n = len(pol)
print(f"  policies examined: {n}")
# ⚠ Assert the extraction before asserting about it. A parser that found nothing
# would report every check clean — which is exactly what happened on my first
# draft of this guard: it assumed the raw GCP `conditions` shape, found 0
# conditions, and reported "0 missing durations" as a PASS.
if n < 10:
    print(f"FAIL: parsed only {n} policies — the parser is broken, and a broken "
          f"parser makes every check below vacuously clean")
    sys.exit(1)

# The file's own schema: a PromQL query plus a settle window, not raw GCP
# conditions. Asserted so a schema change fails here instead of silently
# disabling the checks.
required = ("displayName", "query", "duration", "evaluationInterval")
shape = [p.get("displayName", "?") for p in pol
         if any(k not in p for k in required)]

fails = []
if shape:
    fails.append(f"policies missing one of {required}: {sorted(set(shape))}")

# ⭐ THE INCIDENT CAUSE. `apply-alertpolicies.sh` defaults a missing `duration`
# to 0s, which turns a documented settle window into "page on the first
# increment". On 2026-10-15 a STABLE divergence count of 35 paged immediately and
# kept paging for exactly this reason.
bad_dur = []
zero_dur = []
for p in pol:
    d = p.get("duration")
    name = p.get("displayName", "?")
    if not isinstance(d, str) or not re.fullmatch(r"\d+s", d or ""):
        bad_dur.append(f"{name} -> {d!r}")
    elif d == "0s" and "0s" not in json.dumps(p.get("documentation", "")):
        # 0s is legitimate for a genuinely instant condition, but it must SAY so,
        # because 0s is also what the apply script produces from an omission.
        zero_dur.append(name)
if bad_dur:
    fails.append(f"durations that are absent or not `<digits>s`: {sorted(bad_dur)}")
if zero_dur:
    fails.append("policies with duration 0s and no explanation in documentation "
                 f"(0s is also what an OMITTED duration becomes): {sorted(zero_dur)}")

# A policy nobody can read is a policy nobody can triage at 3am.
undoc = [p.get("displayName", "?") for p in pol
         if not str(p.get("documentation", "")).strip()]
if undoc:
    fails.append(f"policies with empty documentation: {sorted(undoc)}")

# Duplicate names make `apply` ambiguous about which policy it updates.
dupes = [k for k, v in collections.Counter(
    p.get("displayName", "?") for p in pol).items() if v > 1]
if dupes:
    fails.append(f"duplicate displayNames: {sorted(dupes)}")

# A query that references no metric cannot fire.
nometric = [p.get("displayName", "?") for p in pol
            if not re.search(r"[a-z_]+_[a-z_]+", str(p.get("query", "")))]
if nometric:
    fails.append(f"queries with no metric-shaped identifier: {sorted(nometric)}")

if fails:
    print(f"\nFAIL ({len(fails)} problem class(es)):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print(f"  OK: {n} policies — every one has a PromQL query, an explicit "
      f"`<digits>s` duration, an evaluation interval, documentation, and a "
      f"unique name")
PYEOF
rc=$?
[ $rc -ne 0 ] && exit $rc

if [ "$LIVE" -eq 1 ]; then
  echo
  echo "=== --live: committed vs applied ==="
  if ! command -v gcloud >/dev/null 2>&1; then
    # ⚠ SKIPPED LOUDLY. A silent skip here is the failure this guard exists to
    # prevent, one level up: "the check ran and found nothing" would be
    # indistinguishable from "the check could not run".
    echo "  SKIPPED: gcloud is not installed — this says NOTHING about live drift."
    exit 0
  fi
  TOK=$(gcloud auth print-access-token --account="${GCLOUD_ACCOUNT:-shastaratech@gmail.com}" 2>/dev/null)
  if [ -z "$TOK" ]; then
    echo "  SKIPPED: no access token — this says NOTHING about live drift."
    exit 0
  fi
  PROJ="${PROJECT_ID:-shastaratech-noetl-prod}"
  curl -s -H "Authorization: Bearer $TOK" \
    "https://monitoring.googleapis.com/v3/projects/$PROJ/alertPolicies" \
  | FILE="$FILE" python3 - <<'PY'
import json, os, sys
live = json.load(sys.stdin).get("alertPolicies", [])
raw = json.load(open(os.environ["FILE"]))
pol = raw if isinstance(raw, list) else raw.get("policies", raw)
ln = {p.get("displayName") for p in live}
# Channels are attached by the apply script, not committed, so this is the only
# place the delivery path can be checked at all.
nochan = sorted(p.get("displayName") for p in live if not p.get("notificationChannels"))
if nochan:
    print(f"  ⚠ LIVE POLICIES WITH NO NOTIFICATION CHANNEL ({len(nochan)}) — these reach nobody:")
    for d in nochan: print(f"      {d}")
cn = {p.get("displayName") for p in pol}
print(f"  live: {len(live)}   committed: {len(pol)}   (the denominators)")
only_c = sorted(cn - ln)
only_l = sorted(ln - cn)
if only_c:
    print(f"  ⚠ COMMITTED BUT NOT APPLIED ({len(only_c)}):")
    for d in only_c: print(f"      {d}")
if only_l:
    print(f"  ⚠ LIVE BUT NOT COMMITTED ({len(only_l)}):")
    for d in only_l: print(f"      {d}")
# Field-level: the one that caused the incident.
by_l = {p.get("displayName"): p for p in live}
for p in pol:
    d = p.get("displayName")
    l = by_l.get(d)
    if not l: continue
    ct = p.get("duration")
    lt = next((
        (c.get("conditionThreshold") or {}).get("duration")
        for c in l.get("conditions", [])
        if (c.get("conditionThreshold") or {}).get("duration") is not None
    ), None)
    if ct is not None and lt is not None and ct != lt:
        # ⭐ The 2026-10-15 incident in one line: committed 1800s, live 0s.
        print(f"  ⚠ DURATION DRIFT on {d!r}: committed={ct!r} live={lt!r}")
if not only_c and not only_l:
    print("  no membership drift")
PY
fi
