# GitHub Action runner images for AWS

GitHub Action Runner images for AWS, to be used with [RunsOn](https://runs-on.com/?ref=runner-images-for-aws), or for your own usage.

Official images are replicated and published every 15 days.

[![ubuntu22 x64](https://github.com/runs-on/runner-images-for-aws/actions/workflows/check-x64.yml/badge.svg)](https://github.com/runs-on/runner-images-for-aws/actions/workflows/check-x64.yml)
[![ubuntu22 arm64](https://github.com/runs-on/runner-images-for-aws/actions/workflows/check-arm64.yml/badge.svg)](https://github.com/runs-on/runner-images-for-aws/actions/workflows/check-arm64.yml)

## Supported regions

- North Virginia (`us-east-1`)
- Ohio (`us-east-2`)
- Oregon (`us-west-2`)
- Ireland (`eu-west-1`)
- Frankfurt (`eu-central-1`)
- London (`eu-west-2`)
- Tokyo (`ap-northeast-1`)
- Singapore (`ap-southeast-1`)
- Sydney (`ap-southeast-2`)

## Find the AMI

For the `x86_64` image, search for:

*  name: `runs-on-v2.2-ubuntu22-full-x64-*`
*  owner: `135269210855`

For the `ARM64` image, search for:

*  name: `runs-on-v2.2-ubuntu22-full-arm64-*`
*  owner: `135269210855`

## Notes

* SSH daemon is disabled by default, so be sure to enable it in a user-data script.