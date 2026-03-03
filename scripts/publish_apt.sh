#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
REPO_DIR="${2:-.}"
CODENAMES="${CODENAMES:-jammy noble}"

if [[ -z "${VERSION}" ]]; then
  echo "Usage: $0 <version> [repo_dir]"
  exit 1
fi

cd "${REPO_DIR}"
mkdir -p pool/main

if ! ls pool/main/noetl_*.deb >/dev/null 2>&1; then
  echo "No .deb packages found in ${REPO_DIR}/pool/main"
  exit 1
fi

ARCHES=()
while IFS= read -r pkg; do
  pkg_arch="$(basename "${pkg}" | sed -E 's/^noetl_[^-]+-[0-9]+_([^.]+)\.deb$/\1/')"
  case "${pkg_arch}" in
    amd64|arm64)
      if [[ ! " ${ARCHES[*]} " =~ " ${pkg_arch} " ]]; then
        ARCHES+=("${pkg_arch}")
      fi
      ;;
  esac
done < <(find pool/main -maxdepth 1 -type f -name 'noetl_*.deb' | sort)

if [[ "${#ARCHES[@]}" -eq 0 ]]; then
  echo "No supported architectures found (expected amd64 and/or arm64)"
  exit 1
fi

ARCH_LINE="${ARCHES[*]}"

for codename in ${CODENAMES}; do
  rm -rf "dists/${codename}/main"
  mkdir -p "dists/${codename}/main"

  for repo_arch in "${ARCHES[@]}"; do
    dist_dir="dists/${codename}/main/binary-${repo_arch}"
    mkdir -p "${dist_dir}"
    dpkg-scanpackages --multiversion --arch "${repo_arch}" pool/ > "${dist_dir}/Packages"
    gzip -k -f "${dist_dir}/Packages"
    cat > "${dist_dir}/Release" <<EOF
Archive: ${codename}
Component: main
Origin: NoETL
Label: NoETL
Architecture: ${repo_arch}
EOF
  done

  cat > "dists/${codename}/Release" <<EOF
Origin: NoETL
Label: NoETL APT Repository
Suite: ${codename}
Codename: ${codename}
Version: ${VERSION}
Architectures: ${ARCH_LINE}
Components: main
Description: NoETL APT Repository
Date: $(date -Ru)
EOF

  (
    cd "dists/${codename}"
    {
      echo "MD5Sum:"
      find . -type f ! -name 'Release' -print0 \
        | sort -z \
        | xargs -0 md5sum \
        | sed 's|^\([^ ]*\)  \./\(.*\)$| \1|' \
        | paste -d' ' - <(find . -type f ! -name 'Release' | sed 's|^\./||' | sort) \
        | while read -r checksum path; do
            size="$(wc -c < "${path}" | tr -d ' ')"
            printf " %s %16d %s\n" "${checksum}" "${size}" "${path}"
          done
      echo "SHA1:"
      find . -type f ! -name 'Release' -print0 \
        | sort -z \
        | xargs -0 sha1sum \
        | sed 's|^\([^ ]*\)  \./\(.*\)$| \1|' \
        | paste -d' ' - <(find . -type f ! -name 'Release' | sed 's|^\./||' | sort) \
        | while read -r checksum path; do
            size="$(wc -c < "${path}" | tr -d ' ')"
            printf " %s %16d %s\n" "${checksum}" "${size}" "${path}"
          done
      echo "SHA256:"
      find . -type f ! -name 'Release' -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        | sed 's|^\([^ ]*\)  \./\(.*\)$| \1|' \
        | paste -d' ' - <(find . -type f ! -name 'Release' | sed 's|^\./||' | sort) \
        | while read -r checksum path; do
            size="$(wc -c < "${path}" | tr -d ' ')"
            printf " %s %16d %s\n" "${checksum}" "${size}" "${path}"
          done
    } >> Release
  )
done

echo "APT metadata updated for version ${VERSION}"
echo "Architectures: ${ARCH_LINE}"
echo "Codenames: ${CODENAMES}"
