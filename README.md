# GitHub Actions runner images for AWS

GitHub Actions Runner images for AWS, to be used with [RunsOn](https://runs-on.com/?ref=runner-images-for-aws), or for your own usage.

Official images are replicated and published every 15 days.

## Supported images

### Base images compatible with managed GitHub runners

* `ubuntu22-full-x64`
* `ubuntu22-full-arm64`
* `ubuntu24-full-x64`
* `ubuntu24-full-arm64`

### GPU-optimized images

Those use the above images as base, and include latest NVidia GPU drivers, cuda toolkit, and container toolkit.

* `ubuntu22-gpu-x64`
* `ubuntu24-gpu-x64`

## Supported regions

- North Virginia (`us-east-1`)
- Ohio (`us-east-2`)
- Oregon (`us-west-2`)
- Ireland (`eu-west-1`)
- London (`eu-west-2`)
- Paris (`eu-west-3`)
- Frankfurt (`eu-central-1`)
- Mumbai (`ap-south-1`)
- Tokyo (`ap-northeast-1`)
- Singapore (`ap-southeast-1`)
- Sydney (`ap-southeast-2`)

## Find the AMI

For the `x86_64` image, search for:

*  name: `runs-on-v2.2-<IMAGE_ID>-*`
*  owner: `135269210855`

For instance, for the `ubuntu22-full-x64` image, search for:

*  name: `runs-on-v2.2-ubuntu22-full-x64-*`
*  owner: `135269210855`

## Notes

* SSH daemon is disabled by default, so be sure to enable it in a user-data script if needed.
