#!/bin/bash -e
################################################################################
##  File:  install-nvidia-container.sh
##  Desc:  Install nvidia container toolkit onto the image
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/install.sh

REPO_URL="https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH)"
GPG_KEY="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
REPO_PATH="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o $GPG_KEY
echo "deb [signed-by=$GPG_KEY] $REPO_URL /" > $REPO_PATH
apt-get update

# Install nvidia container toolkit which available via apt-get
# Using toolsets keep installation order to install dependencies before the package in order to control versions

components=$(get_toolset_value '.nvidia-container.components[] .package')
for package in $components; do
    version=$(get_toolset_value ".nvidia-container.components[] | select(.package == \"$package\") | .version")
    if [[ $version == "latest" ]]; then
        apt-get install --no-install-recommends "$package"
    else
        version_string=$(apt-cache madison "$package" | awk '{ print $3 }' | grep "$version" | head -1)
        apt-get install --no-install-recommends "${package}=${version_string}"
    fi
done

# Configure the container runtime by using the nvidia-ctk command
nvidia-ctk runtime configure --runtime=docker

# Restart the Docker daemon
systemctl restart docker
docker info

# Cleanup custom repositories
rm $GPG_KEY
rm $REPO_PATH
