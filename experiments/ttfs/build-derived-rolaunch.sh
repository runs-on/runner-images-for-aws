#!/usr/bin/env bash

set -euo pipefail

: "${PARENT_AMI_ID:?PARENT_AMI_ID is required}"
: "${ROLAUNCH_BINARY:?ROLAUNCH_BINARY is required}"
: "${TTFS_VARIANT:?TTFS_VARIANT must be baseline or candidate}"

case "${TTFS_VARIANT}" in
  baseline|candidate) ;;
  *) echo "TTFS_VARIANT must be baseline or candidate" >&2; exit 2 ;;
esac

readonly region="${AWS_DEFAULT_REGION:-us-east-1}"
readonly profile="${AWS_PROFILE:-runs-on-dev}"
readonly template_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly template="${template_dir}/derived-rolaunch.pkr.hcl"
readonly timestamp="${TTFS_IMAGE_VERSION:-$(date -u +%Y%m%d%H%M%S)}"
readonly ami_name="${TTFS_AMI_NAME:-runs-on-dev-ttfs-${TTFS_VARIANT}-${timestamp}}"

test -f "${ROLAUNCH_BINARY}"
test -x "${ROLAUNCH_BINARY}"

parent_state="$(aws --profile "${profile}" --region "${region}" ec2 describe-images \
  --image-ids "${PARENT_AMI_ID}" \
  --owners self \
  --query 'Images[0].State' \
  --output text)"
test "${parent_state}" = "available"

subnet_id="${SUBNET_ID:-}"
if [[ -z "${subnet_id}" ]]; then
  subnet_id="$(aws --profile "${profile}" --region "${region}" ec2 describe-subnets \
    --filters Name=state,Values=available Name=tag:runner-image-for-aws,Values=true \
    --query 'sort_by(Subnets[?MapPublicIpOnLaunch==`true`],&AvailabilityZone)[0].SubnetId' \
    --output text)"
fi
if [[ -z "${subnet_id}" || "${subnet_id}" = "None" ]]; then
  echo "No tagged public builder subnet found; set SUBNET_ID" >&2
  exit 1
fi

packer init "${template}"
packer build \
  -color=false \
  -var "ami_name=${ami_name}" \
  -var "parent_ami_id=${PARENT_AMI_ID}" \
  -var "region=${region}" \
  -var "rolaunch_binary=${ROLAUNCH_BINARY}" \
  -var "subnet_id=${subnet_id}" \
  -var "variant=${TTFS_VARIANT}" \
  "${template}"
