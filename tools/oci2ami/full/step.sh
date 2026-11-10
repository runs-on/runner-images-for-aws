#!/bin/bash
# Runs one provisioner script the way packer's shell provisioner does
# (`sudo sh -c '<vars> <script>'`): from a temporary copy, as root, with the
# variables of the template. `step.sh pwsh <script>` runs a PowerShell one.
set -euo pipefail
runner=sh
if [[ "$1" == pwsh ]]; then runner=pwsh; shift; fi
for script in "$@"; do
  echo "=== oci build step: $script"
  tmp=$(mktemp /tmp/script_XXXX.${script##*.})
  cp "$script" "$tmp"; chmod 0755 "$tmp"
  if [[ $runner == pwsh ]]; then pwsh -f "$tmp"; else sh -c "$tmp"; fi
  rm -f "$tmp"
done
