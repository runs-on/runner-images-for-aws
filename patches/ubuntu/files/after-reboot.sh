 #!/bin/bash 
set -ex

tune2fs -c 0 /dev/nvme0n1p1

rm -rf /var/lib/apt/lists
rm -rf /var/lib/cloud/instances/*

# ensure no ssh keys are present
rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys

# Remove SSH host key pairs - https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/building-shared-amis.html#remove-ssh-host-key-pairs
shred -u /etc/ssh/*_key /etc/ssh/*_key.pub

# disable ssh daemon by default, do this after VM has rebooted
systemctl disable ssh.service
