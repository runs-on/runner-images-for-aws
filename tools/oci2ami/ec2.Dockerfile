# The EC2 boot layer: a kernel, systemd as init, DHCP and rolaunch, which runs
# the stack's user data. oci2ami.sh turns the result into an AMI.
ARG BASE=runs-on-job
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      linux-image-aws systemd-sysv udev kmod dbus openssh-client fdisk e2fsprogs cloud-guest-utils >/dev/null \
 && rm -rf /var/lib/apt/lists/* /boot/initrd.img* \
 && rm -f /etc/machine-id && : > /etc/machine-id
COPY rolaunch /usr/bin/rolaunch
COPY rootfs/ /
COPY install-runs-on-bootstrap.sh /tmp/
# The unit set of runner-images-for-aws's minimal variant (runner-finalize-units.sh):
# Docker starts on its socket, nothing waits for ldconfig or getty.
RUN systemctl enable systemd-networkd.service rolaunch.service docker.socket \
 && systemctl disable docker.service containerd.service \
 && systemctl mask systemd-networkd-wait-online.service ldconfig.service systemd-journal-flush.service e2scrub_reap.service e2scrub_all.timer \
      apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer dpkg-db-backup.timer fstrim.timer \
      systemd-tmpfiles-clean.timer motd-news.timer man-db.timer systemd-binfmt.service proc-sys-fs-binfmt_misc.automount \
      getty@tty1.service getty-static.service modprobe@drm.service systemd-initctl.socket \
 && systemctl set-default multi-user.target \
 && bash /tmp/install-runs-on-bootstrap.sh && rm /tmp/install-runs-on-bootstrap.sh
