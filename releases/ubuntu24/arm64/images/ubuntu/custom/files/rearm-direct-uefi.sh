#!/usr/bin/env bash

set -euo pipefail

if [[ "${IMAGE_OS:-}" != "ubuntu26" ]]; then
  exit 0
fi

state_dir="${DIRECT_UEFI_STATE_DIR:-/var/lib/runs-on-direct-uefi}"
boot_path_file="${DIRECT_UEFI_BOOT_PATH_FILE:-/etc/runs-on-overlay/boot-path}"

[[ "$(dpkg --print-architecture)" == amd64 ]] || {
  echo "Direct UEFI rearm is only valid on Ubuntu 26 x64" >&2
  exit 1
}
[[ -r "${boot_path_file}" && "$(< "${boot_path_file}")" == direct-uefi ]] || {
  echo "Refusing to rearm Direct UEFI outside the direct overlay upper" >&2
  exit 1
}
[[ -r "${state_dir}/expected-boot-current" ]] || {
  echo "Direct UEFI boot-number state is missing" >&2
  exit 1
}

direct_bootnum="$(tr '[:lower:]' '[:upper:]' < "${state_dir}/expected-boot-current")"
[[ "${direct_bootnum}" =~ ^[0-9A-F]{4}$ ]] || {
  echo "Invalid Direct UEFI boot number: ${direct_bootnum}" >&2
  exit 1
}

entry="$(efibootmgr | awk -v boot="${direct_bootnum}" '$0 ~ "^Boot" boot "[* ]" { print; exit }')"
[[ "${entry}" == *"RunsOn direct Linux"* ]] || {
  echo "Boot${direct_bootnum} is not the RunsOn Direct UEFI entry" >&2
  exit 1
}

efibootmgr --bootnext "${direct_bootnum}"
prepared_next="$(efibootmgr | awk -F': ' '/^BootNext:/ { print toupper($2); exit }')"
[[ "${prepared_next}" == "${direct_bootnum}" ]] || {
  echo "Failed to rearm Boot${direct_bootnum} through BootNext" >&2
  exit 1
}

sync
echo "[direct-uefi] rearmed Boot${direct_bootnum} for the requested builder reboot"
