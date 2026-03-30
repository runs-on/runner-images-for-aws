# Agents Guide

## Tooling

- Always use `mise` to select and run language/toolchain versions in this repo instead of relying on the ambient system install.
- After making a meaningful change, create a git commit before moving on.

## Reproduction workflows

Use `.github/workflows/reproductions.yml` to capture issue-specific reproductions.

- Create one job per issue.
- Specify the RunsOn runner label in `runs-on`, for example:
  - `runs-on=${{ github.run_id }}/runner=2cpu-linux-arm64` (RunsOn custom runner syntax; see https://runs-on.com)

## Generated releases

- Treat `releases/` as generated output from the build/sync scripts.
- If a build depends on regenerated release files, run [`bin/build`](/Users/crohr/dev/runs-on/runner-images-for-aws/bin/build) with `--sync` or run [`bin/sync`](/Users/crohr/dev/runs-on/runner-images-for-aws/bin/sync) first.
- Do not commit `releases/` changes unless the user explicitly asks for them.
