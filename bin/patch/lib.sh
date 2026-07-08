# Shared implementation for the bin/patch/ubuntu* scripts.
#
# Callers must set DIST (e.g. ubuntu24), ARCH (x64|arm64) and TOOLSET_FILE
# (e.g. toolset-2404-arm64.json) before sourcing this file, then call
# `patch_ubuntu "$RELEASE_DIR"`. Windows patch scripts are standalone.
#
# yq note: "keep last version" edits on toolcache entries use the
# parenthesized-path form with a length guard. The older
# `eval(... | select(...) | ...)` form writes an EMPTY file when the select
# matches nothing (e.g. toolset-2604 ships empty Python/PyPy version arrays),
# silently destroying the toolset JSON.

gnu_sed() {
  $(which gsed || which sed) "$@"
}

patch_ubuntu() {
  local release_dir="$1"

  if [ -z "$release_dir" ]; then
    echo "Usage: $0 <RELEASE_DIR>"
    exit 1
  fi
  if [ -z "$DIST" ] || [ -z "$ARCH" ] || [ -z "$TOOLSET_FILE" ]; then
    echo "DIST, ARCH and TOOLSET_FILE must be set before calling patch_ubuntu" >&2
    exit 1
  fi

  local repo_root build_dir custom_dir toolsets_dir tests_dir
  local goarch dist_dir rolaunch_bin
  repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
  build_dir="$release_dir/images/ubuntu/scripts/build"
  custom_dir="$release_dir/images/ubuntu/custom"
  toolsets_dir="$release_dir/images/ubuntu/toolsets"
  tests_dir="$release_dir/images/ubuntu/scripts/tests"
  TOOLSET_PATH="$toolsets_dir/$TOOLSET_FILE"
  goarch=$([ "$ARCH" = "arm64" ] && echo arm64 || echo amd64)
  dist_dir="$repo_root/dist"
  rolaunch_bin="$dist_dir/rolaunch-linux-$goarch"

  ## Script overrides
  if [ "$ARCH" = "x64" ]; then
    # add gpu install script
    cp patches/ubuntu/build/install-gpu.sh "$build_dir/"
  fi
  # install apt common packages in one transaction to avoid repeated apt service checks
  cp patches/ubuntu/build/install-apt-common.sh "$build_dir/"
  # restore runner install script
  cp patches/ubuntu/build/install-runner-package.sh "$build_dir/"
  # add runs-on/action@v2 to action archive cache
  cp patches/ubuntu/build/install-actions-cache.sh "$build_dir/"

  ## Custom files
  mkdir -p $custom_dir
  cp -r patches/ubuntu/files $custom_dir/
  if [ "$ARCH" = "arm64" ]; then
    gnu_sed -i 's|amd64|arm64|g' $custom_dir/files/*.sh
  fi

  if [ "${IMAGE_ID:-}" = "${DIST}-minimal-${ARCH}" ]; then
    build_minimal_rolaunch
  fi

  ## arm64: rewrite arch references in upstream build scripts and toolsets
  if [ "$ARCH" = "arm64" ]; then
    gnu_sed -i 's|awscli-exe-linux-x86_64.zip|awscli-exe-linux-aarch64.zip|g' $build_dir/*.sh
    gnu_sed -i 's|aws-sam-cli-linux-x86_64.zip|aws-sam-cli-linux-arm64.zip|g' $build_dir/*.sh
    # typo on purpose, matches Linux and linux
    gnu_sed -i 's|inux-x86_64|inux-aarch64|g' $build_dir/*.sh $toolsets_dir/*.json
    gnu_sed -i 's|linux-amd64|linux-arm64|g' $build_dir/*.sh $toolsets_dir/*.json
    gnu_sed -i 's|linux_amd64|linux_arm64|g' $build_dir/*.sh
    gnu_sed -i 's|jdk-amd64|jdk-arm64|g' $build_dir/install-java-tools.sh
    gnu_sed -i 's|X64|ARM64|g' $build_dir/install-java-tools.sh
    gnu_sed -i 's|x64|arm64|g' $build_dir/install-java-tools.sh
    # Restore the architecture guard after the broad x64 -> arm64 rewrite above.
    perl -0pi -e 's/if is_\w+; then\n  java_arch="amd64"\nelif is_\w+; then\n  java_arch="arm64"/if is_x64; then\n  java_arch="amd64"\nelif is_arm64; then\n  java_arch="arm64"/' $build_dir/install-java-tools.sh
    gnu_sed -i 's|_X64|_ARM64|g' $tests_dir/Java.Tests.ps1
    gnu_sed -i 's|linux-x64|linux-arm64|g' $build_dir/*.sh
    gnu_sed -i 's|ubuntu_64bit|ubuntu_arm64|g' $build_dir/*.sh
    gnu_sed -i 's|arch=amd64 |arch=amd64,arm64 |g' $build_dir/*.sh
    gnu_sed -i 's|contains(\\"amd64\\")|contains(\\"arm64\\")|g' $build_dir/*.sh
    gnu_sed -i 's|x86_64-linux|aarch64-linux|g' $build_dir/*.sh
    gnu_sed -i 's|arch=="amd64"|arch=="arm64"|g' $build_dir/*.sh
  fi

  ## Toolset edits
  # Save ~3.2GB by removing default docker images
  yq -oj -i '.docker.images = []' $TOOLSET_PATH

  # Use official runners for CodeQL
  yq -oj -i 'del(.toolcache[] | select(.name == "CodeQL"))' $TOOLSET_PATH
  # only keep last python version
  yq -oj -i '(.toolcache[] | select(.name == "Python") | select(.versions | length > 0) | .versions) |= [.[-1]]' $TOOLSET_PATH
  # only keep last node version in toolcache
  yq -oj -i '(.toolcache[] | select(.name == "node") | select(.versions | length > 0) | .versions) |= [.[-1]]' $TOOLSET_PATH
  if [ "$ARCH" = "arm64" ]; then
    # PyPy has no arm64 versions upstream, so there is nothing useful to cache.
    yq -oj -i 'del(.toolcache[] | select(.name == "PyPy"))' $TOOLSET_PATH
  else
    # only keep one last pypy version
    yq -oj -i '(.toolcache[] | select(.name == "PyPy") | select(.versions | length > 0) | .versions) |= [.[-1]]' $TOOLSET_PATH
  fi
  # only keep one last go version
  yq -oj -i '(.toolcache[] | select(.name == "go") | select(.versions | length > 0) | .versions) |= [.[-1]]' $TOOLSET_PATH
  yq -oj -i '(.toolcache[] | select(.name == "go") | select(.versions | length > 0)) |= (.default = .versions[-1])' $TOOLSET_PATH
  # only keep one last clang version
  yq -oj -i 'eval(.clang | .versions |= [.[-1]])' $TOOLSET_PATH
  yq -oj -i 'eval(.clang | .default_version |= (parent | .versions[-1]))' $TOOLSET_PATH
  # only keep latest dotnet version
  yq -oj -i 'eval(.dotnet | .aptPackages |= [.[-1]])' $TOOLSET_PATH
  yq -oj -i 'eval(.dotnet | .versions |= [.[-1]])' $TOOLSET_PATH
  # remove PSScriptAnalyzer
  yq -oj -i 'eval(del(.powershellModules[] | select(.name == "PSScriptAnalyzer")))' $TOOLSET_PATH
  # only keep the default java version (use action to install additional, adds 5s)
  yq -oj -i 'eval(.java | .versions |= [(parent | .default)])' $TOOLSET_PATH
  if [ "$ARCH" = "x64" ]; then
    # only keep the default android ndk version
    yq -oj -i 'eval(.android.ndk | .versions |= [(parent | .default)])' $TOOLSET_PATH
  fi
  # only keep latest gfortran version
  yq -oj -i 'eval(.gfortran | .versions |= [.[-1]])' $TOOLSET_PATH
  # only keep one last gcc version
  yq -oj -i 'eval(.gcc | .versions |= [.[-1]])' $TOOLSET_PATH
  # remove sphinxsearch
  yq -oj -i 'del(.apt.cmd_packages[] | select(. == "sphinxsearch"))' $TOOLSET_PATH

  # only keep yarn
  yq -oj -i 'del(.node_modules[] | (select(.name != "yarn" and .name != "typescript")))' $TOOLSET_PATH

  yq -oj -i 'del(.azureModules[])' $TOOLSET_PATH

  ## Upstream build script tweaks
  # Remove chromium since chrome already installed. 500MB saved
  # https://github.com/actions/runner-images/issues/2388
  # might need to add symlinks if causing issues, but let's see
  gnu_sed -i 's/apt-get install "\$chrome_deb_path" -f/\/usr\/bin\/apt-get -qq install "\$chrome_deb_path" -f/' $build_dir/install-google-chrome.sh
  gnu_sed -i 's|# Download and unpack Chromium|invoke_tests "Browsers" "Chrome" \&\& exit 0|' $build_dir/install-google-chrome.sh

  gnu_sed -i 's/unzip "$aws_sam_cli_archive_path" -d \/tmp/unzip -qq "$aws_sam_cli_archive_path" -d \/tmp/' $build_dir/install-aws-tools.sh

  gnu_sed -i 's/apt-get install --no-install-recommends/\/usr\/bin\/apt-get -qq install --no-install-recommends/g' $build_dir/install-php.sh

  gnu_sed -i 's|mkdir $AGENT_TOOLSDIRECTORY|mkdir -p $AGENT_TOOLSDIRECTORY|' $build_dir/configure-environment.sh
}

build_minimal_rolaunch() {
  mkdir -p "$dist_dir"
  rm -f "$rolaunch_bin"
  (cd tools/rolaunch && mise exec go@1.26.1 -- env CGO_ENABLED=0 GOOS=linux GOARCH=$goarch go build -trimpath -ldflags='-s -w' -o "$rolaunch_bin" .)
  if ! command -v upx >/dev/null; then
    echo "upx is required to compress rolaunch for packer upload" >&2
    exit 1
  fi
  upx -f -1 "$rolaunch_bin"
  cp "$rolaunch_bin" "$custom_dir/files/rolaunch"
}
