#!/usr/bin/env bash
# Interleaved before/after (noetl/ai-meta#557): alternate the lat stack between
# two settings and run the suite on each, REPS times, so host drift lands on
# both arms instead of on whichever ran second.
#
#   ab.sh OUT_DIR REPS "<stack.sh set args for A>" "<stack.sh set args for B>"
#
#   ab.sh runs/stage1 2 \
#     "--server-env NOETL_SERVER_ADVANCE_API= --worker-env NOETL_WORKER_LOCAL_DRIVE=" \
#     "--server-env NOETL_SERVER_ADVANCE_API=true --worker-env NOETL_WORKER_LOCAL_DRIVE=true"
#
# Writes OUT_DIR/A-<i>/<arm> and OUT_DIR/B-<i>/<arm>, then OUT_DIR/A and OUT_DIR/B
# (every rep merged per arm) and prints `suite.sh --compare OUT_DIR/A OUT_DIR/B`.
# Env: ARMS, N_SEQ, N_HOP, N_LOAD, C_LOAD, N_AUTH as for suite.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: ab.sh OUT_DIR REPS A_ARGS B_ARGS}; REPS=${2:?}; A_ARGS=${3?}; B_ARGS=${4?}
mkdir -p "$OUT"
for i in $(seq 1 "$REPS"); do
  for side in A B; do
    args=$A_ARGS; [ "$side" = B ] && args=$B_ARGS
    echo "== rep $i side $side: stack.sh set $args"
    # shellcheck disable=SC2086
    [ -n "$args" ] && "$HERE/stack.sh" set $args
    "$HERE/suite.sh" "$OUT/$side-$i"
  done
done
for side in A B; do
  for a in noop py await load auth toollist slots; do
    for i in $(seq 1 "$REPS"); do
      d="$OUT/$side-$i/$a"; [ -d "$d" ] || continue
      mkdir -p "$OUT/$side/$a/children"
      cp "$d"/*.json "$OUT/$side/$a/" 2>/dev/null || true
      [ -d "$d/children" ] && cp "$d"/children/*.json "$OUT/$side/$a/children/" 2>/dev/null || true
      # keep metrics of the first rep only (histogram deltas are per run)
      [ "$i" = 1 ] && cp "$d"/metrics-*.txt "$OUT/$side/$a/" 2>/dev/null || true
      [ -f "$d/auth-client.txt" ] && cat "$d/auth-client.txt" >> "$OUT/$side/$a/auth-client.txt"
    done
  done
done
"$HERE/suite.sh" --compare "$OUT/A" "$OUT/B"
