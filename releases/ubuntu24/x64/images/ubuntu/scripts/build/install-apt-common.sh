#!/bin/bash -e
################################################################################
##  File:  install-apt-common.sh
##  Desc:  Install basic command line utilities and dev packages
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/install.sh

common_packages=$(get_toolset_value .apt.common_packages[])
cmd_packages=$(get_toolset_value .apt.cmd_packages[])
packages=()
while IFS= read -r package; do
    [[ -z "$package" ]] && continue
    # Ubuntu 24+ exposes netcat only as a virtual package; install a concrete provider.
    [[ "$package" == "netcat" ]] && package="netcat-openbsd"
    packages+=("$package")
done < <(printf "%s\n%s\n" "$common_packages" "$cmd_packages")

/usr/bin/apt-get install --no-install-recommends "${packages[@]}"

if command -v nc >/dev/null && ! command -v netcat >/dev/null; then
    ln -s "$(command -v nc)" /usr/local/bin/netcat
fi

invoke_tests "Apt"
