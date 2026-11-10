# No podman network exists in a build, and netavark cannot reach the kernel's netfilter.
edit 's/^\( *\)podman network reload --all 2>\/dev\/null$/\1podman network reload --all 2>\/dev\/null || true/' 'reload --all 2>/dev/null || true'
