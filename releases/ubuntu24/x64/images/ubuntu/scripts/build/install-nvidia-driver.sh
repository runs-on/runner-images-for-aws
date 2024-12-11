#!/bin/bash -e
################################################################################
##  File:  install-nvidia-driver.sh
##  Desc:  Install nvidia driver onto the image
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/install.sh

DEBIAN_FILE="cuda-keyring_1.1-1_all.deb"
REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/$DEBIAN_FILE"
GPG_KEY="/usr/share/keyrings/cuda-archive-keyring.gpg"
REPO_PATH="/etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list"

wget $REPO_URL
sudo dpkg -i $DEBIAN_FILE
apt-get update

# Install nvidia container toolkit which available via apt-get
# Using toolsets keep installation order to install dependencies before the package in order to control versions

components=$(get_toolset_value '.nvidia-driver.components[] .package')
for package in $components; do
    version=$(get_toolset_value ".nvidia-driver.components[] | select(.package == \"$package\") | .version")
    if [[ $version == "latest" ]]; then
        apt-get install --no-install-recommends "$package"
    else
        version_string=$(apt-cache madison "$package" | awk '{ print $3 }' | grep "$version" | head -1)
        apt-get install --no-install-recommends "${package}=${version_string}"
    fi
done

# Cleanup custom repositories
rm $DEBIAN_FILE
rm $GPG_KEY
rm $REPO_PATH
