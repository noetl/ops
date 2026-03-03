#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
OPS_REPO_DIR="${2:-.}"
CLI_REPO_DIR="${3:-${OPS_REPO_DIR}/vendor/cli}"
HOMEBREW_TARGET="${4:-${OPS_REPO_DIR}/vendor/homebrew-tap}"
APT_TARGET="${5:-${OPS_REPO_DIR}/vendor/apt}"
ARTIFACTS_ROOT="${6:-${OPS_REPO_DIR}/build/release}"
APT_ARCHES="${7:-amd64,arm64}"
MACOS_ARCHES="${8:-arm64,x86_64}"
BUILD_ARTIFACTS="${9:-true}"
PREFER_RELEASE_ASSETS="${10:-true}"
PUSH_CHANGES="${11:-true}"
HOMEBREW_REMOTE="${12:-git@github.com:noetl/homebrew-tap.git}"
APT_REMOTE="${13:-git@github.com:noetl/apt.git}"
CLI_REMOTE="${14:-git@github.com:noetl/cli.git}"
SYNC_CLI="${15:-false}"
CODENAMES="${16:-jammy noble}"

if [[ -z "${VERSION}" ]]; then
  echo "Usage: $0 <version> [ops_repo_dir] [cli_repo_dir] [homebrew_repo] [apt_repo] [artifacts_root] [apt_arches] [macos_arches] [build_artifacts] [prefer_release_assets] [push_changes] [homebrew_remote] [apt_remote] [cli_remote] [sync_cli] [codenames]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="$(cd "${OPS_REPO_DIR}" && pwd)"
resolve_path() {
  local path="$1"
  if [[ "${path}" = /* ]]; then
    echo "${path}"
  else
    echo "${OPS_ROOT}/${path#./}"
  fi
}

CLI_REPO_DIR="$(resolve_path "${CLI_REPO_DIR}")"
HOMEBREW_TARGET="$(resolve_path "${HOMEBREW_TARGET}")"
APT_TARGET="$(resolve_path "${APT_TARGET}")"
ARTIFACTS_ROOT="$(resolve_path "${ARTIFACTS_ROOT}")"
ARTIFACTS_VERSION_DIR="${ARTIFACTS_ROOT}/v${VERSION}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

sha256_url() {
  local url="$1"
  if command -v shasum >/dev/null 2>&1; then
    curl -fsSL "${url}" | shasum -a 256 | awk '{print $1}'
  else
    curl -fsSL "${url}" | sha256sum | awk '{print $1}'
  fi
}

download_release_asset() {
  local asset_name="$1"
  local output_path="$2"
  local url="https://github.com/noetl/cli/releases/download/v${VERSION}/${asset_name}"
  if curl -fsSL "${url}" -o "${output_path}"; then
    echo "Downloaded release asset: ${asset_name}"
    return 0
  fi
  return 1
}

ensure_git_repo() {
  local repo_path="$1"
  local remote_url="$2"
  if git -C "${repo_path}" rev-parse --git-dir >/dev/null 2>&1; then
    return
  fi
  mkdir -p "$(dirname "${repo_path}")"
  git clone "${remote_url}" "${repo_path}"
}

sync_main() {
  local repo_path="$1"
  git -C "${repo_path}" fetch origin
  git -C "${repo_path}" checkout main
  git -C "${repo_path}" pull --ff-only origin main
}

commit_if_changed() {
  local repo_path="$1"
  local message="$2"
  if [[ -n "$(git -C "${repo_path}" status --porcelain)" ]]; then
    git -C "${repo_path}" add -A
    git -C "${repo_path}" commit -m "${message}"
    if [[ "${PUSH_CHANGES}" == "true" ]]; then
      git -C "${repo_path}" push origin main
    fi
  else
    echo "No changes detected in ${repo_path}"
  fi
}

verify_cli_version() {
  local cargo_version
  cargo_version="$(grep -E '^version = ' "${CLI_REPO_DIR}/Cargo.toml" | head -1 | cut -d '"' -f 2)"
  if [[ "${cargo_version}" != "${VERSION}" ]]; then
    echo "CLI Cargo.toml version (${cargo_version}) does not match requested version (${VERSION})"
    exit 1
  fi
}

build_macos_artifacts() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Skipping macOS build on non-macOS host"
    return
  fi

  for arch in ${MACOS_ARCHES//,/ }; do
    local target
    local archive_arch
    case "${arch}" in
      arm64|aarch64)
        target="aarch64-apple-darwin"
        archive_arch="arm64"
        ;;
      x86_64|amd64)
        target="x86_64-apple-darwin"
        archive_arch="x86_64"
        ;;
      *)
        echo "Unsupported macOS arch: ${arch}"
        exit 1
        ;;
    esac

    local archive_path="${ARTIFACTS_VERSION_DIR}/noetl-v${VERSION}-darwin-${archive_arch}.tar.gz"
    if [[ "${PREFER_RELEASE_ASSETS}" == "true" ]] && [[ ! -f "${archive_path}" ]]; then
      download_release_asset "noetl-v${VERSION}-macos-${archive_arch}.tar.gz" "${archive_path}" || true
    fi
    if [[ -f "${archive_path}" ]]; then
      echo "Using existing macOS ${archive_arch} archive"
      continue
    fi

    echo "Building macOS ${archive_arch} binaries"
    (
      cd "${CLI_REPO_DIR}"
      rustup target add "${target}"
      cargo build --release --bins --target "${target}"
      tar -C "target/${target}/release" \
        -czf "${archive_path}" \
        noetl ntl
    )
  done
}

build_linux_artifacts() {
  for arch in ${APT_ARCHES//,/ }; do
    local platform
    local deb_arch
    local tar_arch
    case "${arch}" in
      amd64|x86_64)
        platform="linux/amd64"
        deb_arch="amd64"
        tar_arch="x86_64"
        ;;
      arm64|aarch64)
        platform="linux/arm64"
        deb_arch="arm64"
        tar_arch="arm64"
        ;;
      *)
        echo "Unsupported Linux arch: ${arch}"
        exit 1
        ;;
    esac

    local linux_archive_name="noetl-v${VERSION}-linux-${tar_arch}.tar.gz"
    local deb_pkg_name="noetl_${VERSION}-1_${deb_arch}.deb"
    local linux_archive="${ARTIFACTS_VERSION_DIR}/${linux_archive_name}"
    local deb_pkg="${ARTIFACTS_VERSION_DIR}/${deb_pkg_name}"
    if [[ "${PREFER_RELEASE_ASSETS}" == "true" ]]; then
      [[ -f "${linux_archive}" ]] || download_release_asset "noetl-v${VERSION}-linux-${tar_arch}.tar.gz" "${linux_archive}" || true
      [[ -f "${deb_pkg}" ]] || download_release_asset "noetl_${VERSION}-1_${deb_arch}.deb" "${deb_pkg}" || true
    fi
    if [[ -f "${linux_archive}" && -f "${deb_pkg}" ]]; then
      echo "Using existing Linux ${deb_arch} assets"
      continue
    fi

    echo "Building Linux ${deb_arch} binaries and .deb via Docker (${platform})"
    docker run --rm --platform "${platform}" \
      -e VERSION="${VERSION}" \
      -e DEB_ARCH="${deb_arch}" \
      -e OUT_TAR="${linux_archive_name}" \
      -e OUT_DEB="${deb_pkg_name}" \
      -v "${CLI_REPO_DIR}:/src:ro" \
      -v "${ARTIFACTS_VERSION_DIR}:/dist" \
      rust:1-bookworm \
      bash -lc '
        set -euo pipefail
        export PATH="/usr/local/cargo/bin:${PATH}"
        apt-get update >/dev/null
        apt-get install -y --no-install-recommends build-essential dpkg-dev ca-certificates >/dev/null
        rm -rf /work
        mkdir -p /work
        export CARGO_HOME="/work/cargo"
        export CARGO_TARGET_DIR="/work/target"
        cd /src
        cargo build --release --bins
        tar -C "${CARGO_TARGET_DIR}/release" -czf "/dist/${OUT_TAR}" noetl ntl

        PKG_ROOT="/tmp/noetl_${VERSION}-1_${DEB_ARCH}"
        mkdir -p "${PKG_ROOT}/DEBIAN" "${PKG_ROOT}/usr/bin"
        cp "${CARGO_TARGET_DIR}/release/noetl" "${PKG_ROOT}/usr/bin/noetl"
        cp "${CARGO_TARGET_DIR}/release/ntl" "${PKG_ROOT}/usr/bin/ntl"

        cat > "${PKG_ROOT}/DEBIAN/control" <<EOF
Package: noetl
Version: ${VERSION}-1
Section: utils
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: NoETL <support@noetl.io>
Homepage: https://noetl.io
Description: NoETL workflow automation CLI
EOF

        dpkg-deb --build "${PKG_ROOT}" "/dist/${OUT_DEB}" >/dev/null
      '
    chown "${HOST_UID}:${HOST_GID}" "${linux_archive}" "${deb_pkg}" 2>/dev/null || true
  done
}

update_homebrew_formula() {
  local tarball_url
  local tarball_sha
  tarball_url="https://github.com/noetl/cli/archive/refs/tags/v${VERSION}.tar.gz"
  tarball_sha="$(sha256_url "${tarball_url}")"

  mkdir -p "${HOMEBREW_TARGET}/Formula"
  cat > "${HOMEBREW_TARGET}/Formula/noetl.rb" <<EOF
class Noetl < Formula
  desc "NoETL workflow automation CLI - Execute playbooks locally or orchestrate distributed pipelines"
  homepage "https://noetl.io"
  url "${tarball_url}"
  sha256 "${tarball_sha}"
  license "MIT"
  head "https://github.com/noetl/cli.git", branch: "main"

  depends_on "rust" => :build

  def install
    system "cargo", "install", "--path", ".", "--bins", *std_cargo_args
  end

  test do
    assert_match "noetl", shell_output("#{bin}/noetl --version")
    assert_match "ntl", shell_output("#{bin}/ntl --version")
  end
end
EOF
}

update_apt_repo() {
  mkdir -p "${APT_TARGET}/pool/main"
  cp "${ARTIFACTS_VERSION_DIR}"/noetl_"${VERSION}"-1_*.deb "${APT_TARGET}/pool/main/"

  docker run --rm \
    -e VERSION="${VERSION}" \
    -e CODENAMES="${CODENAMES}" \
    -e HOST_UID="${HOST_UID}" \
    -e HOST_GID="${HOST_GID}" \
    -v "${APT_TARGET}:/repo" \
    -v "${SCRIPT_DIR}/publish_apt.sh:/work/publish_apt.sh:ro" \
    ubuntu:22.04 \
    bash -lc '
      set -euo pipefail
      apt-get update >/dev/null
      apt-get install -y --no-install-recommends dpkg-dev gzip >/dev/null
      bash /work/publish_apt.sh "${VERSION}" "/repo"
      chown -R "${HOST_UID}:${HOST_GID}" /repo/dists /repo/pool
    '
}

mkdir -p "${ARTIFACTS_VERSION_DIR}"

ensure_git_repo "${CLI_REPO_DIR}" "${CLI_REMOTE}"
ensure_git_repo "${HOMEBREW_TARGET}" "${HOMEBREW_REMOTE}"
ensure_git_repo "${APT_TARGET}" "${APT_REMOTE}"

if [[ "${SYNC_CLI}" == "true" ]]; then
  sync_main "${CLI_REPO_DIR}"
fi
sync_main "${HOMEBREW_TARGET}"
sync_main "${APT_TARGET}"

verify_cli_version

if [[ "${BUILD_ARTIFACTS}" == "true" ]]; then
  build_macos_artifacts
  build_linux_artifacts
  (
    cd "${ARTIFACTS_VERSION_DIR}"
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 ./* > checksums.txt
    else
      sha256sum ./* > checksums.txt
    fi
  )
else
  echo "Skipping local artifact build (build_artifacts=false)"
fi

echo "Updating Homebrew formula for v${VERSION}"
update_homebrew_formula
commit_if_changed "${HOMEBREW_TARGET}" "noetl ${VERSION}"

echo "Updating APT repository for v${VERSION}"
update_apt_repo
commit_if_changed "${APT_TARGET}" "noetl ${VERSION}"

echo "Done."
echo "Artifacts: ${ARTIFACTS_VERSION_DIR}"
