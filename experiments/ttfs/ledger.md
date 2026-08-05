# Cold Flex TTFS experiment ledger

This ledger records the frozen inputs, correctness gates, measurements, and
disposition of every experiment in the cold Flex TTFS plan. `pending` entries
must be replaced by `accepted`, `rejected with measurements`, or `inapplicable
with evidence` before the experiment closes.

## Frozen inputs

- Runner-images baseline SHA: `6bfe245c87ad155faee77cd9e4c9aa3c6187714e`
- Monorepo baseline SHA: `80483dd02277f297e28389b90a299ca14631a766`
- Workload repository baseline SHA: `70e11333caf63bf2f0db49df029a9e15662dfa90`
- Baseline rolaunch SHA-256: `7e123a6320a5e8395bbfed8eecabfebaab9ae85e811164becc104e54e80f6af8`
- Candidate rolaunch SHA-256: `d905a7e69e375257d9d6ad12ab1cc31802f43ac90f05cea22892b52adc3365b3`
- Candidate agent SHA-256: `1e35d97a55ea7ab68ad460c2f28e27bf8f746278b516a73564628bf244eb8ece`
- AWS account: `966509368716`
- AWS region/profile: `us-east-1` / `runs-on-dev`
- Parent source AMI: `ami-09ca141c7d43f5fbb`
- Frozen parent AMI: `ami-0c0837aea0d93a18b`
- Frozen parent snapshot: `snap-0a48c5a9f63c3cfe0`
- Frozen baseline AMI/snapshot: `ami-0ce93b0f4d8334b9d` / `snap-091bacee24a954de0`
- Frozen candidate AMI/snapshot: `ami-09874a7909893f7f1` / `snap-0450b442eb0eb5c1f`

Both repositories were clean when the SHAs above were frozen. Generated
`releases/` output is ignored and is not part of the change set.

## Correctness evidence

- `mise exec go@1.26.1 -- go test ./...` in `tools/rolaunch`: pass.
- `make cloudformation-check`: pass.
- Focused agent, Flex provisioning, and Fleet registration tests: pass.
- `mise exec -- make test`: executed; 2,926 tests reached. The untouched
  monorepo baseline independently reproduces
  `TestWriteStickyDiskUnmountScriptCreatesExecutableSafetyHook` failing because
  the implementation creates mode `0700` while the test expects `0755`.
  `pkg/dev` also crashed once during that aggregate run, then passed alone with
  `-race`. These failures are unrelated to the TTFS changes and are not treated
  as candidate regressions.
- Derived Packer template full validation and builder shell syntax: pass.
- AMI smoke tests: pass. Temporary instances `i-086db773eb836f68b`
  (baseline) and `i-09f2f939af0058b28` (candidate) each executed ordinary
  descriptor-free user data and emitted proof SHA-256
  `65992a4fa37767cdb1a38628e485c37a3c15ad42f1e3321ebdc713bf7b6ef0d5`.
  Console evidence showed the expected rolaunch hash for each sibling; the
  candidate left prefetch inactive. Both temporary instances were terminated.
- Cold-run correctness gates: pending.

## Experiment decisions

| Order | Experiment | Changed variable | Evidence | Decision |
| --- | --- | --- | --- | --- |
| 0 | Concurrent rolaunch config prefetch and secure agent handoff | Rolaunch/agent handoff contract | Correctness tests pass; cold samples pending | pending |
| 1 | Earlier Flex/Fleet config publication and JIT overlap | Control-plane publication order | Phase budget pending | pending |
| 2 | Secure JIT delivery and direct Listener execution | JIT delivery/Listener launch | Phase budget pending | pending |
| 3 | Lazy legacy Actions connection and OAuth reuse | Connection initialization | Phase budget pending | pending |
| 4 | Resident Listener, prestarted Worker, and lease overlap | Runner process residency | Phase budget pending | pending |
| 5 | ReadyToRun and targeted read-ahead | Runtime page-cache preparation | Phase budget pending | pending |
| 6 | Runner layout/archive experiments | Runner filesystem layout | Phase budget pending; no layout replacement in first AMI comparison | pending |
| 7 | SquashFS/OverlayFS integration | Runner filesystem packaging | Integration branch availability and phase budget pending | pending |

## Measurement protocol

- Workload repository: `runs-on/test`.
- The branch-triggered workflow's first step emits UTC, epoch-nanosecond, and
  boot-ID markers; artifact hashes and sanitized timing arrays are collected
  afterward.
- Final order: `B1, C1, B2, C2, B3, C3` on identical infrastructure.
- Acceptance threshold: `candidate_mean <= 0.75 * baseline_mean` with three
  valid samples per side.
- Invalid samples include clock skew, wrong artifacts, stale assignments,
  unrelated AWS/GitHub retries, or a failed first step.

## Raw samples and retained resources

Pending sibling AMI creation and measurement. Successful parent and sibling
AMIs remain frozen through the final comparison; failed intermediate AMIs and
their snapshots are deleted.
