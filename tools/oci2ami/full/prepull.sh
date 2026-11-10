#!/bin/bash
# prepull.sh IMAGE PULLS ROOT: pulls into ROOT (the image's exported root) the
# Docker images that install-docker.sh pulls in a packer build, with the
# image's own containerd and dockerd, since no daemon runs in a docker build.
# PULLS holds install-docker.sh's `docker pull` lines.
set -euo pipefail
image=$1 pulls=$(cd "$(dirname "$2")" && pwd)/$(basename "$2") root=$3
[ -s "$pulls" ] || exit 0
mkdir -p "$root/var/lib/containerd" "$root/var/lib/docker"
docker run --rm --privileged --network host \
  -v "$root/var/lib/containerd:/var/lib/containerd" \
  -v "$root/var/lib/docker:/var/lib/docker" \
  -v "$pulls:/oci-pulls:ro" \
  --entrypoint /bin/bash "$image" -euc '
    containerd >/tmp/containerd.log 2>&1 & c=$!
    dockerd --containerd=/run/containerd/containerd.sock --iptables=false --ip6tables=false --bridge=none >/tmp/dockerd.log 2>&1 & d=$!
    for i in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
    docker info >/dev/null || { tail -20 /tmp/dockerd.log; exit 1; }
    while read -r line; do [ -z "$line" ] || eval "$line"; done < /oci-pulls
    docker images --format "{{.Repository}}:{{.Tag}} {{.Size}}"
    kill $d; wait $d || true
    kill $c; wait $c || true'
