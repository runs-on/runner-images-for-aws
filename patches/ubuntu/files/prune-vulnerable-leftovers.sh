#!/bin/bash
# Runs after the toolset install on full images. It closes scanner findings
# that upstream leaves behind (Wiz and Inspector read package metadata, not
# what actually runs):
# - Miniconda bundles the brotlicffi it had when the installer was cut, which
#   can lag the fixed release by weeks.
# - Toolcache Pythons can keep an old *.dist-info next to the upgraded one
#   (PyPy 3.11 shipped pip-24.0 beside pip-26.2.2).
#
# Usage: prune-vulnerable-leftovers.sh [ROOT]  (ROOT defaults to /)
set -euo pipefail

root="${1:-}"
conda_dir="$root/usr/share/miniconda"

if [ -x "$conda_dir/bin/python" ] && "$conda_dir/bin/python" -m pip show brotlicffi >/dev/null 2>&1; then
  # From PyPI: installing from Anaconda's channels at build time would accept
  # Anaconda's terms of service on the image's behalf.
  "$conda_dir/bin/python" -m pip install --upgrade --no-cache-dir --disable-pip-version-check brotlicffi
  # Drop the package cache, which still holds the bundled versions.
  "$conda_dir/bin/conda" clean --all --yes
fi

# Keep only the newest *.dist-info of each package in every site-packages.
prune_stale_dist_info() {
  local site_packages="$1" name
  for name in $(find "$site_packages" -mindepth 1 -maxdepth 1 -type d -name '*-*.dist-info' -printf '%f\n' |
    sed 's/-[^-]*\.dist-info$//' | sort | uniq -d); do
    find "$site_packages" -mindepth 1 -maxdepth 1 -type d -name "$name-*.dist-info" -printf '%f\n' |
      grep -E "^$name-[^-]+\.dist-info$" | sed "s/^$name-//; s/\.dist-info$//" | sort -V | head -n -1 |
      while read -r version; do
        echo "Removing stale $site_packages/$name-$version.dist-info"
        rm -rf "${site_packages:?}/$name-$version.dist-info"
      done
  done
}

for dir in "$root/opt/hostedtoolcache" "$conda_dir"; do
  [ -d "$dir" ] || continue
  find "$dir" -type d -name site-packages -print0 | while IFS= read -r -d '' site_packages; do
    prune_stale_dist_info "$site_packages"
  done
done
