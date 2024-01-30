# GitHub Action runner images for AWS

GitHub Action Runner images for AWS, to be used with [RunsOn](https://runs-on.com), or for your own usage.

## AMI details

Supported regions: `us-east-1`, `eu-west-1`.

Search for `runs-on-ubuntu22-full-x64-*` with owner `135269210855`.

## Changes from upstream image

See [bin/patch](bin/patch).

Most notable changes include removal of older cached software versions, as well as Android SDK, since arm64 images are available for RunsOn and emulated compilation is much slower on x64.

This was done to greatly reduce the size of the AMI (40GB, with ~27GB used), which greatly helps with boot and runtime speed when creating instances from that AMI for immediate use.
