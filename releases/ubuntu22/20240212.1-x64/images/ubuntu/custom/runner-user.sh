#!/bin/bash
set -e

echo "Setting up runner user..."
adduser --shell /bin/bash --disabled-password --gecos "" --uid 1001 runner
usermod -aG sudo runner
echo "%sudo   ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers
echo "Defaults env_keep += \"DEBIAN_FRONTEND\"" >> /etc/sudoers

# install archive from cache
archive_name=$(ls /opt/runner-cache)
archive_path="/opt/runner-cache/$archive_name"
echo "Installing runner from $archive_path"
tar xzf "$archive_path" -C /home/runner
chown -R runner:runner /home/runner
rm -rf /opt/runner-cache

# test presence of run.sh
test -s /home/runner/run.sh