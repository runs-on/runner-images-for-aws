#!/bin/bash -e
################################################################################
##  File:  configure-dpkg-eatmydata.sh
##  Desc:  Run dpkg under eatmydata when apt installs packages
################################################################################

# Minimal images run this through `bash <script>`, which ignores the shebang's -e.
set -e

# Runner VMs are ephemeral, so package installs do not need to survive a crash.
# --force-unsafe-io only skips the fsync of unpacked files: dpkg still syncs its
# database, and maintainer scripts sync their own files. On EBS those syncs take
# most of an install's time. eatmydata turns them into no-ops for dpkg and
# everything it runs, and a clean shutdown or reboot still writes the data out.
apt-get install -y --no-install-recommends eatmydata

cat > /usr/local/sbin/dpkg-eatmydata <<'EOF'
#!/bin/sh
exec /usr/bin/eatmydata /usr/bin/dpkg "$@"
EOF
chmod 0755 /usr/local/sbin/dpkg-eatmydata

echo 'Dir::Bin::dpkg "/usr/local/sbin/dpkg-eatmydata";' > /etc/apt/apt.conf.d/10dpkg-eatmydata
