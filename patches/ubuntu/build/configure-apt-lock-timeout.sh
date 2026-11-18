#!/bin/bash -e
################################################################################
##  File:  configure-apt-lock-timeout.sh
##  Desc:  Make apt-get wait for the dpkg lock instead of failing at once
################################################################################

# Minimal images run this through `bash <script>`, which ignores the shebang's -e.
set -e

# An AWS account can install packages on every new instance through Systems
# Manager, a few seconds after its agent registers: Amazon Inspector does
# (`dpkg -i`, `apt install`), and so can Patch Manager or a Distributor
# association. A job that runs apt-get install in those seconds fails with
# "Could not get lock /var/lib/dpkg/lock-frontend", because apt-get does not
# wait for the lock by default. The apt command already waits 120 seconds.
echo 'DPkg::Lock::Timeout "120";' > /etc/apt/apt.conf.d/10dpkg-lock-timeout
