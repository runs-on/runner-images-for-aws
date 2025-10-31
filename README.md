# GitHub Actions runner images for AWS

GitHub Actions Runner images for AWS, to be used with [RunsOn](https://runs-on.com/?ref=runner-images-for-aws), or for your own usage.

Official images are replicated and published every 15 days.

## Supported images

### Linux

Those images are very close to 1-1 compatible with official GitHub Actions runner images. Some legacy or easily available through actions software has been removed to ensure faster boot times and lower disk usage.

* `ubuntu22-full-x64`
* `ubuntu22-full-arm64`
* `ubuntu24-full-x64`
* `ubuntu24-full-arm64`

### Windows

Those images are lacking the Hyper-V (and related tooling) framework for Windows, because virtualization on AWS is only available on bare-metal instances. Some legacy or easily available through actions software has been removed to ensure faster boot times and lower disk usage.

* `windows22-full-x64`
* `windows25-full-x64`

### GPU

Those use the Linux images as base, and include NVidia GPU drivers, cuda toolkit, and container toolkit, version 12.

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
