#!/bin/bash -e
################################################################################
##  File:  configure-apt-gzip-indexes.sh
##  Desc:  Make apt download gzip package indexes instead of xz
################################################################################

# Minimal images run this through `bash <script>`, which ignores the shebang's -e.
set -e

# Images ship without package lists, so a job's first apt-get update downloads
# and decompresses every index. xz, apt's default, decompresses several times
# slower than gzip, and that dominates the update on a runner. The Ubuntu
# archive publishes gzip indexes too, about 30% larger. Docker's Ubuntu images
# make the same choice. apt still uses xz for indexes without a gzip variant.
echo 'Acquire::CompressionTypes::Order:: "gz";' > /etc/apt/apt.conf.d/10apt-gzip-indexes
