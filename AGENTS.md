# Agents Guide

## Reproduction workflows

Use `.github/workflows/reproductions.yml` to capture issue-specific reproductions.

- Create one job per issue.
- Specify the runner for the job using runs-on, for example:
  - `runs-on=${{ github.run_id }}/runner=2cpu-linux-arm64`
