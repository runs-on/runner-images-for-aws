#!/bin/bash

HELPER_SCRIPTS=${HELPER_SCRIPTS:-"/imagegeneration/helpers"}

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

set -eox pipefail

# Ensure the root partition is resized
cloud-init single --name cc_growpart
cloud-init single --name cc_resizefs

# NVIDIA CUDA drivers and toolkit
DEBIAN_FILE="cuda-keyring_1.1-1_all.deb"
REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/$DIST_SLUG/x86_64/$DEBIAN_FILE"
wget $REPO_URL
dpkg -i $DEBIAN_FILE && rm $DEBIAN_FILE

# NVIDIA container toolkit
REPO_URL="https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH)"
GPG_KEY="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
REPO_PATH="/etc/apt/sources.list.d/nvidia-container-toolkit.list"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o $GPG_KEY
echo "deb [signed-by=$GPG_KEY] $REPO_URL /" > $REPO_PATH

apt-get update -qq

# cuda-toolkit vs nvidia-cuda-toolkit:
# - cuda-toolkit is NVIDIA's official package from their repository
# - nvidia-cuda-toolkit is Ubuntu's packaged version of CUDA toolkit (often outdated version)
# So using cuda-toolkit here:
apt install -y --no-install-recommends cuda-drivers cuda-toolkit nvidia-container-toolkit

# Update PATH and LD_LIBRARY_PATH
path="/usr/local/cuda-12/bin"
library_path="/usr/local/cuda-12/lib64"
# Ensure the paths exist
ls -al $path
ls -al $library_path
prepend_etc_environment_path "$path"

# prepend_etc_environment_variable does not check if the variable exists, so fails if not...
if grep "^LD_LIBRARY_PATH=" /etc/environment; then
    prepend_etc_environment_variable "LD_LIBRARY_PATH" "$library_path"
else
    set_etc_environment_variable "LD_LIBRARY_PATH" "$library_path"
fi

# Configure the container runtime by using the nvidia-ctk command
nvidia-ctk runtime configure --runtime=docker

# Restart the Docker daemon
systemctl restart docker
docker info

# Disable nvidia-persistenced service
systemctl disable nvidia-persistenced