# Cold Flex TTFS experiment ledger

## Outcome

The direct early-lease prototype passed the requested small-cohort mean gate
when both predeclared, interleaved cohorts were pooled without removing any
successful sample:

- baseline mean: `22.093897499s` (n=6, sample SD `12.531710717s`)
- candidate mean: `16.122213729s` (n=6, sample SD `3.893236338s`)
- candidate/baseline: `0.729713`
- improvement: `27.0287%`
- required candidate ceiling: `16.570423124s` (`0.75 * baseline_mean`)

The result is noisy. In particular, the stock runner's B1 sample in the second
cohort waited about 34 seconds between runner launch and the first job step.
That is not an unrelated retry or a polling delay: the job was received by the
Flex dev server 1.053 seconds after creation and completed successfully. It is
the GitHub dispatch tail that the direct early-lease Worker is intended to
remove. The first cohort alone improved by `18.8707%`; the second cohort alone
improved by `32.1545%`. Both cohorts and all raw values are retained below.

The latency result does **not** make the direct-listener design acceptable for
production. The experiment is closed and that part of the candidate is
rejected. Its relay depends on private Listener/Worker framing: advertising a
newer runner version while implementing behavior copied from an older release
can select incompatible GitHub broker behavior or violate the newer Worker's
payload assumptions, while advertising the older version can trigger update
enforcement. Runner upgrade timing belongs to the user's control plane, so the
bridge cannot safely pin or impersonate a version. At 200-way overlap it also
required one bridge and one official Listener per job, consuming about 23.8 GiB
aggregate RSS on the dev host, which cannot fit the production control plane's
512 MiB allocation.

## Frozen inputs

- AWS account/profile/region: `966509368716` / `runs-on-dev` / `us-east-1`
- exact Canonical source AMI: `ami-09ca141c7d43f5fbb`
- final fresh baseline AMI/snapshot: `ami-07c6d78df2965e34b` / `snap-06ede7a7335d36692`
- final fresh candidate AMI/snapshot: `ami-0358a7b469575734a` / `snap-0f5ebded7a91c0b0c`
- baseline rolaunch SHA-256: `40d20c5124d9a5e0ae464e9a0eea622cfb450b64db19de7038022b603bce5c43`
- candidate rolaunch SHA-256: `c720ff146aba7fac8bad9b15dbad22832a62ece4e8170e45d9fd2be91ecca371`
- candidate/baseline agent SHA-256: `c16b2eaeef5f53b33787b1081807f33556de31b22b570813cb09f5131ac13dae`
- agent S3 key: `agents/v3.2.1-flex-dev-local-rob/agent-linux-x86_64`
- agent object size: `11,262,952` bytes
- official runner: `2.336.0`
- instance selector: exact `m8a.large`, on-demand, `us-east-1`
- root volume: 30 GiB `gp3`, 3,000 IOPS, 400 MiB/s throughput
- measurement root initialization: 200 MiB/s through temporary launch-template
  version 11; Fleet inherited that mapping instead of replacing it
- workflow commit for cohort 1: `b7d1386`
- workflow commit for cohort 2: `45f79ee`
- measured monorepo commit: `be663b27`
- final monorepo PR head: `af3948a5` (build-neutral interface-only CI fix)
- runner-images checkpoint commit: `938163d`

The final baseline and candidate AMIs were each built from the exact Canonical
source, not derived from an earlier experiment AMI. This avoids inherited or
non-contiguous EBS snapshot block layout. New experimental AMIs were launched
repeatedly before stabilized conclusions were drawn.

## Measurement protocol and correctness

- Repository: `runs-on/test`.
- Order in each cohort: `B1,C1,B2,C2,B3,C3`, enforced with job dependencies.
- TTFS: GitHub job `created_at` to the first workflow-step epoch-nanosecond
  marker.
- Every sample used an exact AMI ID and verified the rolaunch and running agent
  hashes above.
- Both cohorts completed all six jobs successfully. There were no job retries,
  failed first steps, wrong artifacts, stale assignments, or clock-skew
  exclusions.
- Cohort 1: <https://github.com/runs-on/test/actions/runs/31065426308>
- Cohort 2: <https://github.com/runs-on/test/actions/runs/31067235039>
- Focused rolaunch, agent, Flex provisioning, registration, and Fleet tests
  passed. Commit hooks and lint passed.
- The aggregate monorepo suite's pre-existing sticky-disk mode mismatch (`0700`
  implementation versus `0755` test expectation) also reproduces on the frozen
  baseline and is unrelated.

## Raw samples

| Cohort | Sample | Variant | Job ID | TTFS (s) |
| --- | --- | --- | --- | ---: |
| 1 | B1 | baseline | `92502028547` | 18.943029002 |
| 1 | C1 | candidate | `92502076772` | 13.555825071 |
| 1 | B2 | baseline | `92502117264` | 16.456230156 |
| 1 | C2 | candidate | `92502167056` | 14.549260516 |
| 1 | B3 | baseline | `92502206975` | 15.753178090 |
| 1 | C3 | candidate | `92502249606` | 13.394542026 |
| 2 | B1 | baseline | `92507399213` | 47.580625627 |
| 2 | C1 | candidate | `92507530308` | 23.607196680 |
| 2 | B2 | baseline | `92507596670` | 16.701916396 |
| 2 | C2 | candidate | `92507647636` | 17.052141387 |
| 2 | B3 | baseline | `92507704268` | 17.128405722 |
| 2 | C3 | candidate | `92507752122` | 14.574316694 |

## Phase evidence

- Cohort 1 candidate early-lease delivery to first step:
  `1.081s`, `1.123s`, `1.109s` (mean `1.104s`).
- Cohort 1 stock runner launch to first step:
  `4.148s`, `4.154s`, `3.781s` (mean `4.028s`).
- Cohort 2 candidate early-lease delivery to first step:
  `0.816s`, `1.013s`, `1.185s` (mean `1.005s`).
- Cohort 2 stock runner launch to first step:
  `34.366s`, `4.315s`, `4.016s` (mean `14.232s`).
- The JIT setup itself was about 12 ms; the material saving comes from taking
  the lease before the instance is ready and delivering the job directly to
  the official Worker instead of waiting for post-registration GitHub dispatch.
- Secure adoption of rolaunch's validated identity/config removes the agent's
  duplicate IMDS path (about 100 ms) while retaining cloud-init/no-rolaunch
  fallback compatibility.

## 200-job scale experiment

The final candidate soak was run
[`31097515591`](https://github.com/runs-on/test/actions/runs/31097515591)
against the dev Flex server's native medium preset: 8 provisioning workers, 4
registration workers, and the normal 8/s EC2 limiter. It used 200 on-demand
`m8a.large` jobs, `max-parallel: 200`, the frozen inputs above, and a 300-second
hold. No additional 2 requests/s pacing override was used.

- All 200 scale jobs completed successfully.
- All 200 emitted a first-step marker and validated the exact AMI, rolaunch and
  live agent hashes, assignment, and early-lease mode.
- The observer reached 200 bridges, 200 official Listeners, and 200 acquired
  leases concurrently.
- Three CreateFleet responses included a partial `RequestLimitExceeded`, but
  every response returned the requested instance; no launch was retried.
- The GitHub-hosted analysis job failed before publishing CSV/JSON. The run is
  therefore not claimed as a complete analyzer or 200-sample performance pass.

Sanitized telemetry from 408 one-second samples:

| Metric | Value |
| --- | ---: |
| Maximum Flex CPU / RSS | 16.467% / 102,092 KiB |
| Maximum Flex threads / FDs | 217 / 446 |
| Maximum host processes | 1,309 |
| Maximum bridges / Listeners | 200 / 200 |
| Maximum aggregate bridge RSS | 2,126,464 KiB |
| Maximum aggregate Listener RSS | 21,677,468 KiB |
| Minimum available host memory | 33,386,192 KiB |
| Maximum bridge log count / bytes | 400 / 200,892 |
| Maximum acquired leases | 200 |

After normal completion, bridge and Listener processes, matching EC2
instances, assignment-scoped S3 objects, and experiment claims converged to
zero. The lock table contained only `server-background-tasks-leader`. Flex
exhausted its GitHub App rate budget and skipped explicit unregister calls for
some completed runners; the available CLI credential lacked organization-runner
enumeration permission, so runner-registration convergence was not proven.

The following scale runs were rejected without excluding their failures:

| Run | Reason |
| --- | --- |
| `31086263646` | workflow parser failure |
| `31086410356` | temporary-filesystem inode exhaustion |
| `31088068753` | Listener configuration/symlink failure |
| `31088863341` | validation/setup defects |
| `31090209948` | live agent hash resolved a deleted executable path |
| `31091363417` | transient receipt assertion |
| `31091753294` | transient acknowledgement assertion; 22 old Listeners needed cleanup |
| `31093405031` | concurrent timing-file rewrite; cancellation left 122 lease objects for exact-prefix cleanup |
| `31094368263` | harness incorrectly rejected compatible fallback handoff |
| `31094997056` | 199/200 leases; one official Listener stalled; xhigh preset |
| `31095760091` | xhigh EC2 throttle storm; stopped |
| `31096379646` | medium reached 199/200; one official Listener stopped progressing after a 100-second broker GET timeout |

Sequential Listener recovery was implemented and exercised by focused tests,
but the final 200-job wave did not need it. It treats a symptom while adding
supervision around a private protocol; it does not resolve version fidelity or
the resource model.

The planned independent 200-job baseline, candidate, and mass-cancellation
cohorts were not run after the experiment was closed. No mean/p95 scale claim is
made from the final soak.

## Experiment disposition

| Experiment | Evidence | Decision |
| --- | --- | --- |
| Concurrent rolaunch config prefetch and secure descriptor handoff | Exact hash/ownership/version checks passed; candidate adopted the handoff in every measured run | accepted |
| Earlier Flex/Fleet config publication and JIT overlap | Config and JIT were published while EC2 booted; no stale assignment or correctness failure | accepted |
| Secure direct Listener/Worker lease delivery | Main phase reduction and 200-way execution succeeded, but the relay depends on private versioned framing and consumed about 23.8 GiB aggregate RSS | rejected for production; experiment closed |
| Skip duplicate agent IMDS/metadata fetch when rolaunch supplied it | About 100 ms removed; descriptor-free/cloud-init fallback tests pass | accepted |
| Skip duplicate cold mount/instance-store probes and fixed script delay | Focused tests pass; retained as small hot-path reductions | accepted |
| Lazy legacy Actions connection and OAuth reuse | Direct Worker delivery bypasses this Listener connection path entirely | inapplicable/superseded |
| Resident/prestarted Worker | Nine warm-ups on fresh `ami-0d59378846392dafd`; stabilized TTFS about 15.37s and only ~0.17s delivery improvement | rejected as default; secure opt-in implementation retained |
| ReadyToRun Worker cache | Nine warm-ups on fresh `ami-01ff425cb1d05b567`; no stabilized TTFS improvement | rejected |
| Boot-time targeted Worker read-ahead | Fresh `ami-0a20c67786a35bbda`; W1-W9 TTFS `41.024,19.641,18.625,17.990,15.375,15.815,15.622,15.314,14.935s`; W7-W9 mean `15.290s`; early reads contended with rolaunch | rejected |
| Alternative runner archive/layout | Runtime experiments showed page preparation was not the limiting phase after direct delivery | inapplicable for this candidate |
| SquashFS/OverlayFS runner packaging | Adds mount/decompression work on the already I/O-sensitive boot path, with no measured phase budget sufficient to justify it | inapplicable |
| Direct CreateFleet `VolumeInitializationRate` override | Live EC2 rejected the raw Smithy field with `UnknownParameter`; current `FleetEbsBlockDeviceRequest` does not expose it | inapplicable |
| Inherit LT root mapping with 200 MiB/s initialization | Preserved AMI gp3/3,000/400 settings and stabilized the measurement control | accepted for measurement only |

User-level root-volume initialization remains tracked separately in
<https://github.com/runs-on/monorepo/issues/302>, assigned to `rob-ships` with
label `todo`; the proposed product default remains lazy initialization.

## Retained and removed resources

Retained for reproducibility:

- baseline `ami-07c6d78df2965e34b` / `snap-06ede7a7335d36692`
- candidate `ami-0358a7b469575734a` / `snap-0f5ebded7a91c0b0c`

Removed after confirming no non-terminated instance referenced them:

- `ami-09874a7909893f7f1` / `snap-0450b442eb0eb5c1f`
- `ami-0d59378846392dafd` / `snap-054e1bef4af24ecbe`
- `ami-01ff425cb1d05b567` / `snap-0f21b286426e23b51`
- `ami-0a20c67786a35bbda` / `snap-0a91e18291ee55053`
- `ami-0714bbecfe0bf2e2e` / `snap-08bbd7da6d70d2534`
- `ami-0c0837aea0d93a18b` / `snap-0a48c5a9f63c3cfe0`
- `ami-0ce93b0f4d8334b9d` / `snap-091bacee24a954de0`
- temporary launch-template version 11

The local Flex dev server was stopped. Packer left no extra builder volumes.
Deleted AMIs, snapshots, and the LT version are not recoverable.
