# No Docker daemon runs in a build.
edit 's/^docker info$/: docker info # oci: no daemon/' ': docker info # oci'
edit 's/^\( *\)docker pull /\1: oci: no daemon: docker pull /' ': oci: no daemon: docker pull'
