 #!/bin/bash 
set -ex

# Check FS on next boot for the / mount
tune2fs -c 0 $(cat /proc/self/mounts | grep " / " | cut -f 1 -d " ")

rm -rf /var/lib/apt/lists
rm -rf /var/lib/cloud/instances/*

# disable ssh daemon by default, do this after VM has rebooted
systemctl disable ssh.service
