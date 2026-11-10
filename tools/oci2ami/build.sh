#!/bin/bash
# build.sh DEVICE: builds the job image and its EC2 layer, then writes the
# AMI disk to DEVICE (an empty EBS volume attached to this builder). Run on an
# Ubuntu 26.04 builder of the target architecture (x64 only so far) with
# docker.io, systemd-ukify, systemd-boot-efi, gdisk, dosfstools and Go.
# Then: aws ec2 create-snapshot on the volume, and
#   aws ec2 register-image --boot-mode uefi --ena-support --architecture x86_64 \
#     --root-device-name /dev/xvda --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-..."}}]'
set -euo pipefail
cd "$(dirname "$0")"
DEV=$1
(cd ../rolaunch && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o ../oci2ami/rolaunch .)
cp ../../patches/ubuntu/files/install-runs-on-bootstrap.sh .
trap 'rm -f rolaunch install-runs-on-bootstrap.sh' EXIT
docker build -t runs-on-job -f job.Dockerfile .
docker build -t runs-on-job-ec2 -f ec2.Dockerfile .
./oci2ami.sh runs-on-job-ec2 "$DEV"
