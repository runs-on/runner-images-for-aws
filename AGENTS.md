# Agents Guide

## Reproduction workflows

Use `.github/workflows/reproductions.yml` to capture issue-specific reproductions.

- Create one job per issue.
- Specify the RunsOn runner label in `runs-on`, with `env=bootstrap`, for example:
  - `runs-on=${{ github.run_id }}/env=bootstrap/runner=2cpu-linux-arm64` (RunsOn custom runner syntax; see https://runs-on.com)
- RunsOn jobs in the runs-on organization run on the bootstrap stack, which serves only `env=bootstrap`. A label without `env=` asks for `env=production`, which no stack serves: the job stays queued until it is cancelled.

## Generated releases

- Treat `releases/` as generated output from the build/sync scripts.
- Do not commit `releases/` changes unless the user explicitly asks for them.
