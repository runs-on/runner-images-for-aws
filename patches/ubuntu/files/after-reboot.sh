 #!/bin/bash 
set -ex

# Check FS on next boot for the / mount
tune2fs -c 0 $(cat /proc/self/mounts | grep " / " | cut -f 1 -d " ")

rm -rf /var/lib/apt/lists

cloud-init clean --logs
rm -rf /var/lib/cloud/*

# ensure no ssh keys are present
rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys

# Remove SSH host key pairs - https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/building-shared-amis.html#remove-ssh-host-key-pairs
shred -u /etc/ssh/*_key /etc/ssh/*_key.pub

# disable ssh daemon by default, do this after VM has rebooted
systemctl disable ssh.service
