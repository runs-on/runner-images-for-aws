#!/usr/bin/env bash

set -euo pipefail

ROLAUNCH_SOURCE="${ROLAUNCH_SOURCE:-}"

log() {
  echo "[restore-minimal-boot-contract] $*"
}

install_current_rolaunch() {
  if [[ -n "${ROLAUNCH_SOURCE}" && -f "${ROLAUNCH_SOURCE}" ]]; then
    install -D -m 0755 "${ROLAUNCH_SOURCE}" /usr/bin/rolaunch
    ln -sfn /usr/bin/rolaunch /usr/local/bin/rolaunch
    return
  fi

  if [[ -x /usr/local/bin/rolaunch ]]; then
    ln -sfn /usr/local/bin/rolaunch /usr/bin/rolaunch
    log "ROLAUNCH_SOURCE unavailable, using existing /usr/local/bin/rolaunch via /usr/bin/rolaunch"
    return
  fi

  if [[ -x /usr/bin/rolaunch ]]; then
    log "ROLAUNCH_SOURCE unavailable, reusing existing /usr/bin/rolaunch"
    return
  fi

  log "ROLAUNCH_SOURCE unavailable and no existing rolaunch binary found"
}

write_current_rolaunch_units() {
  cat > /etc/systemd/system/rolaunch.service <<'EOF'
[Unit]
Description=ROLaunch

[Service]
Type=oneshot
ExecStart=/usr/bin/rolaunch
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
}

set_default_target() {
  ln -sfn /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
}

reset_rolaunch_state() {
  install -d -m 0700 /var/lib/rolaunch
  rm -f \
    /var/lib/rolaunch/instance-identity.json \
    /var/lib/rolaunch/runs-on-user-data.done \
    /var/lib/rolaunch/user-data.sh
}

remove_ldconfig_symlinks() {
  rm -f \
    /etc/systemd/system/ldconfig-after-rolaunch.service \
    /etc/systemd/system/sysinit.target.wants/ldconfig.service \
    /lib/systemd/system/sysinit.target.wants/ldconfig.service \
    /usr/lib/systemd/system/sysinit.target.wants/ldconfig.service
}

log "restoring minimal boot contract unit state"

install_current_rolaunch
write_current_rolaunch_units
set_default_target
reset_rolaunch_state
remove_ldconfig_symlinks

systemctl daemon-reload || true
log "minimal unit allowlist is applied separately by runner-finalize-units.sh"
