# Windows 2025 Findings (Issue #19)

Date: 2026-03-02
Target: `windows25-full-x64`

## Latest run summary (custom amazon plugin path)

- Build command run: `PACKER_AMAZON_PLUGIN_BINARY=/tmp/runs-on-packer-plugin-amazon/bin/packer-plugin-amazon make build-windows25-full-x64`
- Local Packer CLI: `v1.14.2`
- Custom plugin install during run:
  - `Installing custom amazon plugin from /tmp/runs-on-packer-plugin-amazon/bin/packer-plugin-amazon`
  - Installed binary: `.tmp/packer/plugins/windows25-full-x64/github.com/hashicorp/amazon/packer-plugin-amazon_v1.8.1_x5.0_darwin_arm64`
- Builder instance launched: `i-0477f1b5b2b40575e` on `m8i.4xlarge` (Windows, `us-east-1`)

## EC2 nested virtualization check

From `aws ec2 describe-instances` for `i-0477f1b5b2b40575e`:

- `CpuOptions.NestedVirtualization = enabled`

This confirms the patched plugin path successfully requested nested virtualization at instance launch.

## Provisioning evidence

`Install-WindowsFeatures.ps1` succeeded for Hyper-V-related entries:

- `Windows Feature 'Hyper-V' was activated successfully`
- `Windows Feature 'HypervisorPlatform' was activated successfully`
- `Windows Feature 'Hyper-V-PowerShell' was activated successfully`

## Build failure point

The run failed later in `Install-VisualStudio.ps1`:

- `Non zero exit code returned by the installation process : -2147024784`
- This maps to `0x80070070` (`ERROR_DISK_FULL`).
- Follow-on script error:
  - `Failed to install Visual Studio; The path 'C:\temp-to-delete\vslogs.zip' either does not exist or is not a valid file system path.`
- Final packer failure:
  - `Script exited with non-zero exit status: 4294967295. Allowed exit codes are: [0 3010]`

## Outcome

- Nested virtualization blocker is resolved for the launched `m8i.4xlarge` build instance.
- Hyper-V feature installation now succeeds in-provisioning.
- Current blocker is Visual Studio installation failure (disk-space error path) on this run (`volume_size=50`).
- No AMI artifact was produced; source instance was terminated by packer cleanup.

## Rerun after increasing disk size

Config change applied:

- `config.yml` for `windows25-full-x64`: `volume_size` increased from `50` to `150`

Rerun command:

- `PACKER_AMAZON_PLUGIN_BINARY=/tmp/runs-on-packer-plugin-amazon/bin/packer-plugin-amazon make build-windows25-full-x64`

Rerun validation highlights:

- New builder instance: `i-0e4bd1f365be1fe9a` (`m8i.4xlarge`, `us-east-1`)
- `CpuOptions.NestedVirtualization = enabled` confirmed via `describe-instances`
- Hyper-V features again succeeded:
  - `Hyper-V`
  - `HypervisorPlatform`
  - `Hyper-V-PowerShell`
- Visual Studio succeeded:
  - `Installation successful in 1318.82 seconds`
- VS extensions installed successfully
- Disk evidence after resize:
  - `C:` total `160520187904`
  - `C:` free `132902477824`

Rerun failure point (new blocker):

- Failed later in `Install-DotnetSDK.ps1`:
  - `Remove-Item : Cannot find path 'C:\Program Files\dotnet\sdk-manifests\8.0.100\microsoft.net.sdk.aspire' because it does not exist.`
  - Script exited non-zero (`Allowed exit codes are: [0]`)
- Build result:
  - `Build 'amazon-ebs.build_ebs' errored after 1 hour 26 minutes`
  - No AMI artifact produced; source instance terminated by packer cleanup.

## Investigation: why `Install-DotnetSDK.ps1` failed

Root cause is in the manifest-restore loop in `Install-DotnetSDK.ps1`:

- Script line 128 runs:
  - `Remove-Item -Path "$sdkManifestPath\$($_.BaseName)" -Recurse -Force`
- This assumes every manifest directory moved earlier from `TEMP_DIR\8.0.100` also exists in the freshly installed `C:\Program Files\dotnet\sdk-manifests\8.0.100`.
- During the rerun, one moved manifest (`microsoft.net.sdk.aspire`) was not present in the freshly installed folder, so `Remove-Item` failed with `PathNotFound`.
- Because the provisioner treats this as a hard failure, packer aborted the build.

Relevant evidence:

- Build log line with failing path:
  - `C:\Program Files\dotnet\sdk-manifests\8.0.100\microsoft.net.sdk.aspire`
- Script location:
  - `releases/windows25/x64/images/windows/scripts/build/Install-DotnetSDK.ps1` line 128

## Rerun after guarding delete with `Test-Path` (current)

Patch applied in repo patching step:

- File: `bin/patch/windows25-x64`
- Change:
  - from:
    - `Remove-Item -Path "$sdkManifestPath\$($_.BaseName)" -Recurse -Force | Out-Null`
  - to:
    - `if (Test-Path -Path "$sdkManifestPath\$($_.BaseName)") { Remove-Item -Path "$sdkManifestPath\$($_.BaseName)" -Recurse -Force | Out-Null }`

Rerun command:

- `PACKER_AMAZON_PLUGIN_BINARY=/tmp/runs-on-packer-plugin-amazon/bin/packer-plugin-amazon make build-windows25-full-x64`

Observed outcomes from rerun log (`/tmp/windows25_custom_plugin_build_rerun3.log`):

- Hyper-V feature install still succeeds (`Hyper-V`, `HypervisorPlatform`, `Hyper-V-PowerShell`).
- Visual Studio install succeeds (`Install-VisualStudio.ps1` completed successfully).
- Dotnet stage now passes:
  - `Provisioning with powershell script: .../Install-DotnetSDK.ps1`
  - `dotnet-install: Installed version is 10.0.102`
- The previous failure (`Cannot find path ... microsoft.net.sdk.aspire`) does not recur.
- Build proceeds into cleanup/slimming and then `Install-NativeImages.ps1`.

New late-stage anomaly observed:

- During post-cleanup transition, a PowerShell command reported:
  - `The term 'c:/Windows/Temp/packer-ps-env-vars-...ps1' is not recognized...`
- Provisioning continued after this line (packer did not terminate immediately) and moved into `Install-NativeImages.ps1`.

Final outcome of this rerun:

- `Install-NativeImages.ps1` failed:
  - `Update of x64 native images failed with exit code -1`
  - `FullyQualifiedErrorId : Update of x64 native images failed with exit code -1`
- Build result:
  - `Build 'amazon-ebs.build_ebs' errored after 2 hours 4 minutes`
  - `Script exited with non-zero exit status: 1. Allowed exit codes are: [0]`
  - `Builds finished but no artifacts were created.`

Current blocker after fixing dotnet manifest deletion:

- `Install-NativeImages.ps1` (`NGen: update x64 native images...`) exits with `-1` on this image path.

## Mitigation applied in template

To unblock builds while root-cause cleanup work is pending:

- `patches/windows/templates/windows25-full-x64.pkr.hcl`
  - set `instance_type = "m8i.large"` (from larger instance)
  - disabled `Install-NativeImages.ps1` in the final provisioner script list

Rationale:

- NGen is an optimization step, not required for tool availability.
- Skipping it avoids the current late-stage failure and allows AMI creation while keeping Hyper-V/VS/C++ enablement changes.

## Durable root-fix implementation and new build attempt

Implemented durable root-fix in patching pipeline:

- File updated: `bin/patch/windows25-x64`
- Change in generated `Invoke-Cleanup.ps1`:
  - preserve temp directories by removing these entries from destructive directory deletion loop:
    - `$env:SystemRoot\Temp`
    - `$env:TEMP`
- Goal:
  - prevent deletion of packer/powershell temp scripts between provisioners
  - avoid recurrence of:
    - `c:/Windows/Temp/packer-ps-env-vars-...ps1 is not recognized`

Template state used for this attempt:

- `instance_type = "m8i.large"` (as requested)
- `Install-NativeImages.ps1` re-enabled

Build command:

- `PACKER_AMAZON_PLUGIN_BINARY=/tmp/runs-on-packer-plugin-amazon/bin/packer-plugin-amazon make build-windows25-full-x64`

Evidence from new run (`/tmp/windows25_custom_plugin_build_rootfix.log`):

- Instance:
  - `Instance ID: i-0d4ba5dbd099ddb38`
  - `instance type: m8i.large`
  - `CpuOptions.NestedVirtualization = enabled`
- Hyper-V features succeeded:
  - `Windows Feature 'Hyper-V' was activated successfully`
  - `Windows Feature 'HypervisorPlatform' was activated successfully`
  - `Windows Feature 'Hyper-V-PowerShell' was activated successfully`
- Visual Studio succeeded on `m8i.large`:
  - `Installation successful in 1828.24 seconds`

New blocker in this run (different from previous blockers):

- Stalled in `Install-OpenSSL.ps1` at:
  - `Downloading package from https://slproweb.com/download/Win64OpenSSL-3_6_1.exe to C:\temp-to-delete\Win64OpenSSL-3_6_1.exe...`
- No further build log progress after this line for an extended period; run was manually terminated and instance terminated to stop cost.

Outcome:

- Root-fix patch is in place and durable (via `bin/patch/windows25-x64`).
- Build advanced much further than previous failed run and did not hit the earlier `packer-ps-env-vars` / `Install-NativeImages` failure path yet.
- Final validation of cleanup->native-images path remains pending because this run was blocked earlier by OpenSSL download stage.

## 2026-03-03 rerun findings (retry3 -> retry4)

### retry3 (`/tmp/windows25_custom_plugin_build_retry3.log`)

Command:

- `PACKER_AMAZON_PLUGIN_BINARY=/tmp/runs-on-packer-plugin-amazon/bin/packer-plugin-amazon make build-windows25-full-x64`

Instance / launch validation:

- `Instance ID: i-0aee00fad7bae4d12`
- `instance_type: m8i.large`
- `CpuOptions.NestedVirtualization = enabled`

Progress reached:

- Hyper-V feature block succeeded again:
  - `Hyper-V`
  - `HypervisorPlatform`
  - `Hyper-V-PowerShell`
- Visual Studio succeeded:
  - `Installation successful in 1736.45 seconds`
- Kubernetes tools succeeded (`kind`, `kubectl`, `helm`, `minikube`)

Failure point:

- After reboot and pause, run entered `Install-Wix.ps1`.
- Build then failed with WinRM reconnect/upload timeout:
  - `Build 'amazon-ebs.build_ebs' errored after 1 hour 23 minutes`
  - `Error processing command: Error uploading ps script containing env vars: Error uploading file to $env:TEMP\\winrmcp-....tmp: Couldn't create shell: unknown error Post "https://34.227.192.73:5986/wsman": dial tcp ...:5986: connect: operation timed out`

Interpretation:

- This happened between provisioners right after `Install-Wix.ps1`, consistent with reboot/WinRM instability during a multi-script provisioner chain.

### durable fix applied for retry4

File changed:

- `patches/windows/templates/windows25-full-x64.pkr.hcl`

Change:

- Split `Install-Wix.ps1` into its own `powershell` provisioner.
- Added explicit `windows-restart` immediately after Wix:
  - `check_registry = true`
  - `restart_timeout = "30m"`
- Left remaining scripts (`Install-VSExtensions.ps1`, `Install-AzureCli.ps1`, `Install-ChocolateyPackages.ps1`, `Install-JavaTools.ps1`, `Install-Kotlin.ps1`, `Install-OpenSSL.ps1`) in a following provisioner.

### retry4 started (current)

Command:

- `PACKER_AMAZON_PLUGIN_BINARY=/tmp/runs-on-packer-plugin-amazon/bin/packer-plugin-amazon make build-windows25-full-x64`

Log:

- `/tmp/windows25_custom_plugin_build_retry4.log`

Current instance:

- `Instance ID: i-0ce2e5f5d53e8c15d`
- `instance_type: m8i.large`
- `CpuOptions.NestedVirtualization = enabled`

## 2026-03-03 lean rerun on 120 GiB (current)

Scope for this rerun:

- lean Visual Studio workload path enabled (no `--allWorkloads`)
- `instance_type = m8i.large`
- `volume_size = 120`
- custom amazon plugin path with nested virtualization support
- image tests remain disabled by design

Launch/provisioning validation:

- Builder instance: `i-055dfa966f493147a` (`m8i.large`, `us-east-1`)
- `CpuOptions.NestedVirtualization = enabled` confirmed via `describe-instances`
- Hyper-V features succeeded in this run:
  - `Windows Feature 'Hyper-V' was activated successfully`
  - `Windows Feature 'HypervisorPlatform' was activated successfully`
  - `Windows Feature 'Hyper-V-PowerShell' was activated successfully`
- Visual Studio succeeded:
  - `Installation successful in 1458.34 seconds`
- Dotnet stage (previous blocker) succeeded:
  - `Install-DotnetSDK.ps1` completed, installed `.NET 10.0.102`
- Native images stage reached and passed retry:
  - `NGen: update x64 native images succeeded on retry`
  - proceeded into `NGen: update x86 native images...`

Live build status at time of writing:

- Source instance was finalized/stopped and AMI creation started:
  - AMI: `ami-02b8aa4051ba88897`
  - Snapshot: `snap-012e590b91157bf2b`
- Packer is waiting for AMI readiness while snapshot progresses.

### Space audit findings during this run

Top space consumers on the running build VM (live SSM audit):

- `C:\Program Files\Microsoft Visual Studio` ~`29.07 GiB`
  - `...\2022\Enterprise\VC` ~`17.75 GiB`
  - `...\2022\Enterprise\Common7` ~`9.0 GiB`
- `C:\Windows\WinSxS` ~`11.59 GiB`
- `C:\Program Files\dotnet` ~`5.32 GiB`
- `C:\Windows\System32` ~`4.39 GiB`
- `C:\Windows\Installer` ~`3.19` to `3.85 GiB` (grew during install flow)
- `C:\ProgramData\Package Cache` ~`1.53` to `1.56 GiB`
- `C:\ProgramData\chocolatey` grew from `0.55` to ~`1.54 GiB` during package installs

Low-impact contributors (not major size drivers):

- `C:\Program Files\Android` ~`0.18 GiB`
- `kubernetes-cli` ~`0.238 GiB`
- `Minikube` ~`0.174 GiB`
- `kubernetes-helm` ~`0.06 GiB`
- hosted toolcache during install wave observed ~`0.94 GiB`

### 120 GiB sizing evidence from `WINDOWS_METRICS.md`

- Observed peak used during provisioning before final cleanup:
  - `92.43 GiB` used, `27.06 GiB` free (`2026-03-03T14:24:36Z`)
- During image slimming/cleanup:
  - usage dropped from low 90s into high 70s (`~77-80 GiB`)
- Build-time transient peak is materially higher than post-cleanup footprint, so final AMI occupancy is lower than provisioning peak.

## 2026-03-03 lean cut (Java/K8s/ServiceFabric/Rust/MSYS2) and rerun

Change request implemented:

- removed `Install-KubernetesTools.ps1`
- removed Java stack (`Install-JavaTools.ps1`, `Install-Kotlin.ps1`)
- removed `Install-ServiceFabricSDK.ps1`
- removed `Install-Rust.ps1`
- removed `Install-Msys2.ps1` and `Install-Mingw64.ps1`

File changed:

- `patches/windows/templates/windows25-full-x64.pkr.hcl`

Build rerun command:

- `PACKER_AMAZON_PLUGIN_BINARY=/tmp/runs-on-packer-plugin-amazon/bin/packer-plugin-amazon make build-windows25-full-x64`

Current rerun instance:

- `Instance ID: i-0b17814a6edbd9604`
- `instance_type: m8i.large`
- `CpuOptions.NestedVirtualization = enabled` (validated via `aws ec2 describe-instances`)

Metrics capture:

- `WINDOWS_METRICS.md` now includes a dedicated section for `i-0b17814a6edbd9604`
- poll interval remains 3 minutes
- early rows show pre-SSM stage (`ssm-None`) while WinRM/bootstrap steps run

## 2026-03-05 issue #19 package audit and follow-up

Source reviewed:

- https://github.com/runs-on/runner-images-for-aws/issues/19

Issue #19 package asks called out by users:

- `bash`
- Rust toolchain (`cargo`/`rustc`)
- `pwsh` (PowerShell 7)
- `AzureSignTool`

Validation run on AMI `ami-0ef43650ecc48cf98` (`us-west-2`) using instance `i-0876226637fae8e0e` via SSM:

- `FOUND bash => C:\Program Files\Git\bin\bash.exe`
- `FOUND pwsh => C:\Program Files\PowerShell\7\pwsh.exe`
- `MISSING cargo`
- `MISSING rustc`
- `MISSING AzureSignTool`

Changes applied to restore missing tooling:

1. Re-enabled Rust install in template:
   - `patches/windows/templates/windows25-full-x64.pkr.hcl`
   - Added `${path.root}/../scripts/build/Install-Rust.ps1` to provisioner script list.
2. Added AzureSignTool to dotnet tools in patch pipeline:
   - `bin/patch/windows25-x64`
   - Appends `AzureSignTool` to `.dotnet.tools` if not already present.
3. Extended issue-19 reproduction checks:
   - `.github/workflows/reproductions.yml`
   - Added validation for `bash`, `cargo`, `rustc`, `pwsh`, `AzureSignTool`.

## 2026-03-05 us-west-2 run (`volume_size=120`) + Rust/Cargo validation

Build command:

- `AWS_PROFILE=crohr AWS_DEFAULT_REGION=us-west-2 PACKER_AMAZON_PLUGIN_BINARY=/tmp/runs-on-packer-plugin-amazon/bin/packer-plugin-amazon bundle exec bin/build --image-id windows25-full-x64 --region us-west-2 --subnet-id subnet-03a94566`

Key runtime confirmations:

- Builder instance: `i-066ce30df6863ddb3` (`m8i.4xlarge`)
- Nested virtualization confirmed on builder:
  - `CpuOptions.NestedVirtualization = enabled`
- Hyper-V feature block succeeded again:
  - `Hyper-V`
  - `HypervisorPlatform`
  - `Hyper-V-PowerShell`
- Visual Studio install succeeded:
  - `Installation successful in 1072.5 seconds`
- Rust install script ran and completed during provisioning (`Install-Rust.ps1` logs showed cargo/rustc components installed).

### Peak disk usage tracking (`WINDOWS_METRICS.md`)

- Sampling interval: 180s via SSM during build.
- Final observed peak:
  - `95.46 GB / 119.50 GB (79.88%)`
- Near-end used value after cleanup dropped to ~`78.72 GB`.

Implication for minimum EBS sizing from this run:

- 120 GB worked with ~24 GB free at peak.
- A hard floor should stay above ~100 GB to preserve safety margin for variance.

### Build result and blocker

Provisioning and AMI creation reached completion, but final attribute publication failed:

- Error:
  - `ResourceLimitExceeded: You have reached your quota of 60 for the number of public images allowed in this Region.`
- Packer cleanup behavior:
  - deregistered source AMI in `us-west-2` (`ami-0491c768ecf1a25b9`)
  - deleted snapshot (`snap-009ec487195f5bc4c`)

Surviving artifact:

- Cross-region copy in `us-east-1` remained available and private:
  - `ami-04bce52682ce46c9c`
  - name: `runs-on-dev-windows25-full-x64-20260305163814`

### Post-build validation on surviving AMI (`us-east-1`)

Validation instance:

- `i-03497ab344df26b7b`

Checks:

- `VSWHERE_EXISTS=True`
- `VS_INSTALL_PATH=C:\Program Files\Microsoft Visual Studio\2022\Enterprise`
- `DEVENV_EXISTS=True`
- `CL_X64_PATH=...\\VC\\Tools\\MSVC\\...\\Hostx64\\x64\\cl.exe`
- `PWSH_PATH=C:\Program Files\PowerShell\7\pwsh.exe`
- `BASH_PATH=C:\Program Files\Git\bin\bash.exe`
- `AZURESIGNTOOL_VERSION=MISSING`
- `CARGO_VERSION=MISSING`
- `RUSTC_VERSION=MISSING`

Root cause for missing Rust/Cargo on runtime user context:

- Rust was installed only under default profile paths:
  - `C:\Users\Default\.cargo\bin\cargo.exe` exists
  - `C:\Users\Default\.cargo\bin\rustc.exe` exists
- Not promoted to machine-level `PATH`/env in a way that made binaries resolvable for normal runtime users.

Fix implemented in repo:

- Added patch file: `patches/windows/files/patch-Install-Rust.ps1`
- Behavior:
  - copies rustup/cargo homes to machine location (`C:\Rust\\.rustup`, `C:\Rust\\.cargo`)
  - sets machine env vars `RUSTUP_HOME` and `CARGO_HOME`
  - adds `C:\Rust\\.cargo\\bin` to machine PATH
  - validates `cargo.exe` and `rustc.exe` after promotion

Outstanding follow-up:

- Re-run image build with this new Rust patch and either:
  - free public AMI quota / raise quota, or
  - skip making AMIs public during build and publish separately.

## 2026-03-05 durable peak tracking automation

Implemented durable peak tracking so manual polling is no longer required for Windows builds:

- Added script: `scripts/monitor-windows-builder-disk.sh`
  - polls builder instance by `ami_name` tag
  - samples `C:` usage via SSM every 180s (default)
  - continuously tracks highest observed used GB
  - appends a per-build section and final peak summary into `WINDOWS_METRICS.md`
- Wired `bin/build` to auto-start/stop this monitor for any `windows*` image build.

Operational knobs:

- `WINDOWS_METRICS_FILE` (default: `WINDOWS_METRICS.md`)
- `WINDOWS_METRICS_INTERVAL_SEC` (default: `180`)
