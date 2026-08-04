#!/bin/bash

HELPER_SCRIPTS=${HELPER_SCRIPTS:-"/imagegeneration/helpers"}

source $HELPER_SCRIPTS/os.sh
source $HELPER_SCRIPTS/etc-environment.sh

DIST_SLUG=""
NVIDIA_DRIVER_PACKAGES=""
CUDA_PACKAGES="cuda-12-9 cuda-toolkit-12-9"
CUDA_MAJOR_VERSION="12"
if is_ubuntu26; then
    DIST_SLUG="ubuntu2604"
    NVIDIA_DRIVER_PACKAGES="linux-modules-nvidia-595-$(uname -r) nvidia-driver-595"
    CUDA_PACKAGES="cuda-toolkit-13-3"
    CUDA_MAJOR_VERSION="13"
elif is_ubuntu24; then
    DIST_SLUG="ubuntu2404"
    NVIDIA_DRIVER_PACKAGES="linux-modules-nvidia-580-aws nvidia-driver-580"
elif is_ubuntu22; then
    DIST_SLUG="ubuntu2204"
    NVIDIA_DRIVER_PACKAGES="cuda-drivers-575"
else
    echo "Unsupported ubuntu version"
    exit 1
fi

set -eox pipefail

# The Full parent pins its image-specific boot stack. Install only the NVIDIA
# module built for that exact kernel, then let compact finalization restore the
# boot-package pin for the GPU image.
if is_ubuntu26; then
    rm -f /etc/apt/preferences.d/runs-on-compact-boot
fi

if [ -f /root/cuda-installed.txt ]; then
    # Verify CUDA and driver installation
    echo "=== CUDA Installation Verification ==="
    su - runner -c "nvcc --version"
    nvidia-smi
    su - runner -c "nvcc --version" | grep "release $CUDA_MAJOR_VERSION"
    rm /root/cuda-installed.txt
    exit 0
fi

echo "cuda installed" > /root/cuda-installed.txt

# Ubuntu 26's parent waits for rolaunch's root resize before it exposes SSH.
# Older parents still use cloud-init for this build-time guard.
if ! is_ubuntu26; then
    cloud-init single --name cc_growpart
    cloud-init single --name cc_resizefs
fi

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

if is_ubuntu24 || is_ubuntu26; then
    # Prefer Ubuntu's prebuilt AWS-kernel modules over CUDA repository DKMS
    # packages. This keeps the driver aligned with the image's linux-aws kernel.
    cat >/etc/apt/preferences.d/ubuntu-nvidia-driver <<'EOF'
Package: nvidia-driver* nvidia-dkms* nvidia-headless* nvidia-kernel* nvidia-utils* nvidia-compute-utils* nvidia-firmware* nvidia-modprobe nvidia-persistenced libnvidia* xserver-xorg-video-nvidia* linux-modules-nvidia*
Pin: release o=Ubuntu
Pin-Priority: 1001
EOF
fi

# Pin CUDA version to 12
# cuda-toolkit vs nvidia-cuda-toolkit:
# - cuda-toolkit is NVIDIA's official package from their repository
# - nvidia-cuda-toolkit is Ubuntu's packaged version of CUDA toolkit (often outdated version)
# So using cuda-toolkit here:
apt install -y --no-install-recommends $NVIDIA_DRIVER_PACKAGES $CUDA_PACKAGES nvidia-container-toolkit

( dpkg -l | grep -E "(nvidia-driver|cuda)" | head -10 ) || true

# Update PATH and LD_LIBRARY_PATH for the installed CUDA major version.
path="/usr/local/cuda-${CUDA_MAJOR_VERSION}/bin"
library_path="/usr/local/cuda-${CUDA_MAJOR_VERSION}/lib64"
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
