#!/usr/bin/env bash
# noetl-local-build.sh — build NoETL Rust components on the Mount Shasta Ranch
# machines instead of GitHub Actions / Google Cloud Build.
#
# Build placement policy (owner decision, 2026-11-27):
#   * Linux / amd64   (x86_64-unknown-linux-gnu binaries, linux/amd64 images, .deb)
#       -> AMD box   kadyapam@10.50.0.89  (32 cores, 60 GB RAM)
#   * Apple Silicon   (aarch64-apple-darwin binaries, linux/arm64 images for the Mac kind)
#       -> Mac Studio (through ~/.cargo-queue, jobs=2)
#   * GitHub Actions: lightweight checks only.  Cloud Build / Cloud Run builds:
#       only with the owner's explicit OK.
#
# The script only builds what is NATIVE for the host it runs on.  It never
# cross-compiles: from the Mac, use `--remote amd` to run the Linux build on the
# AMD box (the tracked tree, including uncommitted edits, is synced over ssh).
#
# Usage:
#   scripts/local-build/noetl-local-build.sh [options]
#
#   --repos LIST        comma list of server,worker,cli,gateway   (default: server,worker,cli)
#   --src-root DIR      directory holding the repo checkouts       (default: <ops>/..)
#   --out DIR           artifact directory (default: ~/noetl-build/out/<platform>-<UTC stamp>)
#   --no-binaries       skip `cargo build --release` + tarballs
#   --image             also build the container image with podman (native arch only)
#   --kind-load NAME    load the built images into kind cluster NAME (implies --image)
#   --push REGISTRY     push images as REGISTRY/<image>:<tag>-<arch>  (explicit only;
#                       needs a prior `podman login`; never done by default)
#   --tag TAG           image/tarball version tag (default: <Cargo version>-g<sha>[-dirty])
#   --remote amd        (Mac only) run this script on the AMD box for the given repos
#   --amd-host HOST     ssh target for --remote amd (default: kadyapam@10.50.0.89)
#   --dry-run           print what would run
#   -h | --help
#
# Output: <out>/<repo>-<tag>-<platform>.tar.gz, SHA256SUMS, build-times.tsv, build.log
set -euo pipefail

REPOS="server,worker,cli"
SRC_ROOT=""
OUT=""
BINARIES=true
IMAGE=false
KIND_CLUSTER=""
PUSH_REGISTRY=""
TAG_OVERRIDE=""
REMOTE=""
AMD_HOST="${NOETL_AMD_HOST:-kadyapam@10.50.0.89}"
DRY=false

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repos) REPOS="$2"; shift 2;;
    --src-root) SRC_ROOT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --no-binaries) BINARIES=false; shift;;
    --image) IMAGE=true; shift;;
    --kind-load) KIND_CLUSTER="$2"; IMAGE=true; shift 2;;
    --push) PUSH_REGISTRY="${2%/}"; IMAGE=true; shift 2;;
    --tag) TAG_OVERRIDE="$2"; shift 2;;
    --remote) REMOTE="$2"; shift 2;;
    --amd-host) AMD_HOST="$2"; shift 2;;
    --dry-run) DRY=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[ -n "$SRC_ROOT" ] || SRC_ROOT="$(cd "$OPS_ROOT/.." && pwd)"

os="$(uname -s)"; arch="$(uname -m)"
case "$os/$arch" in
  Linux/x86_64)  PLATFORM=linux-x86_64;  OCI_PLATFORM=linux/amd64; ARCH_TAG=amd64;;
  Darwin/arm64)  PLATFORM=darwin-arm64;  OCI_PLATFORM=linux/arm64; ARCH_TAG=arm64;;
  *) echo "noetl-local-build: unsupported host $os/$arch. Policy: Linux/amd64 builds run on the AMD box, Apple Silicon builds on the Mac Studio." >&2; exit 2;;
esac

run() { echo "+ $*" >&2; $DRY || "$@"; }

# Heavy commands on the Mac go through the machine-wide build queue (see
# ai-meta agents/rules/build-queue.md).  The AMD box has no queue: it is sized
# for full-parallel builds.
gate() {
  if [ "$os" = Darwin ] && command -v cargo-queue >/dev/null 2>&1 && [ -z "${CARGO_QUEUE_HELD:-}" ]; then
    run cargo-queue run "$@"
  else
    run "$@"
  fi
}

# ---------------------------------------------------------------- remote mode
if [ -n "$REMOTE" ]; then
  [ "$REMOTE" = amd ] || { echo "--remote supports only 'amd'" >&2; exit 2; }
  [ "$os" = Darwin ] || { echo "--remote amd is for the Mac; on the AMD box run the script directly" >&2; exit 2; }
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  rbase="noetl-build/remote-src/$stamp"
  fwd=()
  $BINARIES || fwd+=(--no-binaries)
  $IMAGE && fwd+=(--image)
  [ -n "$KIND_CLUSTER" ] && fwd+=(--kind-load "$KIND_CLUSTER")
  [ -n "$PUSH_REGISTRY" ] && fwd+=(--push "$PUSH_REGISTRY")
  [ -n "$TAG_OVERRIDE" ] && fwd+=(--tag "$TAG_OVERRIDE")
  $DRY && fwd+=(--dry-run)
  for r in ops ${REPOS//,/ }; do
    src="$SRC_ROOT/$r"; [ "$r" = ops ] && src="$OPS_ROOT"
    [ -d "$src/.git" ] || [ -f "$src/.git" ] || { echo "not a git checkout: $src" >&2; exit 2; }
    echo "=== sync $r (tracked files + uncommitted edits) -> $AMD_HOST:~/$rbase/$r" >&2
    # Ship the tracked tree only (never target/ or other untracked build output),
    # plus a tiny .git so the remote can compute the same <version>-g<sha>[-dirty] tag.
    sha="$(git -C "$src" rev-parse --short HEAD)"
    dirty=""; [ -n "$(git -C "$src" status --porcelain --untracked-files=no)" ] && dirty="-dirty"
    if ! $DRY; then
      ssh -o BatchMode=yes "$AMD_HOST" "mkdir -p ~/$rbase/$r"
      git -C "$src" ls-files -z | (cd "$src" && tar --null -T - -czf - 2>/dev/null) \
        | ssh -o BatchMode=yes "$AMD_HOST" "tar -xzf - -C ~/$rbase/$r && echo '$sha$dirty' > ~/$rbase/$r/.noetl-src-rev"
    fi
  done
  rc=0
  run ssh -o BatchMode=yes "$AMD_HOST" "export PATH=\$HOME/.cargo/bin:\$PATH; bash ~/$rbase/ops/scripts/local-build/noetl-local-build.sh --repos $REPOS --src-root ~/$rbase ${fwd[*]:-}" || rc=$?
  # The synced sources are throwaway; cargo output lives in ~/noetl-build/target/<repo>
  # on the AMD box so the next remote build is incremental.
  $DRY || ssh -o BatchMode=yes "$AMD_HOST" "rm -rf ~/$rbase" || true
  echo "Artifacts stay on the AMD box under ~/noetl-build/out/ (see the remote output above)." >&2
  exit $rc
fi

# ---------------------------------------------------------------- local mode
command -v cargo >/dev/null 2>&1 || export PATH="$HOME/.cargo/bin:$PATH"

# macOS: since the 2026-11-25 Command Line Tools update the selected Xcode.app
# linker cannot read the CLT 27.x SDK (`tapi error: malformed file ... unknown
# architecture arm64e.x1-macos`), so every native link fails. If a trivial link
# fails and the CLT toolchain works, use the CLT toolchain for this build only.
if [ "$os" = Darwin ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  _t="$(mktemp -d)"
  if ! printf 'int main(void){return 0;}\n' > "$_t/t.c" || ! cc "$_t/t.c" -o "$_t/t" >/dev/null 2>&1; then
    if [ -d /Library/Developer/CommandLineTools ] && DEVELOPER_DIR=/Library/Developer/CommandLineTools cc "$_t/t.c" -o "$_t/t" >/dev/null 2>&1; then
      export DEVELOPER_DIR=/Library/Developer/CommandLineTools
      echo "NOTE: default Xcode linker cannot link against the installed SDK; using DEVELOPER_DIR=$DEVELOPER_DIR for this build (fix: sudo xcode-select -s /Library/Developer/CommandLineTools, or update Xcode.app)" >&2
    else
      echo "WARNING: a trivial C link fails on this Mac; cargo builds will likely fail at link time" >&2
    fi
  fi
  rm -rf "$_t"
fi
[ -n "$OUT" ] || OUT="$HOME/noetl-build/out/${PLATFORM}-$(date -u +%Y%m%dT%H%M%SZ)"
run mkdir -p "$OUT"
LOG="$OUT/build.log"; TIMES="$OUT/build-times.tsv"
$DRY || printf 'repo\tstep\tseconds\tresult\n' > "$TIMES"

# repo -> "cargo args|binaries|image repo"
spec() {
  case "$1" in
    server)  echo "--locked --bin noetl-control-plane|noetl-control-plane|localhost/noetl-server-rust";;
    worker)  echo "--locked --features duckdb-integration --bin noetl-worker --bin ehdb-selfcheck|noetl-worker ehdb-selfcheck|localhost/noetl-worker";;
    cli)     echo "--locked --bins --features duckdb-integration|noetl ntl|localhost/noetl-cli";;
    gateway) echo "--locked|noetl-gateway|localhost/noetl-gateway";;
    *) return 1;;
  esac
}

cargo_version() { grep -m1 -E '^version *= *"' "$1/Cargo.toml" | cut -d'"' -f2; }
src_rev() {
  if [ -f "$1/.noetl-src-rev" ]; then cat "$1/.noetl-src-rev"; return; fi
  local s; s="$(git -C "$1" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  [ -n "$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null)" ] && s="$s-dirty"
  echo "$s"
}

timed() { # timed <repo> <step> <cmd...>
  local repo="$1" step="$2"; shift 2
  local t0 rc=0; t0="$(date +%s)"
  if $DRY; then echo "+ $*" >&2; else "$@" >>"$LOG" 2>&1 || rc=$?; fi
  local dt=$(( $(date +%s) - t0 ))
  $DRY || printf '%s\t%s\t%s\t%s\n' "$repo" "$step" "$dt" "$([ $rc = 0 ] && echo ok || echo "FAIL($rc)")" >> "$TIMES"
  echo "  $repo $step: ${dt}s $([ $rc = 0 ] && echo ok || echo "FAILED rc=$rc (see $LOG)")" >&2
  return $rc
}

fail=0
for r in ${REPOS//,/ }; do
  s="$(spec "$r")" || { echo "unknown repo '$r' (server|worker|cli|gateway)" >&2; exit 2; }
  IFS='|' read -r cargo_args bins image_repo <<<"$s"
  src="$SRC_ROOT/$r"
  [ -f "$src/Cargo.toml" ] || { echo "missing checkout: $src" >&2; fail=1; continue; }
  tag="${TAG_OVERRIDE:-$(cargo_version "$src")-g$(src_rev "$src")}"
  # Synced (--remote) trees build into a stable per-repo target dir so repeated
  # remote builds are incremental and the throwaway source dir stays small.
  if [ -f "$src/.noetl-src-rev" ] && [ -z "${CARGO_TARGET_DIR:-}" ]; then
    tdir="$HOME/noetl-build/target/$r"
  else
    tdir="${CARGO_TARGET_DIR:-$src/target}"
  fi
  echo "=== $r $tag ($PLATFORM) from $src" >&2

  if $BINARIES; then
    if timed "$r" "cargo-build-release" gate bash -c "cd '$src' && CARGO_TARGET_DIR='$tdir' cargo build --release $cargo_args"; then
      tarball="$OUT/$r-$tag-$PLATFORM.tar.gz"
      $DRY || tar -C "$tdir/release" -czf "$tarball" $bins
      echo "  -> $tarball" >&2
    else
      fail=1
    fi
  fi

  if $IMAGE; then
    [ -f "$src/Dockerfile" ] || { echo "no Dockerfile in $src" >&2; fail=1; continue; }
    img="$image_repo:$tag"
    if timed "$r" "podman-build-$ARCH_TAG" gate podman build --platform "$OCI_PLATFORM" -t "$img" -f "$src/Dockerfile" "$src"; then
      echo "  -> image $img" >&2
      if [ -n "$KIND_CLUSTER" ]; then
        arc="$OUT/$r-$tag-$ARCH_TAG.oci.tar"
        timed "$r" "kind-load" bash -c "podman save -o '$arc' '$img' && KIND_EXPERIMENTAL_PROVIDER=podman kind load image-archive '$arc' --name '$KIND_CLUSTER' && rm -f '$arc'" || fail=1
      fi
      if [ -n "$PUSH_REGISTRY" ]; then
        remote_img="$PUSH_REGISTRY/${image_repo#localhost/}:$tag-$ARCH_TAG"
        timed "$r" "push" bash -c "podman tag '$img' '$remote_img' && podman push '$remote_img'" || fail=1
        echo "  -> pushed $remote_img (single-arch; combine amd64+arm64 with 'podman manifest' if needed)" >&2
      fi
    else
      fail=1
    fi
  fi
done

if ! $DRY; then
  (cd "$OUT" && ls *.tar.gz >/dev/null 2>&1 && { command -v sha256sum >/dev/null && sha256sum *.tar.gz || shasum -a 256 *.tar.gz; } > SHA256SUMS) || true
  echo "--- timings ($TIMES)" >&2; column -t -s $'\t' "$TIMES" >&2 || cat "$TIMES" >&2
fi
echo "artifacts: $OUT" >&2
exit $fail
