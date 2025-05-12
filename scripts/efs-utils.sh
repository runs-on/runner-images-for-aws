#!/bin/bash

set -euxo pipefail

IMAGE=$1
ARCH=$2

docker run -v $PWD/scripts:/scripts -v $PWD/dist/efs-utils:/dist --platform "linux/$ARCH" --rm -it "$IMAGE" bash -c "
apt-get update -qq
apt-get -y install git binutils rustc cargo pkg-config libssl-dev gettext
git clone https://github.com/aws/efs-utils
cd efs-utils
./build-deb.sh
mv ./build/amazon-efs-utils*deb /dist/
"