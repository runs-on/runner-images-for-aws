#!/bin/bash
set -euo pipefail

# Installs the RunsOn bootstrap binaries into an image (or, with an argument,
# into the root filesystem mounted there). The user data of a RunsOn stack runs
# /usr/local/bin/runs-on-bootstrap-<tag> and downloads it from GitHub only when
# it is missing, without a checksum, so every tag a supported stack uses must
# be here. On images that boot through rolaunch, rolaunch replaces that file
# with the prefetched agent, and this binary is the fallback when the prefetch
# fails.
#
# Only remove a version once the RunsOn stack versions that use it are
# deprecated.
RUNS_ON_BOOTSTRAP_VERSIONS="v0.1.17 v0.1.12 v0.1.9"

# SHA-256 of each pinned release asset, from the release's checksums.txt. v0.1.9
# publishes only per-asset .md5 files; its hashes match those.
bootstrap_sha256() {
  case "$1-$2" in
    v0.1.17-x86_64) echo 1cb31b7988da2d705256f17b1c3da2956423fac53a2c4a6c36a4f4a4e0b82d86 ;;
    v0.1.17-aarch64) echo 5bebba9f776bb35a6397d7e8bd95991cd7d4f93bd867d6b66c0af8286b7f6ee7 ;;
    v0.1.12-x86_64) echo a387bf964c573daabaf753d42213bfec5931b9a71d01325442253e6caa3dd115 ;;
    v0.1.12-aarch64) echo 9fa9eda93563557a67b6ebcf3311a772c274f71bc2b6121af056b0778f185d2f ;;
    v0.1.9-x86_64) echo 64fcfe5b327b2a75a13846467df2692354618718377ae1465ff847f10651d23b ;;
    v0.1.9-aarch64) echo 8f193935c11050e49abe4ecc81880464ba6b3fd43e43e29baa77d5ba8be255a7 ;;
    *) echo "No pinned SHA-256 for RunsOn bootstrap $1 on $2" >&2; return 1 ;;
  esac
}

install_runs_on_bootstrap_binaries() {
  local install_root="${1:-}"
  local bin_dir="${install_root}/usr/local/bin"
  local arch version sha256 bin download

  # The image is built on an instance of its own architecture.
  arch="$(uname -m)"
  install -d -m 0755 "${bin_dir}"

  for version in ${RUNS_ON_BOOTSTRAP_VERSIONS}; do
    sha256="$(bootstrap_sha256 "${version}" "${arch}")"
    bin="${bin_dir}/runs-on-bootstrap-${version}"
    download="${bin}.download"

    curl -fL --connect-timeout 3 --max-time 15 --retry 5 -s \
      "https://github.com/runs-on/bootstrap/releases/download/${version}/bootstrap-${version}-linux-${arch}" \
      -o "${download}"
    if ! echo "${sha256}  ${download}" | sha256sum -c -; then
      rm -f "${download}"
      echo "RunsOn bootstrap ${version} for ${arch} does not match its pinned SHA-256" >&2
      return 1
    fi
    chmod 0755 "${download}"
    "${download}" -h >/dev/null
    mv -f "${download}" "${bin}"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  install_runs_on_bootstrap_binaries "$@"
fi
