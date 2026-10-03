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
* `ubuntu26-full-x64`
* `ubuntu26-full-arm64`

See the notes below for Ubuntu 26 specifics.

Minimal images only ship the GitHub Actions runner and Docker, for the fastest boot times:

* `ubuntu24-minimal-x64`
* `ubuntu24-minimal-arm64`

### Windows

These images are being aligned with upstream "full" Windows tooling (including Visual Studio/C++ and Hyper-V-related components where supported). Some legacy or easily available through actions software may still be removed to ensure faster boot times and lower disk usage. Availability of virtualization-dependent components can vary based on EC2 instance capabilities and build tooling support.

* `windows22-full-x64`
* `windows25-full-x64`
* `windows25-gpu-x64`

### GPU

Those use the corresponding base images.
Linux GPU images include NVIDIA GPU drivers, CUDA toolkit, and container toolkit.
Windows GPU images include the AWS GRID driver plus the CUDA toolkit.

* `ubuntu22-gpu-x64`
* `ubuntu24-gpu-x64`
* `ubuntu24-gpu-arm64`
* `windows25-gpu-x64`

### StepSecurity

Those are the full Ubuntu images with the [StepSecurity](https://www.stepsecurity.io/) integration preinstalled:

* `ubuntu22-stepsecurity-x64`
* `ubuntu22-stepsecurity-arm64`
* `ubuntu24-stepsecurity-x64`
* `ubuntu24-stepsecurity-arm64`
* `ubuntu26-stepsecurity-x64`
* `ubuntu26-stepsecurity-arm64`

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

For any image, search for:

*  name: `runs-on-v2.2-<IMAGE_ID>-*`
*  owner: `135269210855`

For instance, for the `ubuntu22-full-x64` image, search for:

*  name: `runs-on-v2.2-ubuntu22-full-x64-*`
*  owner: `135269210855`

## Notes

* SSH daemon is disabled by default, so be sure to enable it in a user-data script if needed.
* For full images, the new rolaunch boot path applies only to Ubuntu 26, including its GPU and StepSecurity descendants. Ubuntu 22 and 24 full images keep their existing cloud-init user-data path.
* Fresh Ubuntu 26 x64 UEFI launches use a one-shot direct kernel boot. GRUB stays first for reboots and legacy fallback. Ubuntu 26 arm64 stays on GRUB. Secure Boot is outside this fast-path contract and falls back through shim and GRUB.
* On those Ubuntu 26 images, user data must be a raw, uncompressed shebang shell script. Rolaunch does not process cloud-config, multipart MIME, or compressed payloads and requires a reachable EC2 instance metadata endpoint.
* Ubuntu 26 uses `systemd-networkd` directly and disables cloud-init. This fast path supports a single primary ENA with IPv4 or dual-stack DHCP, including custom DHCP DNS and search domains.
* Ubuntu 26 does not support multi-ENI policy routing, secondary IP discovery, IPv6-only subnets, old Xen network drivers, or persistent netplan configuration. Use Ubuntu 22 or 24 when those network layouts are required.
* For local validation, set `AMI_PUBLIC=false` to keep a full Ubuntu AMI private.

## Build provenance

`releases/` is generated build input and is not committed. `upstream.lock.yml`
pins the exact `actions/runner-images` revision used by every build. Run
`bin/update-upstream-lock` and commit the lock when intentionally updating
upstream. A nightly workflow runs the same update, validates every Ubuntu and
Windows sync/patch path, and commits the lock to `main` only when validation
succeeds.

Each build uploads a JSON provenance manifest. It records the repository and
upstream revisions, source AMI, patch and configuration digests, Packer and
plugin versions, and output AMI and snapshots. Releases emit a second manifest
that links each copied AMI and snapshot to the source build digest. Every output
carries its matching manifest digest and workflow URL in
`runs-on:provenance-digest` and `runs-on:provenance-uri` tags.

## Inspector AMI scanning

Deploy the AWS-native Inspector scanner stack from this repo:

```sh
AWS_PROFILE=<profile> make inspector-stack-deploy
```

The target defaults to `us-east-1`, stack name `runs-on-inspector-ami-scanner`, and notification email `security@runs-on.com`. Optional overrides:

```sh
AWS_REGION=us-east-1 \
INSPECTOR_STACK_NAME=runs-on-inspector-ami-scanner \
INSPECTOR_NOTIFICATION_EMAIL=security@runs-on.com \
make inspector-stack-deploy
```

The stack creates the scanner VPC, outbound-only temporary scan instances, IAM roles, encrypted S3 report bucket, SNS topic, EventBridge schedule, Lambda orchestration, and Step Functions workflow. Confirm the SNS email subscription before expecting notifications.

Amazon Inspector EC2 scanning must be enabled in `us-east-1` for the account. Reports are exported under `s3://<stack-report-bucket>/inspector/<image-id>/<channel>/<ami-id>/`.

AMI scanning is opt-in from `config.yml`. Add `inspect: true` to an image entry to scan the latest dev and prod AMIs matching `runs-on-dev-<image_id>-*` and `runs-on-v2.2-<image_id>-*`. Missing `inspect` defaults to `false`. The `inspector_scan` AMI tag is scanner-owned state; do not manage it from Packer templates or `bin/copy-ami`.

The stack template lives in [cloudformation/inspector-ami-scanner.yml](cloudformation/inspector-ami-scanner.yml).

## AMI cleanup

The daily cleanup checks every publication region in `config.yml` for both image
prefixes. `--region REGION` limits a manual run to one region, including regions
outside that list. Only AMIs owned by the authenticated account are considered.

- Production: keep the latest available public image in each family. Retire each
  predecessor ten days after its immediate available public successor was
  published in that region. Several releases within ten days can remain together.
- Development: delete every development image created more than seven days ago,
  including the newest or only version. This also covers copies outside us-east-1
  in the configured regions. Build preparation uses the same seven-day policy.

Publication writes the `runs-on:published-at` AMI tag after verifying that the
regional image is available and public. Reruns preserve it. Existing untagged
public images start their clock when cleanup first observes them; their creation
date cannot establish when publication completed. The initial apply therefore
records timestamps and grants existing predecessors a full ten-day window.

Preview both plans before applying:

```sh
bundle exec bin/utils/cleanup-amis --prod --dry-run --json /tmp/prod-cleanup.json
bundle exec bin/utils/cleanup-amis --dry-run --json /tmp/dev-cleanup.json
```

Dry-run never changes AWS resources, even with `--force`. It lists candidates,
retention reasons, timestamp initialization, and missing recovery protection.
Without `--dry-run`, the command prompts before applying; `--force` skips the
prompt. It verifies the entire plan before any deletion. `AMI_PREFIX` can narrow
the configured production or development prefix, as build preparation does.
The former `--all` bypass is removed.

### Seven-day recovery

Before enabling deletions, deploy the two Recycle Bin rules in each configured
region using the intended AWS account:

```sh
make ami-recycle-bin-deploy
```

The CloudFormation template `cloudformation/ami-recycle-bin.yml` protects AMIs
and snapshots tagged `creator=RunsOn`. Wait until the rules are `available`.
Cleanup refuses deletion when either the AMI or any backing snapshot lacks an
available seven-day rule. A dry-run reports missing protection without applying
anything. It never creates rules automatically.

The deployment identity needs CloudFormation deployment permissions and Recycle
Bin rule management permissions (`rbin:CreateRule`, `rbin:GetRule`,
`rbin:UpdateRule`, `rbin:DeleteRule`, and tagging permissions). The cleanup identity
needs `rbin:ListRules`, `rbin:GetRule`, `ec2:DescribeImages`,
`ec2:DescribeSnapshots`, `ec2:CreateTags`, `ec2:DeregisterImage`, and
`ec2:DeleteSnapshot`. The AWS CLI must be installed alongside the Ruby bundle.

Snapshots continue to incur storage charges during recovery retention. Restore
snapshots first, then the AMI, before the seven days expire. An AMI in Recycle Bin
cannot launch new instances. A restored old image still meets the cleanup age
policy, so pause automated cleanup before recovering it for extended use.

Old production prefixes and standalone orphan snapshots are outside this policy.
