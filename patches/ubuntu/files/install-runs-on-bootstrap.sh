#!/bin/bash
set -euo pipefail

RUNS_ON_BOOTSTRAP_VERSIONS="${RUNS_ON_BOOTSTRAP_VERSIONS:-v0.1.12 v0.1.9}"

install_runs_on_bootstrap_binaries() {
  local install_root="${1:-}"
  local bootstrap_arch="${2:-$(uname -i)}"
  local bin_dir="${install_root}/usr/local/bin"
  local bootstrap_version=""
  local bootstrap_bin=""

  install -d -m 0755 "${bin_dir}"

  for bootstrap_version in ${RUNS_ON_BOOTSTRAP_VERSIONS}; do
    bootstrap_bin="${bin_dir}/runs-on-bootstrap-${bootstrap_version}"
    curl -L --connect-time 3 --max-time 15 --retry 5 -s \
      "https://github.com/runs-on/bootstrap/releases/download/${bootstrap_version}/bootstrap-${bootstrap_version}-linux-${bootstrap_arch}" \
      -o "${bootstrap_bin}"
    chmod +x "${bootstrap_bin}"
    "${bootstrap_bin}" -h >/dev/null
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  install_runs_on_bootstrap_binaries "$@"
fi
