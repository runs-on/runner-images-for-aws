#!/usr/bin/env bash

set -euo pipefail

if [[ "${IMAGE_OS:-}" != "ubuntu26" ]]; then
  exit 0
fi

variant="${COMPACT_ROOT_VARIANT:-}"
[[ "$(< /etc/runs-on-overlay/boot-path)" == direct-uefi ]] || {
  echo "Ubuntu 26 descendant reboot did not return through Direct UEFI" >&2
  exit 1
}

expected_bootnum="$(tr '[:lower:]' '[:upper:]' < /var/lib/runs-on-direct-uefi/expected-boot-current)"
current_bootnum="$(efibootmgr | awk -F': ' '/^BootCurrent:/ { print toupper($2); exit }')"
[[ "${current_bootnum}" == "${expected_bootnum}" ]] || {
  echo "Expected Direct BootCurrent=${expected_bootnum}, found ${current_bootnum:-missing}" >&2
  exit 1
}

case "${variant}" in
  gpu)
    [[ -x /usr/local/cuda-13/bin/nvcc || -x /usr/local/cuda/bin/nvcc ]] || {
      echo "CUDA from the pre-reboot GPU provisioning pass is missing" >&2
      exit 1
    }
    ;;
  stepsecurity)
    [[ -x /home/agent/agent && -f /etc/systemd/system/agent.service ]] || {
      echo "StepSecurity files from the pre-reboot provisioning pass are missing" >&2
      exit 1
    }
    ;;
  *)
    echo "Unsupported compact descendant variant: ${variant:-unset}" >&2
    exit 1
    ;;
esac

echo "[direct-uefi] ${variant} descendant changes survived the Direct UEFI reboot"
