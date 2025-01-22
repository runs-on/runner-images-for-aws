#!/bin/bash

set -eo pipefail

. /etc/os-release

DIST_SLUG=""
case $VERSION_CODENAME in
    noble)
        DIST_SLUG="ubuntu2404"
        ;;
    jammy)
        DIST_SLUG="ubuntu2204"
        ;;
    *)
        echo "Unsupported version codename: $VERSION_CODENAME"
        exit 1
        ;;
esac

# NVIDIA CUDA drivers
DEBIAN_FILE="cuda-keyring_1.1-1_all.deb"
REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/$DIST_SLUG/x86_64/$DEBIAN_FILE"
GPG_KEY="/usr/share/keyrings/cuda-archive-keyring.gpg"
REPO_PATH="/etc/apt/sources.list.d/cuda-$DIST_SLUG-x86_64.list"

wget $REPO_URL
sudo dpkg -i $DEBIAN_FILE
apt-get update

package="cuda-drivers"
version="latest"
if [[ $version == "latest" ]]; then
    apt-get install --no-install-recommends "$package"
else
    version_string=$(apt-cache madison "$package" | awk '{ print $3 }' | grep "$version" | head -1)
    apt-get install --no-install-recommends "${package}=${version_string}"
fi

rm $DEBIAN_FILE
rm $GPG_KEY
rm $REPO_PATH

# NVIDIA container toolkit
REPO_URL="https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH)"
GPG_KEY="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
REPO_PATH="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o $GPG_KEY
echo "deb [signed-by=$GPG_KEY] $REPO_URL /" > $REPO_PATH
apt-get update

package="nvidia-container-toolkit"
version="latest"
if [[ $version == "latest" ]]; then
    apt-get install --no-install-recommends "$package"
else
    version_string=$(apt-cache madison "$package" | awk '{ print $3 }' | grep "$version" | head -1)
    apt-get install --no-install-recommends "${package}=${version_string}"
fi

# Configure the container runtime by using the nvidia-ctk command
nvidia-ctk runtime configure --runtime=docker

# Restart the Docker daemon
systemctl restart docker
docker info

# Cleanup custom repositories
rm $GPG_KEY
rm $REPO_PATH