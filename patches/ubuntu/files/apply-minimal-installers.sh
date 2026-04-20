#!/usr/bin/env bash

set -euo pipefail

ROOTFS_COMPACTION_HELPER="${ROOTFS_COMPACTION_HELPER:-/tmp/rootfs-compaction.sh}"
source "${ROOTFS_COMPACTION_HELPER}"

IMAGE_VERSION="${IMAGE_VERSION:-}"
IMAGE_OS="${IMAGE_OS:-}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
HELPER_SCRIPTS="${HELPER_SCRIPTS:-${IMAGE_FOLDER}/helpers}"
INSTALLER_SCRIPT_FOLDER="${INSTALLER_SCRIPT_FOLDER:-${IMAGE_FOLDER}/installers}"
IMAGEDATA_FILE="${IMAGEDATA_FILE:-${IMAGE_FOLDER}/imagedata.json}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-/mnt/minimal-root}"
MINIMAL_INCLUDE_FULL_INSTALLERS="${MINIMAL_INCLUDE_FULL_INSTALLERS:-false}"
TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR:-}"
TARGET_UBUNTU_SECURITY_MIRROR="${TARGET_UBUNTU_SECURITY_MIRROR:-https://security.ubuntu.com/ubuntu/}"

partition_path() {
  local disk="$1"
  if [[ "$disk" =~ [0-9]$ ]]; then
    echo "${disk}p1"
  else
    echo "${disk}1"
  fi
}

run_logged() {
  local description="$1"
  shift
  echo "[minimal-install] $description"
  "$@"
}

resolve_target_ubuntu_mirror() {
  local region=""
  local token=""

  if [[ -n "${TARGET_UBUNTU_MIRROR}" ]]; then
    echo "${TARGET_UBUNTU_MIRROR}"
    return 0
  fi

  token="$(curl -fsS -m 2 -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    http://169.254.169.254/latest/api/token || true)"
  if [[ -n "${token}" ]]; then
    region="$(curl -fsS -m 2 \
      -H "X-aws-ec2-metadata-token: ${token}" \
      http://169.254.169.254/latest/meta-data/placement/region || true)"
  fi

  if [[ -n "${region}" ]]; then
    echo "http://${region}.ec2.archive.ubuntu.com/ubuntu/"
    return 0
  fi

  echo "http://archive.ubuntu.com/ubuntu/"
}

find_target_disk() {
  local root_source
  local root_disk
  local candidate

  root_source="$(findmnt -n -o SOURCE /)"
  root_disk="/dev/$(lsblk -nro PKNAME "$root_source" | head -n1)"

  while IFS= read -r candidate; do
    if [[ "/dev/$candidate" != "$root_disk" ]]; then
      echo "/dev/$candidate"
      return 0
    fi
  done < <(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" { print $1 }')

  return 1
}

run_in_target() {
  local command="$1"

  chroot "${TARGET_ROOT_MOUNT}" /usr/bin/env \
    "IMAGE_VERSION=${IMAGE_VERSION}" \
    "IMAGE_OS=${IMAGE_OS}" \
    "IMAGE_FOLDER=${IMAGE_FOLDER}" \
    "HELPER_SCRIPTS=${HELPER_SCRIPTS}" \
    "HELPER_SCRIPT_FOLDER=${HELPER_SCRIPTS}" \
    "INSTALLER_SCRIPT_FOLDER=${INSTALLER_SCRIPT_FOLDER}" \
    "IMAGEDATA_FILE=${IMAGEDATA_FILE}" \
    "DEBIAN_FRONTEND=${DEBIAN_FRONTEND}" \
    "SUDO_USER=runner" \
    /bin/bash -lc "${command}"
}

run_installer_script() {
  local script_name="$1"

  case "$script_name" in
    *.ps1)
      run_in_target "pwsh -f ${INSTALLER_SCRIPT_FOLDER}/${script_name}"
      ;;
    *)
      run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/${script_name}"
      ;;
  esac
}

ensure_runner_user() {
  run_in_target "
    set -euo pipefail
    if ! id -u runner >/dev/null 2>&1; then
      useradd --create-home --shell /bin/bash --uid 1001 runner
    fi
  "
}

install_minimal_runtime_packages() {
  run_in_target "
    set -euo pipefail
    apt-get install -y --no-install-recommends \
      netcat-openbsd \
      unzip \
      zip
  "
}

ensure_netcat_alias() {
  run_in_target "
    set -euo pipefail
    if ! command -v netcat >/dev/null 2>&1; then
      ln -sf /usr/bin/nc /usr/bin/netcat
    fi
  "
}

ensure_invoke_tests_stub() {
  run_in_target "
    set -euo pipefail
    if ! command -v pwsh >/dev/null 2>&1; then
      cat > /usr/local/bin/invoke_tests <<'EOF'
#!/bin/bash
echo \"Skipping invoke_tests: pwsh not installed\"
EOF
      chmod +x /usr/local/bin/invoke_tests
    fi
  "
}

ensure_noninteractive_environment() {
  run_in_target "
    set -euo pipefail
    touch /etc/environment
    if grep -q '^DEBIAN_FRONTEND=' /etc/environment; then
      sed -i 's|^DEBIAN_FRONTEND=.*|DEBIAN_FRONTEND=noninteractive|' /etc/environment
    else
      printf '%s\n' 'DEBIAN_FRONTEND=noninteractive' >> /etc/environment
    fi
  "
}

run_minimal_tooling_suite() {
  install_minimal_runtime_packages
  ensure_netcat_alias
  ensure_invoke_tests_stub
  run_installer_script "install-git.sh"
  run_installer_script "install-python.sh"
}

install_minimal_docker_stack() {
  run_in_target "
    set -euo pipefail

    source ${HELPER_SCRIPTS}/install.sh
    REPO_URL=\"https://download.docker.com/linux/ubuntu\"
    GPG_KEY=\"/usr/share/keyrings/docker.gpg\"
    REPO_PATH=\"/etc/apt/sources.list.d/docker.list\"
    os_codename=\$(lsb_release -cs)

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o \"\$GPG_KEY\"
    echo \"deb [arch=amd64 signed-by=\$GPG_KEY] \$REPO_URL \${os_codename} stable\" > \"\$REPO_PATH\"
    apt-get update

    components=\$(get_toolset_value '.docker.components[] .package')
    for package in \$components; do
      version=\$(get_toolset_value \".docker.components[] | select(.package == \\\"\$package\\\") | .version\")
      if [[ \$version == \"latest\" ]]; then
        apt-get install -y --no-install-recommends \"\$package\"
        continue
      fi

      version_string=\$(apt-cache madison \"\$package\" | awk '{ print \$3 }' | grep \"\$version\" | grep \"\$os_codename\" | head -1)
      apt-get install -y --no-install-recommends \"\${package}=\${version_string}\"
    done

    plugins=\$(get_toolset_value '.docker.plugins[] .plugin')
    for plugin in \$plugins; do
      version=\$(get_toolset_value \".docker.plugins[] | select(.plugin == \\\"\$plugin\\\") | .version\")
      filter=\$(get_toolset_value \".docker.plugins[] | select(.plugin == \\\"\$plugin\\\") | .asset\")
      url=\$(resolve_github_release_asset_url \"docker/\$plugin\" \"endswith(\\\"\$filter\\\")\" \"\$version\")
      binary_path=\$(download_with_retry \"\$url\" \"/tmp/docker-\$plugin\")
      mkdir -p /usr/libexec/docker/cli-plugins
      install \"\$binary_path\" \"/usr/libexec/docker/cli-plugins/docker-\$plugin\"
    done

    if getent group docker >/dev/null 2>&1; then
      gid=\$(cut -d ':' -f 3 /etc/group | grep '^1..$' | sort -n | tail -n 1 | awk '{ print \$1+1 }')
      groupmod -g \"\$gid\" docker
    fi

    cat > /etc/tmpfiles.d/docker.conf <<'EOF'
L /run/docker.sock - - - - root docker 0770
EOF

    systemd-tmpfiles --create /etc/tmpfiles.d/docker.conf || true
    systemctl is-enabled --quiet docker.socket || systemctl enable docker.socket || true
    systemctl disable containerd.service docker.service || true

    upx_url=\$(resolve_github_release_asset_url \"upx/upx\" \"endswith(\\\"amd64_linux.tar.xz\\\")\" \"latest\")
    upx_archive=\$(download_with_retry \"\$upx_url\" \"/tmp/upx.tar.xz\")
    python3 - <<'PY'
import tarfile

with tarfile.open('/tmp/upx.tar.xz', 'r:xz') as archive:
    member = next(item for item in archive.getmembers() if item.name.endswith('/upx'))
    member.name = 'upx'
    archive.extract(member, '/tmp')
PY
    install -m 0755 /tmp/upx /usr/local/bin/upx

    for binary in \
      /usr/libexec/docker/cli-plugins/docker-buildx \
      /usr/bin/dockerd \
      /usr/libexec/docker/cli-plugins/docker-compose \
      /usr/bin/containerd \
      /usr/bin/docker \
      /usr/bin/ctr; do
      before=\$(stat -c %s \"\$binary\")
      backup=\"\${binary}.orig\"
      cp -p \"\$binary\" \"\$backup\"
      if /usr/local/bin/upx --best --lzma \"\$binary\" && /usr/local/bin/upx -t \"\$binary\"; then
        after=\$(stat -c %s \"\$binary\")
        echo \"UPX compressed \$binary: \$before -> \$after bytes\"
        rm -f \"\$backup\"
      else
        mv -f \"\$backup\" \"\$binary\"
        echo \"UPX skipped \$binary after compression/test failure\"
      fi
    done

    rm -f /usr/local/bin/upx /tmp/upx /tmp/upx.tar.xz

    rm -f \"\$GPG_KEY\" \"\$REPO_PATH\"
  "
}

run_full_tooling_suite() {
  ensure_netcat_alias
  local scripts=(
    install-apt-common.sh
    install-azcopy.sh
    install-azure-cli.sh
    install-bicep.sh
    install-apache.sh
    install-aws-tools.sh
    install-clang.sh
    install-cmake.sh
    install-container-tools.sh
    install-dotnetcore-sdk.sh
    install-gcc-compilers.sh
    install-gfortran.sh
    install-git.sh
    install-git-lfs.sh
    install-github-cli.sh
    install-google-chrome.sh
    install-java-tools.sh
    install-kubernetes-tools.sh
    install-miniconda.sh
    install-nodejs.sh
    install-oras-cli.sh
    install-php.sh
    install-ruby.sh
    install-rust.sh
    install-selenium.sh
    configure-dpkg.sh
    install-yq.sh
    install-pypy.sh
    install-python.sh
    install-zstd.sh
  )
  local script_name

  for script_name in "${scripts[@]}"; do
    run_installer_script "$script_name"
  done

  # The stock database installers validate live local services, which does not
  # work reliably inside the surrogate chroot. Install the same package set but
  # skip the socket-based tests in this experimental full-installer mode.
  run_in_target "
    set -euo pipefail
    MYSQL_ROOT_PASSWORD=root
    echo \"mysql-server mysql-server/root_password password \$MYSQL_ROOT_PASSWORD\" | debconf-set-selections
    echo \"mysql-server mysql-server/root_password_again password \$MYSQL_ROOT_PASSWORD\" | debconf-set-selections
    export ACCEPT_EULA=Y
    apt-get install mysql-client
    apt-get install mysql-server
    apt-get install libmysqlclient-dev
    systemctl is-active --quiet mysql.service && systemctl stop mysql.service || true
    systemctl disable mysql.service || true
  "

  run_in_target "
    set -euo pipefail
    source ${HELPER_SCRIPTS}/install.sh
    REPO_URL=\"https://apt.postgresql.org/pub/repos/apt/\"
    wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /usr/share/keyrings/postgresql.gpg
    echo \"deb [signed-by=/usr/share/keyrings/postgresql.gpg] \$REPO_URL \$(lsb_release -cs)-pgdg main\" > /etc/apt/sources.list.d/pgdg.list
    toolset_version=\$(get_toolset_value '.postgresql.version')
    apt update
    apt-get install postgresql-\$toolset_version
    apt-get install libpq-dev
    systemctl is-active --quiet postgresql.service && systemctl stop postgresql.service || true
    systemctl disable postgresql.service || true
    rm /etc/apt/sources.list.d/pgdg.list
    rm /usr/share/keyrings/postgresql.gpg
    echo \"postgresql \$REPO_URL\" >> ${HELPER_SCRIPTS}/apt-sources.txt
  "
}

target_disk="$(find_target_disk)"
if [[ -z "${target_disk}" ]]; then
  echo "Failed to detect non-root target disk for the surrogate image." >&2
  lsblk >&2
  exit 1
fi

target_partition="$(partition_path "${target_disk}")"
if [[ ! -b "${target_partition}" ]]; then
  # Fallback to first discovered partition on the target disk
  target_partition="$(lsblk -nro NAME,TYPE "${target_disk}" | awk '$2=="part"{print "/dev/"$1; exit}')"
fi

if [[ -z "${target_partition}" || ! -b "${target_partition}" ]]; then
  echo "Failed to find partition on target disk ${target_disk}" >&2
  lsblk "${target_disk}" >&2
  exit 1
fi

run_logged "preparing mountpoint ${TARGET_ROOT_MOUNT}" \
  mkdir -p "${TARGET_ROOT_MOUNT}"

TARGET_UBUNTU_MIRROR="$(resolve_target_ubuntu_mirror)"

run_logged "mounting target partition ${target_partition}" \
  mount -o discard "${target_partition}" "${TARGET_ROOT_MOUNT}"

run_logged "preparing chroot mounts on ${TARGET_ROOT_MOUNT}" \
  mkdir -p \
    "${TARGET_ROOT_MOUNT}/dev" \
    "${TARGET_ROOT_MOUNT}/dev/pts" \
    "${TARGET_ROOT_MOUNT}/proc" \
    "${TARGET_ROOT_MOUNT}/sys" \
    "${TARGET_ROOT_MOUNT}/run"

run_logged "binding chroot pseudo filesystems" \
  bash -c "mount --bind /dev \"${TARGET_ROOT_MOUNT}/dev\" && \
    mount --bind /dev/pts \"${TARGET_ROOT_MOUNT}/dev/pts\" && \
    mount -t proc proc \"${TARGET_ROOT_MOUNT}/proc\" && \
    mount -t sysfs sysfs \"${TARGET_ROOT_MOUNT}/sys\" && \
    mount --bind /run \"${TARGET_ROOT_MOUNT}/run\" && \
    cp /etc/resolv.conf \"${TARGET_ROOT_MOUNT}/etc/resolv.conf\""

run_logged "copying installer helpers/assets into target image" \
  cp -a "${IMAGE_FOLDER}" "${TARGET_ROOT_MOUNT}/"

run_logged "patching configure-dpkg.sh to use the us-east-1 Ubuntu mirror" \
  bash -lc 'script_path="'"${TARGET_ROOT_MOUNT}${INSTALLER_SCRIPT_FOLDER}"'/configure-dpkg.sh"; \
    if [[ -f "${script_path}" ]]; then \
      sed -i "s|archive.ubuntu.com|us-east-1.ec2.archive.ubuntu.com|g" "${script_path}"; \
    fi'

run_logged "installing packages needed by installer scripts" \
  chroot "${TARGET_ROOT_MOUNT}" /usr/bin/env \
    DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
    apt-get update

run_logged "installing prerequisites for installer helpers" \
  chroot "${TARGET_ROOT_MOUNT}" /usr/bin/env \
    DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
    apt-get install -y --no-install-recommends \
    lsb-release \
    sudo \
    man-db \
    wget \
    jq \
    curl \
    gpg

run_logged "seeding minimal compatibility files" \
  chroot "${TARGET_ROOT_MOUNT}" /usr/bin/env \
    DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
    bash -lc 'mkdir -p /etc/default && touch /etc/default/motd-news'

run_logged "ensuring ubuntu.sources is the canonical Ubuntu apt source definition" \
  chroot "${TARGET_ROOT_MOUNT}" /usr/bin/env \
    TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR}" \
    TARGET_UBUNTU_SECURITY_MIRROR="${TARGET_UBUNTU_SECURITY_MIRROR}" \
    DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
    bash -lc 'mkdir -p /etc/apt/sources.list.d /etc/cloud/templates; \
      if [ ! -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: ${TARGET_UBUNTU_MIRROR}
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${TARGET_UBUNTU_SECURITY_MIRROR}
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
      fi; \
      rm -f /etc/apt/sources.list /etc/cloud/templates/sources.list.ubuntu.tmpl'

if [[ -f /etc/waagent.conf ]]; then
  run_logged "copying waagent config into target image" \
    cp /etc/waagent.conf "${TARGET_ROOT_MOUNT}/etc/waagent.conf"
fi

run_logged "ensuring runner compatibility user exists in target image"
ensure_runner_user

run_logged "running install configuration scripts in chroot image"

run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/configure-image-data.sh"
run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/configure-environment.sh"
ensure_noninteractive_environment
run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/configure-apt-mock.sh"
run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/install-ms-repos.sh"
run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/configure-apt-sources.sh"
run_logged "preferring AWS-local Ubuntu mirrors inside target image" \
  chroot "${TARGET_ROOT_MOUNT}" /usr/bin/env \
    TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR}" \
    TARGET_UBUNTU_SECURITY_MIRROR="${TARGET_UBUNTU_SECURITY_MIRROR}" \
    DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
    bash -lc 'cat > /etc/apt/apt-mirrors.txt <<EOF
${TARGET_UBUNTU_MIRROR}	priority:1
http://archive.ubuntu.com/ubuntu/	priority:2
${TARGET_UBUNTU_SECURITY_MIRROR}	priority:3
EOF'
run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/configure-apt.sh"
run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/configure-limits.sh"
run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/install-runner-package.sh"

if [[ "${MINIMAL_INCLUDE_FULL_INSTALLERS}" == "true" ]]; then
  run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/install-powershell.sh"
  run_in_target "pwsh -f ${INSTALLER_SCRIPT_FOLDER}/Install-PowerShellModules.ps1"
  run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/install-actions-cache.sh"
  run_logged "running full installer suite"
  run_full_tooling_suite
else
  run_logged "running minimal tooling suite"
  run_minimal_tooling_suite
fi

install_minimal_docker_stack

if [[ "${MINIMAL_INCLUDE_FULL_INSTALLERS}" == "true" ]]; then
  run_logged "installing full toolset metadata"
  run_installer_script "Install-Toolset.ps1"
  run_installer_script "Configure-Toolset.ps1"

  run_logged "seeding needrestart config for configure-system"
  run_in_target "if [ ! -f /etc/needrestart/needrestart.conf ]; then mkdir -p /etc/needrestart; printf '%s\n' '\$nrconf{override_rc} = {' '};' > /etc/needrestart/needrestart.conf; fi"

  run_logged "configuring final system layout for bootfast image"
  run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/configure-system.sh"

  if [[ -f "${TARGET_ROOT_MOUNT}${IMAGE_FOLDER}/bootfast-runner-user.sh" ]]; then
    run_logged "running bootfast-specific runner finalization"
    TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT}" \
      IMAGE_FOLDER="${IMAGE_FOLDER}" \
      DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
      bash "${TARGET_ROOT_MOUNT}${IMAGE_FOLDER}/bootfast-runner-user.sh"
  fi
else
  if [[ -f "${TARGET_ROOT_MOUNT}${IMAGE_FOLDER}/minimal-runner-user.sh" ]]; then
    run_logged "running minimal runner finalization"
    TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT}" \
      IMAGE_FOLDER="${IMAGE_FOLDER}" \
      DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
      bash "${TARGET_ROOT_MOUNT}${IMAGE_FOLDER}/minimal-runner-user.sh"
  fi
fi

run_in_target "bash ${INSTALLER_SCRIPT_FOLDER}/cleanup.sh"

run_logged "trimming target root filesystem before unmount"
trim_rootfs_mount "${TARGET_ROOT_MOUNT}"

run_logged "completed minimal image installer stage"
