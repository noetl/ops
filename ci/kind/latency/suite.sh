#!/usr/bin/env bash
# The full latency matrix (noetl/ai-meta#557), one arm per directory:
#
#   noop      bench/seq10_noop   n=$N_SEQ  C=1   orchestration only (tool ~0)
#   py        bench/seq10_py     n=$N_SEQ  C=1   the #155 probe shape
#   await     bench/await3       n=$N_HOP  C=1   3 awaited child hops per run
#   load      bench/seq10_noop   n=$N_LOAD C=$C_LOAD   contention: C runs at once
#   auth      check_playbook_access n=$N_AUTH        must stay < 15 s
#   toollist  bench/toollist     n=$N_HOP  C=1   one step, 4-tool list → one command
#   slots     bench/await_slots  n=6 C=6         6 awaiting parents on a 4-slot pool (opt-in: ARMS=slots)
#
#   suite.sh OUT_DIR            → OUT_DIR/{noop,py,await,load,auth}/
#   report.py OUT_DIR/noop OTHER/noop      (before/after per arm)
#   suite.sh --compare BEFORE AFTER        (all arms)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" = "--compare" ]; then
  for a in noop py await load auth toollist slots; do
    [ -d "$2/$a" ] && [ -d "$3/$a" ] || continue
    echo; echo "################ $a"; python3 "$HERE/report.py" "$2/$a" "$3/$a" | sed -n '/== delta/,$p'
  done
  exit 0
fi
OUT=${1:?usage: suite.sh OUT_DIR | --compare BEFORE AFTER}
N_SEQ=${N_SEQ:-20}; N_HOP=${N_HOP:-10}; N_LOAD=${N_LOAD:-32}; C_LOAD=${C_LOAD:-8}; N_AUTH=${N_AUTH:-10}
ARMS=${ARMS:-"noop py await load auth toollist"}
mkdir -p "$OUT"
"$HERE/bench.sh" register >/dev/null
for a in $ARMS; do
  echo "== arm $a"
  case $a in
    noop)  "$HERE/bench.sh" run bench/seq10_noop "$N_SEQ" 1 "$OUT/noop" > "$OUT/noop.log" 2>&1;;
    py)    "$HERE/bench.sh" run bench/seq10_py "$N_SEQ" 1 "$OUT/py" > "$OUT/py.log" 2>&1;;
    await) "$HERE/bench.sh" run bench/await3 "$N_HOP" 1 "$OUT/await" > "$OUT/await.log" 2>&1;;
    load)  "$HERE/bench.sh" run bench/seq10_noop "$N_LOAD" "$C_LOAD" "$OUT/load" > "$OUT/load.log" 2>&1;;
    auth)  "$HERE/auth.sh" "$N_AUTH" "$OUT/auth" > "$OUT/auth.log" 2>&1;;
    toollist) "$HERE/bench.sh" run bench/toollist "$N_HOP" 1 "$OUT/toollist" > "$OUT/toollist.log" 2>&1;;
    slots) "$HERE/bench.sh" run bench/await_slots "${N_SLOTS:-6}" "${C_SLOTS:-6}" "$OUT/slots" > "$OUT/slots.log" 2>&1;;
  esac
  grep -E "runs:|exec.wall|overhead|drive |pickup|hop\.|auth arm|PASS|FAIL" "$OUT/$a.log" | sed 's/^/   /' || true
done
