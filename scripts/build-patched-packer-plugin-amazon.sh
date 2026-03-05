#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Upstream has no published v1.8.1 tag; pin to a specific commit from that line.
PLUGIN_REF="${PACKER_AMAZON_PLUGIN_REF:-49961bec5134e26ccf769adb7273cd6c33fdc592}"
PATCH_FILE="${PACKER_AMAZON_PATCH_FILE:-$ROOT_DIR/patches/packer-plugin-amazon/enable-nested-virtualization.patch}"
WORKSPACE_DIR="${PACKER_AMAZON_WORKSPACE_DIR:-${RUNNER_TEMP:-/tmp}/runs-on-packer-plugin-amazon}"
SRC_DIR="$WORKSPACE_DIR/src"
OUT_DIR="${PACKER_AMAZON_OUTPUT_DIR:-$WORKSPACE_DIR/bin}"
OUT_BIN="${PACKER_AMAZON_OUTPUT_BINARY:-$OUT_DIR/packer-plugin-amazon}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_cmd git
require_cmd go

[ -f "$PATCH_FILE" ] || fail "Patch file not found: $PATCH_FILE"

# Some environments export GOROOT with a stale path; clear it so `go env` resolves correctly.
if [ -n "${GOROOT:-}" ] && [ ! -f "${GOROOT}/src/fmt/print.go" ]; then
  unset GOROOT
fi

GO_VERSION_RAW="$(go env GOVERSION 2>/dev/null || true)"
[ -n "$GO_VERSION_RAW" ] || fail "Unable to resolve Go version via 'go env GOVERSION'"
if [[ ! "$GO_VERSION_RAW" =~ ^go([0-9]+)\.([0-9]+) ]]; then
  fail "Unable to parse Go version: $GO_VERSION_RAW"
fi

GO_MAJOR="${BASH_REMATCH[1]}"
GO_MINOR="${BASH_REMATCH[2]}"
if [ "$GO_MAJOR" -lt 1 ] || { [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 24 ]; }; then
  fail "Go 1.24+ is required to build packer-plugin-amazon (found $GO_VERSION_RAW)"
fi

GO_ROOT="$(go env GOROOT 2>/dev/null || true)"
[ -n "$GO_ROOT" ] || fail "Unable to resolve GOROOT"
[ -f "$GO_ROOT/src/fmt/print.go" ] || fail "Go toolchain appears incomplete; missing stdlib at $GO_ROOT/src/fmt/print.go"

rm -rf "$SRC_DIR"
mkdir -p "$OUT_DIR" "$SRC_DIR"

git -C "$SRC_DIR" init -q
git -C "$SRC_DIR" remote add origin https://github.com/hashicorp/packer-plugin-amazon.git
git -C "$SRC_DIR" fetch --depth 1 origin "$PLUGIN_REF"
git -C "$SRC_DIR" checkout -q FETCH_HEAD
git -C "$SRC_DIR" apply "$PATCH_FILE"

pushd "$SRC_DIR" >/dev/null
go mod edit -require=github.com/aws/aws-sdk-go-v2/service/ec2@v1.289.1
go mod tidy
go test ./common -run 'TestRunConfigPrepare_EnableNestedVirtualizationGood|TestCreateTemplateData_EnableNestedVirtualization' -count=1 1>&2
go build -ldflags="-X 'github.com/hashicorp/packer-plugin-amazon/version.VersionPrerelease=' -X 'github.com/hashicorp/packer-plugin-amazon/version.VersionMetadata='" -o "$OUT_BIN" .
popd >/dev/null

chmod +x "$OUT_BIN"
echo "$OUT_BIN"
