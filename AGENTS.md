# Agents Guide

## Tooling

- Always use `mise` to select and run language/toolchain versions in this repo instead of relying on the ambient system install.
- When a task needs AWS access for image builds or boot profiling, load the AWS profile from the repo-local `.env` file instead of hardcoding it in commands. In practice, use `set -a; source .env; set +a` before invoking build/profile helpers so `AWS_PROFILE` comes from local repo config.

## Image rebuilds and profiling

- Rebuild AMIs with the repo wrapper, not an ad hoc `packer build` command. The normal entrypoint is [`bin/build`](/Users/crohr/dev/runs-on/runner-images-for-aws/bin/build).
- Example rebuild flow for the minimal Ubuntu 24 x64 image:
  - `set -a; source .env; set +a`
  - `mise exec ruby@3.3.8 -- bundle exec bin/build --image-id ubuntu24-minimal-x64`
- The build output prints the new AMI ID. Use that exact AMI ID for follow-up profiling instead of guessing from the AMI name.
- Profile boot behavior with [`bin/utils/profile-boot`](/Users/crohr/dev/runs-on/runner-images-for-aws/bin/utils/profile-boot).
- Example profiling flow:
  - `set -a; source .env; set +a`
  - `mise exec ruby@3.3.8 -- bundle exec bin/utils/profile-boot ami-xxxxxxxxxxxxxxxxx`
- `bin/utils/profile-boot` already resolves a subnet tagged `runner-image-for-aws=true`, launches a temporary instance, enables SSH through user-data, captures `systemd-analyze` output, and terminates the instance afterward.
- When validating a boot change, record at least:
  - the AMI ID that was profiled
  - `ssh_ready_s`
  - `systemd-analyze time`
  - the top entries from `systemd-analyze blame`

## Reproduction workflows

Use `.github/workflows/reproductions.yml` to capture issue-specific reproductions.

- Create one job per issue.
- Specify the RunsOn runner label in `runs-on`, for example:
  - `runs-on=${{ github.run_id }}/runner=2cpu-linux-arm64` (RunsOn custom runner syntax; see https://runs-on.com)

## Generated releases

- Treat `releases/` as generated output from the build/sync scripts.
- If a build depends on regenerated release files, run [`bin/build`](/Users/crohr/dev/runs-on/runner-images-for-aws/bin/build) with `--sync` or run [`bin/sync`](/Users/crohr/dev/runs-on/runner-images-for-aws/bin/sync) first.
- Do not commit `releases/` changes unless the user explicitly asks for them.
