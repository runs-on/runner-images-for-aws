#!/bin/bash
set -eo pipefail

source $HELPER_SCRIPTS/os.sh
source $HELPER_SCRIPTS/etc-environment.sh

DIST_SLUG=""
if is_ubuntu24; then
    DIST_SLUG="ubuntu2404"
elif is_ubuntu22; then
    DIST_SLUG="ubuntu2204"
else
    echo "Unsupported ubuntu version"
    exit 1
fi

# Ensure the root partition is resized
cloud-init single --name growpart
cloud-init single --name resizefs

# NVIDIA CUDA drivers
DEBIAN_FILE="cuda-keyring_1.1-1_all.deb"
REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/$DIST_SLUG/x86_64/$DEBIAN_FILE"

wget $REPO_URL
dpkg -i $DEBIAN_FILE && rm $DEBIAN_FILE
apt-get update -qq

package="cuda-drivers"
version="latest"
if [[ $version == "latest" ]]; then
    apt-get install --no-install-recommends "$package"
else
    version_string=$(apt-cache madison "$package" | awk '{ print $3 }' | grep "$version" | head -1)
    apt-get install --no-install-recommends "${package}=${version_string}"
fi

apt install nvidia-cuda-toolkit cuda-toolkit -y

# Add CUDA to PATH
path=$(ls /usr/local/cuda-*/bin | head -1)
prepend_etc_environment_path "$path"
library_path=$(ls /usr/local/cuda-*/lib64 | head -1)
prepend_etc_environment_variable "LD_LIBRARY_PATH", "$library_path"

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