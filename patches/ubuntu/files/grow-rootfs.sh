#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[grow-rootfs] $*"
}

root_source="$(findmnt -n -o SOURCE /)"
root_disk="/dev/$(lsblk -nro PKNAME "$root_source" | head -n1)"
root_partnum="$(lsblk -nro PARTN "$root_source" | head -n1)"

if [[ -z "${root_source}" || -z "${root_disk}" || -z "${root_partnum}" ]]; then
  echo "Unable to determine the live root filesystem layout" >&2
  lsblk >&2
  exit 1
fi

if ! command -v growpart >/dev/null 2>&1; then
  echo "growpart is required to expand the builder root filesystem" >&2
  exit 1
fi

log "root source: ${root_source}"
log "root disk: ${root_disk}"
log "root partition number: ${root_partnum}"

set +e
growpart_output="$(growpart "${root_disk}" "${root_partnum}" 2>&1)"
growpart_status=$?
set -e

if [[ ${growpart_status} -ne 0 && "${growpart_output}" != *"NOCHANGE"* ]]; then
  printf '%s\n' "${growpart_output}" >&2
  exit "${growpart_status}"
fi

printf '%s\n' "${growpart_output}"
log "resizing filesystem on ${root_source}"
resize2fs "${root_source}"
df -h /
