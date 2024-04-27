 #!/bin/bash 
set -ex

tune2fs -c 0 /dev/nvme0n1p1

rm -rf /var/lib/apt/lists
rm -rf /var/lib/cloud/instances/*

# disable ssh daemon by default, do this after VM has rebooted
systemctl disable ssh.service
