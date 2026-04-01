#!/bin/bash
set -euo pipefail

RUNS_ON_BOOTSTRAP_VERSIONS="${RUNS_ON_BOOTSTRAP_VERSIONS:-v0.1.12 v0.1.9}"

install_runs_on_bootstrap_binaries() {
  local install_root="${1:-}"
  local bin_dir="${install_root}/usr/local/bin"
  local bootstrap_version=""
  local bootstrap_bin=""

  install -d -m 0755 "${bin_dir}"

  for bootstrap_version in ${RUNS_ON_BOOTSTRAP_VERSIONS}; do
    bootstrap_bin="${bin_dir}/runs-on-bootstrap-${bootstrap_version}"
    cat > "${bootstrap_bin}" <<'EOF'
#!/bin/bash
exec /bin/true "$@"
EOF
    chmod 0755 "${bootstrap_bin}"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  install_runs_on_bootstrap_binaries "$@"
fi
