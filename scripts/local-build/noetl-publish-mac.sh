#!/usr/bin/env bash
# noetl-publish-mac.sh — build and publish the Apple Silicon / macOS release artifacts
# on the Mac Studio instead of GitHub's paid macOS and arm64 runners.
#
# Build placement policy (owner decision 2026-11-28, "macOS builds on the Mac"):
#   * cli     -> noetl-v<version>-darwin-arm64.tar.gz  (noetl + ntl, aarch64-apple-darwin)
#   * server  -> ghcr.io/noetl/server:<version>-arm64   (linux/arm64 image, native in the podman VM)
#   * worker  -> ghcr.io/noetl/worker:<version>-arm64   (linux/arm64 image, native in the podman VM)
# The release workflows in those repos skip these jobs on GitHub unless the repo variable
# MACOS_BUILDS_ON_GITHUB (cli) / ARM_BUILDS_ON_GITHUB (server, worker) is 'true'.
#
# Safe by default: without --upload / --push nothing leaves this machine.
#
# Usage (Mac Studio only; Apple Silicon):
#   scripts/local-build/noetl-publish-mac.sh --repo cli|server|worker (--version X.Y.Z | --latest) [options]
#
#   --repo NAME         cli | server | worker
#   --version X.Y.Z     release to build (builds the git tag vX.Y.Z from a fresh shallow clone)
#   --latest            use the latest published GitHub release of the repo
#   --upload            cli: upload the tarball + .sha256 to the GitHub release (gh release upload --clobber)
#   --push              server/worker: push the -arm64 image to GHCR, then dispatch the repo's
#                       assemble-multiarch-manifest workflow (metadata only, ~1 min on GitHub)
#   --create-release    cli --upload: create the release (with generated notes) if it does not exist yet
#   --out DIR           output directory (default ~/noetl-build/out/publish-<repo>-<version>-<UTC stamp>)
#   --dry-run           print the plan, build nothing
#   -h | --help
#
# Credentials (never passed on the command line, never printed):
#   --upload  needs `gh auth login` with the `repo` scope (already the case for kadyapam).
#   --push    needs `podman login ghcr.io` with a token that has write:packages on the noetl packages.
set -euo pipefail

REPO=""; VERSION=""; LATEST=false; UPLOAD=false; PUSH=false; CREATE_RELEASE=false; OUT=""; DRY=false
ORG="${NOETL_GH_ORG:-noetl}"
usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --version) VERSION="${2#v}"; shift 2;;
    --latest) LATEST=true; shift;;
    --upload) UPLOAD=true; shift;;
    --push) PUSH=true; shift;;
    --create-release) CREATE_RELEASE=true; shift;;
    --out) OUT="$2"; shift 2;;
    --dry-run) DRY=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2;;
  esac
done

if [ "$(uname -s)/$(uname -m)" != "Darwin/arm64" ]; then
  echo "noetl-publish-mac: this script builds the Apple Silicon artifacts and must run on the Mac Studio (Darwin/arm64)." >&2
  echo "  Linux/amd64 artifacts are built on the AMD box (scripts/local-build/noetl-local-build.sh)." >&2
  exit 2
fi
case "$REPO" in cli|server|worker) ;; *) echo "--repo must be cli, server or worker" >&2; exit 2;; esac
export PATH="$HOME/.cargo-queue/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$HOME/go/bin:$PATH"
command -v gh >/dev/null || { echo "gh not found" >&2; exit 2; }

if $LATEST; then
  [ -z "$VERSION" ] || { echo "use --version or --latest, not both" >&2; exit 2; }
  VERSION="$(gh release view -R "$ORG/$REPO" --json tagName --jq .tagName)"; VERSION="${VERSION#v}"
fi
[ -n "$VERSION" ] || { echo "need --version X.Y.Z or --latest" >&2; exit 2; }
TAG="v$VERSION"
LATEST_TAG="$(gh release view -R "$ORG/$REPO" --json tagName --jq .tagName 2>/dev/null || true)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
[ -n "$OUT" ] || OUT="$HOME/noetl-build/out/publish-$REPO-$VERSION-$STAMP"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/noetl-publish-$REPO.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "=== $REPO $TAG on $(hostname -s): out=$OUT upload=$UPLOAD push=$PUSH dry-run=$DRY" >&2
if $DRY; then
  echo "+ git clone --depth 1 --branch $TAG https://github.com/$ORG/$REPO.git (temp dir)" >&2
  case "$REPO" in
    cli) echo "+ cargo build --release --bins --features duckdb-integration  (through cargo-queue)"
         echo "+ tar noetl ntl -> noetl-$TAG-darwin-arm64.tar.gz (+ .sha256)"
         $UPLOAD && echo "+ gh release upload $TAG <tarball> <sha256> -R $ORG/cli --clobber";;
    *)   echo "+ ci/stamp-version.sh $VERSION; podman build --platform linux/arm64 -t ghcr.io/$ORG/$REPO:$VERSION-arm64  (through cargo-queue)"
         $PUSH && echo "+ podman push ghcr.io/$ORG/$REPO:$VERSION-arm64; gh workflow run assemble-multiarch-manifest.yml -R $ORG/$REPO -f version=$VERSION";;
  esac >&2
  exit 0
fi

# Refuse to publish before checking we are allowed to, so a long build is not wasted.
if $UPLOAD; then gh auth status >/dev/null 2>&1 || { echo "gh is not logged in (gh auth login, repo scope)" >&2; exit 3; }; fi
if $PUSH; then
  podman login --get-login ghcr.io >/dev/null 2>&1 || { echo "podman is not logged in to ghcr.io. Needed: a GitHub token with write:packages (podman login ghcr.io)." >&2; exit 3; }
fi

# Since the 2026-11-25 CLT update the selected Xcode.app linker could not read the CLT SDK; the owner
# fixed it with `xcode-select -s /Library/Developer/CommandLineTools` (verified 2026-11-28). Keep the
# probe as a fallback so a regression gives a clear message instead of a wall of tapi errors.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  printf 'int main(void){return 0;}\n' > "$WORK/t.c"
  if ! cc "$WORK/t.c" -o "$WORK/t" >/dev/null 2>&1; then
    if DEVELOPER_DIR=/Library/Developer/CommandLineTools cc "$WORK/t.c" -o "$WORK/t" >/dev/null 2>&1; then
      export DEVELOPER_DIR=/Library/Developer/CommandLineTools
      echo "NOTE: default linker broken; using DEVELOPER_DIR=$DEVELOPER_DIR" >&2
    else
      echo "WARNING: a trivial C link fails on this Mac; the build will likely fail" >&2
    fi
  fi
fi

# Heavy commands go through the machine-wide build queue (ai-meta agents/rules/build-queue.md).
gate() { if command -v cargo-queue >/dev/null 2>&1 && [ -z "${CARGO_QUEUE_HELD:-}" ]; then cargo-queue run "$@"; else "$@"; fi; }

mkdir -p "$OUT"
SRC="$WORK/src"
echo "--- fetching $ORG/$REPO $TAG" >&2
git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" "https://github.com/$ORG/$REPO.git" "$SRC" \
  || { echo "tag $TAG not found in $ORG/$REPO" >&2; exit 4; }
SHA="$(git -C "$SRC" rev-parse --short HEAD)"
t0=$(date +%s)

case "$REPO" in
cli)
  CV="$(grep -m1 -E '^version *= *"' "$SRC/Cargo.toml" | cut -d'"' -f2)"
  [ "$CV" = "$VERSION" ] || { echo "Cargo.toml says $CV but the tag is $VERSION (release.yml has the same check)" >&2; exit 4; }
  export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/noetl-build/target/mac-cli}"
  mkdir -p "$CARGO_TARGET_DIR"
  echo "--- cargo build --release (target dir $CARGO_TARGET_DIR)" >&2
  # Same command as release.yml: duckdb-integration is part of every distributed binary.
  gate bash -c "cd '$SRC' && cargo build --release --bins --features duckdb-integration" >"$OUT/build.log" 2>&1 \
    || { echo "build failed, see $OUT/build.log" >&2; tail -20 "$OUT/build.log" >&2; exit 5; }
  got="$("$CARGO_TARGET_DIR/release/noetl" --version 2>&1 | head -1)"
  case "$got" in *"$VERSION"*) ;; *) echo "built binary reports '$got', expected $VERSION" >&2; exit 5;; esac
  TARBALL="$OUT/noetl-$TAG-darwin-arm64.tar.gz"
  tar -C "$CARGO_TARGET_DIR/release" -czf "$TARBALL" noetl ntl
  (cd "$OUT" && shasum -a 256 "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256")
  echo "built $TARBALL ($(basename "$TARBALL").sha256) in $(( $(date +%s) - t0 ))s; binary: $got" >&2
  if $UPLOAD; then
    if ! gh release view "$TAG" -R "$ORG/cli" >/dev/null 2>&1; then
      if $CREATE_RELEASE; then gh release create "$TAG" -R "$ORG/cli" --verify-tag --generate-notes --title "$TAG" >&2
      else echo "release $TAG does not exist yet (the release workflow creates it). Re-run later or add --create-release." >&2; exit 6; fi
    fi
    gh release upload "$TAG" "$TARBALL" "$TARBALL.sha256" -R "$ORG/cli" --clobber >&2
    echo "uploaded to https://github.com/$ORG/cli/releases/tag/$TAG" >&2
  fi
  ;;
server|worker)
  [ -f "$SRC/Dockerfile" ] || { echo "no Dockerfile in $REPO $TAG" >&2; exit 4; }
  if [ -x "$SRC/ci/stamp-version.sh" ] || [ -f "$SRC/ci/stamp-version.sh" ]; then
    # Same as release.yml: the tag is authoritative, Cargo.toml in the tree is only a floor.
    (cd "$SRC" && bash ci/stamp-version.sh "$VERSION") >&2
  fi
  IMG="ghcr.io/$ORG/$REPO:$VERSION-arm64"
  echo "--- podman build --platform linux/arm64 $IMG" >&2
  gate podman build --platform linux/arm64 -t "$IMG" -f "$SRC/Dockerfile" "$SRC" >"$OUT/build.log" 2>&1 \
    || { echo "build failed, see $OUT/build.log" >&2; tail -20 "$OUT/build.log" >&2; exit 5; }
  arch="$(podman image inspect "$IMG" --format '{{.Architecture}}')"
  [ "$arch" = arm64 ] || { echo "image architecture is '$arch', expected arm64" >&2; exit 5; }
  echo "built $IMG ($arch, $(podman image inspect "$IMG" --format '{{.Size}}') bytes) in $(( $(date +%s) - t0 ))s" >&2
  if $PUSH; then
    podman push "$IMG" >&2
    ML=true; [ "$TAG" = "$LATEST_TAG" ] || ML=false
    gh workflow run assemble-multiarch-manifest.yml -R "$ORG/$REPO" -f version="$VERSION" -f move_latest="$ML" >&2 \
      || { echo "pushed $IMG, but could not dispatch assemble-multiarch-manifest.yml (not merged to main yet?). Run it by hand." >&2; exit 6; }
    echo "pushed $IMG; assemble-multiarch-manifest dispatched (move_latest=$ML)" >&2
  fi
  ;;
esac
printf '{"repo":"%s","version":"%s","commit":"%s","host":"%s","seconds":%s}\n' "$REPO" "$VERSION" "$SHA" "$(hostname -s)" "$(( $(date +%s) - t0 ))" > "$OUT/result.json"
echo "output: $OUT" >&2
