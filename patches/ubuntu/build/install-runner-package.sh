#!/bin/bash -e
################################################################################
##  File:  install-runner-package.sh
##  Desc:  Download and Install runner package
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/install.sh

# github.com/runs-on/runner publishes RunsOn's build of each actions/runner
# release as v<version>-runs-on.<revision>, with upstream's file names. Take
# the newest revision for upstream's latest version, and fail the build until
# the fork publishes that version. Upstream's release helpers skip tags with a
# suffix like this, so resolve the tag here.
version=$(get_github_api_json "repos/actions/runner/releases/latest" | jq -r '.tag_name | ltrimstr("v")')
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Unexpected actions/runner version: ${version}" >&2
    exit 1
fi

prefix="v${version}-runs-on."
tag=$(get_github_api_json "repos/runs-on/runner/releases?per_page=100" |
    jq -r --arg prefix "$prefix" '[.[].tag_name | select(startswith($prefix))] | sort_by(ltrimstr($prefix) | tonumber) | last // empty')
if [[ -z "$tag" ]]; then
    echo "runs-on/runner has not published actions/runner v${version} yet" >&2
    exit 1
fi

# bin/patch/lib.sh rewrites linux-x64 to linux-arm64 for arm64 images.
archive_name="actions-runner-linux-x64-${version}.tar.gz"
release_url="https://github.com/runs-on/runner/releases/download/${tag}"
echo "Installing ${archive_name} from runs-on/runner ${tag}"
archive_path=$(download_with_retry "${release_url}/${archive_name}")
checksum=$(get_checksum_from_url "${release_url}/SHA256SUMS" "$archive_name" "SHA256")
# Upstream's use_checksum_comparison needs shasum, which comes with perl and
# is missing from minimal images; sha256sum is part of coreutils.
echo "${checksum}  ${archive_path}" | sha256sum --check --strict

mkdir -p /opt/runner-cache
mv "$archive_path" "/opt/runner-cache/$archive_name"
