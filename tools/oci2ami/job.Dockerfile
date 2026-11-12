# The job image: what a job sees, whatever runs it (Lambda MicroVM, a host's
# Firecracker or Nitro sandbox, an EC2 instance). Nothing here knows how it boots.
FROM ubuntu:26.04
ARG RUNNER_URL=https://github.com/runs-on/runner/releases/download/v2.338.2-runs-on.2/actions-runner-linux-x64-2.338.2.tar.gz
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends bash git tar gzip unzip zip jq curl \
      ca-certificates openssl xz-utils bzip2 procps iproute2 findutils hostname util-linux diffutils passwd libicu-dev sudo \
      docker.io iptables >/dev/null \
 && rm -rf /var/lib/apt/lists/* \
 && (id runner >/dev/null 2>&1 || { if getent passwd 1001 >/dev/null; then userdel -r ubuntu; fi; useradd -m -u 1001 -s /bin/bash runner; }) \
 && usermod -aG docker runner \
 && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
 && mkdir -p /home/runner /opt/hostedtoolcache \
 && curl -fsSL "$RUNNER_URL" | tar xz -C /home/runner \
 && chown -R runner:runner /home/runner /opt/hostedtoolcache
