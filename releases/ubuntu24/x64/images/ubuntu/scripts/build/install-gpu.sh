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

DEBIAN_ARCH="$(dpkg --print-architecture)"
CUDA_REPO_ARCH=""
case "$DEBIAN_ARCH" in
    amd64)
        CUDA_REPO_ARCH="x86_64"
        ;;
    arm64)
        CUDA_REPO_ARCH="sbsa"
        ;;
    *)
        echo "Unsupported Debian architecture: $DEBIAN_ARCH"
        exit 1
        ;;
esac

# Use the Ubuntu 580 server driver on both arches and the NVIDIA 12.9 toolkit.
# The cuda-12-9 meta-package pulls a 575-era runtime dependency, so avoid it.
GPU_PACKAGES=(nvidia-driver-580-server cuda-toolkit-12-9 nvidia-container-toolkit)

set -eox pipefail

dump_dkms_logs() {
    find /var/lib/dkms -path '*/build/make.log' -print0 2>/dev/null | while IFS= read -r -d '' logfile; do
        echo "=== DKMS log: $logfile ==="
        cat "$logfile" || true
    done
}

dump_apt_logs() {
    apt-cache policy "${GPU_PACKAGES[@]}" || true
    apt-get install -y --no-install-recommends -o Debug::pkgProblemResolver=yes "${GPU_PACKAGES[@]}" || true
}

if [ -f /root/cuda-installed.txt ]; then
    # Verify CUDA and driver installation
    echo "=== CUDA Installation Verification ==="
    su - runner -c "nvcc --version"
    nvidia-smi
    nvidia-smi -L
    rm /root/cuda-installed.txt
    exit 0
fi

echo "cuda installed" > /root/cuda-installed.txt

# Ensure the root partition is resized
cloud-init single --name cc_growpart
cloud-init single --name cc_resizefs

# NVIDIA CUDA drivers and toolkit
DEBIAN_FILE="cuda-keyring_1.1-1_all.deb"
REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/$DIST_SLUG/$CUDA_REPO_ARCH/$DEBIAN_FILE"
wget $REPO_URL
dpkg -i $DEBIAN_FILE && rm $DEBIAN_FILE

apt-get update -qq

# Pin CUDA version to 12
# cuda-toolkit vs nvidia-cuda-toolkit:
# - cuda-toolkit is NVIDIA's official package from their repository
# - nvidia-cuda-toolkit is Ubuntu's packaged version of CUDA toolkit (often outdated version)
# So using cuda-toolkit here:
if ! apt install -y --no-install-recommends "${GPU_PACKAGES[@]}"; then
    dump_apt_logs
    dump_dkms_logs
    exit 1
fi

( dpkg -l | grep -E "(nvidia-driver|cuda)" | head -10 ) || true

# Update PATH and LD_LIBRARY_PATH for CUDA 12
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
