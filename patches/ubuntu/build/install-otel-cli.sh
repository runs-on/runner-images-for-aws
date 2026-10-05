#!/bin/bash -e
################################################################################
##  File:  install-otel-cli.sh
##  Desc:  Install otel-cli, to wrap workflow commands in spans for the
##         runner's local OpenTelemetry collector
##  Supply chain security: otel-cli - pinned version and SHA-256
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/install.sh
source $HELPER_SCRIPTS/os.sh

# SHA-256 of each pinned release asset, from the release's checksums.txt.
OTEL_CLI_VERSION="0.4.5"
if is_arm64; then
    arch="arm64"
    sha256="f8f27f1289850983f86beaf62968ab65e3491207291d0cdb68247826cc21e695"
else
    arch="amd64"
    sha256="2f192fadfb2107a92ae617ca93fd7c0b532fa618a5ebc3917e641c6a9fbaeb45"
fi

archive_path=$(download_with_retry "https://github.com/equinix-labs/otel-cli/releases/download/v${OTEL_CLI_VERSION}/otel-cli_${OTEL_CLI_VERSION}_linux_${arch}.tar.gz")
use_checksum_comparison "$archive_path" "$sha256"
tar -xzf "$archive_path" -C /usr/local/bin otel-cli
chmod 755 /usr/local/bin/otel-cli

invoke_tests "OtelCli"
