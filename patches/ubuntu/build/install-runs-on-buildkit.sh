#!/bin/bash -e
################################################################################
##  File:  install-runs-on-buildkit.sh
##  Desc:  Pull RunsOn's patched BuildKit image and pin it for runs-on/action
################################################################################

source $HELPER_SCRIPTS/etc-environment.sh

# runs-on/action passes RUNS_ON_BUILDKIT_IMAGE to docker/setup-buildx-action
# through its buildkit-image output. Pre-pulling saves the download on runners
# that keep the root volume's Docker storage; runners with instance-store or
# tmpfs Docker storage start empty and pull the same digest at job time.
# renovate: datasource=docker depName=public.ecr.aws/c5h5o9k1/runs-on/buildkit versioning=regex:^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)-runs-on\.(?<build>\d+)$
BUILDKIT_IMAGE="public.ecr.aws/c5h5o9k1/runs-on/buildkit:v0.33.0-runs-on.1@sha256:PENDING"

for attempt in 1 2 3 4 5; do
    if docker pull "$BUILDKIT_IMAGE"; then
        break
    fi
    if [ "$attempt" -eq 5 ]; then
        echo "Failed to pull $BUILDKIT_IMAGE" >&2
        exit 1
    fi
    sleep $((attempt * 10))
done

set_etc_environment_variable "RUNS_ON_BUILDKIT_IMAGE" "$BUILDKIT_IMAGE"

invoke_tests "RunsOnBuildKit"
