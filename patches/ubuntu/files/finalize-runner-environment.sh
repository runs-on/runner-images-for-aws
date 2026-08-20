#!/usr/bin/env bash

set -euo pipefail

runner_home="$(getent passwd runner | cut -d: -f6)"
if [[ -z "${runner_home}" ]]; then
  echo "Unable to resolve the runner home directory" >&2
  exit 1
fi

sed -i "s|\$HOME|${runner_home}|g" /etc/environment

if grep -qF '$HOME' /etc/environment; then
  echo '/etc/environment still contains a literal $HOME' >&2
  exit 1
fi
