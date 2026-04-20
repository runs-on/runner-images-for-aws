#!/usr/bin/env bash

set -euo pipefail

TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-}"
variant="${RUNNER_FINALIZE_VARIANT:-${1:-full}}"

log() {
  echo "[runner-finalize-units] $*"
}

target_systemctl() {
  if [[ -n "${TARGET_ROOT_MOUNT}" ]]; then
    systemctl --root="${TARGET_ROOT_MOUNT}" "$@" || true
  else
    systemctl "$@" || true
  fi
}

disable_target_units() {
  target_systemctl disable "$@"
}

mask_target_units() {
  target_systemctl mask "$@"
}

enable_target_units() {
  target_systemctl enable "$@"
}

set_default_target_unit() {
  local target_unit="$1"
  local base_dir="${TARGET_ROOT_MOUNT:-}"

  install -d "${base_dir}/etc/systemd/system"
  ln -sfn "/lib/systemd/system/${target_unit}" "${base_dir}/etc/systemd/system/default.target"
}

disable_matching_units() {
  local pattern="$1"
  local base_dir="${TARGET_ROOT_MOUNT:-}"
  local dir
  local unit_path

  for dir in "${base_dir}/lib/systemd/system" "${base_dir}/usr/lib/systemd/system"; do
    [[ -d "${dir}" ]] || continue
    while IFS= read -r unit_path; do
      target_systemctl disable "$(basename "${unit_path}")"
    done < <(find "${dir}" -maxdepth 1 -name "${pattern}" -type f | sort -u)
  done
}

variant_allowlist_units() {
  case "${variant}" in
    bootfast)
      printf '%s\n' \
        docker.socket \
        getty@.service \
        remote-fs.target \
        rolaunch.service
      ;;
    minimal)
      printf '%s\n' \
        docker.socket \
        remote-fs.target \
        rolaunch.service \
        serial-getty@ttyS0.service
      ;;
  esac
}

enforce_allowlist() {
  local allowed_units=("$@")
  local enabled_units=()
  local unit
  local allowed

  if [[ "${#allowed_units[@]}" -eq 0 ]]; then
    return 0
  fi

  mapfile -t enabled_units < <(
    if [[ -n "${TARGET_ROOT_MOUNT}" ]]; then
      systemctl --root="${TARGET_ROOT_MOUNT}" list-unit-files \
        --state=enabled,enabled-runtime \
        --no-legend \
        --no-pager \
        | awk '{ print $1 }'
    else
      systemctl list-unit-files \
        --state=enabled,enabled-runtime \
        --no-legend \
        --no-pager \
        | awk '{ print $1 }'
    fi
  )

  for unit in "${enabled_units[@]}"; do
    allowed=false
    for candidate in "${allowed_units[@]}"; do
      if [[ "${unit}" == "${candidate}" ]]; then
        allowed=true
        break
      fi
    done

    if [[ "${allowed}" == "false" ]]; then
      target_systemctl disable "${unit}"
    fi
  done

  enable_target_units "${allowed_units[@]}"
}

remove_ldconfig_symlinks() {
  local base_dir="${TARGET_ROOT_MOUNT:-}"

  rm -f \
    "${base_dir}/etc/systemd/system/ldconfig-after-rolaunch.service" \
    "${base_dir}/etc/systemd/system/sysinit.target.wants/ldconfig.service" \
    "${base_dir}/lib/systemd/system/sysinit.target.wants/ldconfig.service" \
    "${base_dir}/usr/lib/systemd/system/sysinit.target.wants/ldconfig.service"
}

log "disabling runner image units for variant ${variant}"

disable_target_units timers.target
disable_target_units \
  console-setup.service \
  hibinit-agent.service \
  grub-initrd-fallback.service \
  lvm2-monitor.service \
  rsyslog.service \
  ubuntu-advantage.service \
  vgauth.service \
  setvtrgb.service \
  systemd-journal-flush.service
disable_target_units \
  snapd.seeded.service \
  snapd.autoimport.service \
  snapd.core-fixup.service \
  snapd.recovery-chooser-trigger.service \
  snapd.system-shutdown.service \
  snapd.apparmor.service
disable_target_units \
  update-notifier-download.service \
  plymouth-quit.service \
  plymouth-quit-wait.service
disable_target_units \
  containerd.service \
  docker.service \
  apport.service \
  logrotate.service \
  grub-common.service \
  keyboard-setup.service \
  systemd-update-utmp.service \
  systemd-fsck-root.service \
  systemd-tmpfiles-setup.service \
  apparmor.service \
  e2scrub_reap.service
disable_target_units \
  ufw.service \
  snapd.service \
  snap.lxd.activate.service \
  ec2-instance-connect.service \
  snap.amazon-ssm-agent.amazon-ssm-agent.service \
  cron.service
disable_target_units \
  fwupd.service \
  fwupd-refresh.service \
  dpkg-db-backup.service \
  dpkg-db-backup.timer \
  apt-news.service \
  esm-cache.service \
  ec2-instance-connect-harvest-hostkeys.service \
  ModemManager.service
disable_target_units \
  qemu-kvm.service \
  libvirt-guests.service \
  libvirtd.service \
  systemd-machined.service
disable_target_units mono-xsp4.service

if [[ "${variant}" == "bootfast" ]]; then
  disable_target_units ssh.service
fi

if [[ "${variant}" == "minimal" ]]; then
  disable_target_units ssh.service ssh.socket ldconfig.service
  mask_target_units \
    ssh.socket \
    systemd-initctl.socket \
    modprobe@drm.service \
    getty-static.service \
    getty@tty1.service \
    getty@tty2.service \
    getty@tty3.service \
    getty@tty4.service \
    getty@tty5.service \
    getty@tty6.service \
    systemd-binfmt.service \
    proc-sys-fs-binfmt_misc.automount \
    apt-daily.service \
    apt-daily.timer \
    apt-daily-upgrade.service \
    apt-daily-upgrade.timer \
    dpkg-db-backup.timer \
    e2scrub_all.timer \
    fstrim.timer \
    man-db.timer \
    motd-news.timer \
    systemd-tmpfiles-clean.timer
  remove_ldconfig_symlinks
  set_default_target_unit multi-user.target
fi

disable_matching_units 'podman*'
disable_matching_units 'php*'

if [[ "${variant}" == "bootfast" || "${variant}" == "minimal" ]]; then
  mapfile -t allowed_units < <(variant_allowlist_units)
  enforce_allowlist "${allowed_units[@]}"
fi
