#!/usr/bin/env bash
# Prod latency matrix (reduced load). suite.sh OUT
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); OUT=${1:?}; mkdir -p "$OUT"
N_SEQ=${N_SEQ:-12}; N_HOP=${N_HOP:-10}; N_LOAD=${N_LOAD:-16}; C_LOAD=${C_LOAD:-4}; N_AUTH=${N_AUTH:-10}
ARMS=${ARMS:-"noop py await load auth"}
for a in $ARMS; do
  echo "== arm $a"
  case $a in
    noop)  "$HERE/bench.sh" run bench/seq10_noop "$N_SEQ" 1 "$OUT/noop" > "$OUT/noop.log" 2>&1;;
    py)    "$HERE/bench.sh" run bench/seq10_py "$N_SEQ" 1 "$OUT/py" > "$OUT/py.log" 2>&1;;
    await) "$HERE/bench.sh" run bench/await3 "$N_HOP" 1 "$OUT/await" > "$OUT/await.log" 2>&1;;
    load)  "$HERE/bench.sh" run bench/seq10_noop "$N_LOAD" "$C_LOAD" "$OUT/load" > "$OUT/load.log" 2>&1;;
    auth)  "$HERE/auth.sh" "$N_AUTH" "$OUT/auth" > "$OUT/auth.log" 2>&1;;
  esac
  grep -E "runs:|exec.wall|overhead|drive |pickup|hop\.|auth |PASS|FAIL|CHECK" "$OUT/$a.log" | sed 's/^/   /' || true
done
