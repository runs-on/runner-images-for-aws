#!/bin/bash
# Runs provisioner scripts the way packer's shell provisioner does
# (`sudo sh -c '<vars> <script>'`): from a temporary copy, as root.
# `step.sh pwsh <script>...` runs PowerShell ones. A script's edits for the
# container build are in /oci/p/<script name> (patches/ in the context); each
# edit must match, or the build stops: a script that changed upstream must be
# looked at again.
set -euo pipefail
runner=sh
if [[ "$1" == pwsh ]]; then runner=pwsh; shift; fi
edit() { # sed expression, text that must be present afterwards
  sed -i "$1" "$tmp"
  grep -qF -- "$2" "$tmp" || { echo "oci edit did not apply to $name: $1" >&2; exit 1; }
}
# Packer runs each provisioner in a new login, where PAM loads
# /etc/environment (AGENT_TOOLSDIRECTORY and the others that
# configure-environment.sh sets); sudo's secure_path keeps PATH.
if [[ -f /etc/environment ]]; then
  while IFS= read -r line; do
    [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    [[ $k == PATH ]] && continue
    v=${v#\"}; v=${v%\"}
    export "$k=$v"
  done < /etc/environment
fi
# Packer runs scripts from the SSH user's home: what they leave in the
# current directory must not land in /.
work=$(mktemp -d /var/tmp/oci-step.XXXX); cd "$work"
for script in "$@"; do
  name=${script##*/}
  echo "=== oci build step: $name"
  tmp=$(mktemp "/tmp/script_XXXX.${name##*.}")
  cp "$script" "$tmp"; chmod 0755 "$tmp"
  if [[ -f /oci/p/$name ]]; then . "/oci/p/$name"; fi
  if [[ $runner == pwsh ]]; then pwsh -f "$tmp"; else sh -c "$tmp"; fi
  rm -f "$tmp"
done
cd / && rm -rf "$work"
