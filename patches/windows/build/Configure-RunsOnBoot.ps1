################################################################################
##  File:  Configure-RunsOnBoot.ps1
##  Desc:  Boot-time settings for ephemeral RunsOn runners. Every launch is a
##         fresh EBS volume, so anything the boot reads or waits for before
##         the user data runs is paid on every job.
################################################################################

$ErrorActionPreference = "Stop"

# EC2Launch v2: the RunsOn agent grows the root partition itself, runners have
# no use for a wallpaper, and activation is done by a startup task below
# instead of blocking the preReady stage for 3 to 5 s. Keep password rotation:
# derived image builders use it for WinRM, and each runner needs its own credential.
# (EC2Launch skips activateWindows when it is placed in postReady.)
$agentConfig = @"
version: "1.0"
config:
  - stage: preReady
    tasks:
      - task: setAdminAccount
        inputs:
          password:
            type: random
      - task: setDnsSuffix
        inputs:
          suffixes:
            - `$REGION.ec2-utilities.amazonaws.com
  - stage: postReady
    tasks:
      - task: startSsm
"@
$agentConfigPath = "C:\ProgramData\Amazon\EC2Launch\config\agent-config.yml"
Set-Content -Path $agentConfigPath -Value $agentConfig -Encoding ascii
Write-Host "EC2Launch agent config written to $agentConfigPath"

# Activate against the AWS KMS endpoint, which the base image already
# configures (169.254.169.250:1688), one minute after boot and off the boot
# path. A runner in notification mode for its first minute loses nothing.
$activateAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cscript.exe" -Argument "//B //Nologo $env:SystemRoot\System32\slmgr.vbs /ato"
$activateTrigger = New-ScheduledTaskTrigger -AtStartup
$activateTrigger.Delay = "PT1M"
$activatePrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$activateSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable
Register-ScheduledTask -TaskName "RunsOn Windows activation" -Action $activateAction -Trigger $activateTrigger -Principal $activatePrincipal -Settings $activateSettings -Force | Out-Null
Write-Host "Windows activation scheduled one minute after boot"

# Virtualization-based security has no job to do on a throwaway CI VM and
# costs boot time. The Hyper-V role itself stays installed.
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name EnableVirtualizationBasedSecurity -Value 0 -Type DWord
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name RequirePlatformSecurityFeatures -Value 0 -Type DWord
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name Enabled -Value 0 -Type DWord
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name LsaCfgFlags -Value 0 -Type DWord
Write-Host "Virtualization-based security disabled"

# Boot loader: no boot UI, no menu wait, no boot logging.
foreach ($setting in @(
    @("{current}", "quietboot", "on"),
    @("{current}", "bootux", "disabled"),
    @("{current}", "bootlog", "no"),
    @("{bootmgr}", "timeout", "0")
)) {
    & bcdedit.exe /set $setting[0] $setting[1] $setting[2] | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdedit /set $($setting -join ' ') failed with exit code $LASTEXITCODE" }
}
Write-Host "Boot loader settings applied"

# Services that start automatically but do nothing for a runner until a job
# asks for them. Manual services still start on demand.
# TextInputManagementService is protected and refuses the change; leave it.
# vmms stays automatic: nothing starts it on demand, and without it the Hyper-V
# cmdlets (Get-VMSwitch, New-VM) fail on nested-virt runners.
$manualServices = @(
    "WSLService",
    "Audiosrv",
    "AudioEndpointBuilder",
    "Themes",
    "TrkWks",
    "WpnService"
)
function Set-RunsOnServiceStartup {
    param([string]$Name, [string]$StartupType)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { return }
    try {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        Write-Host "Service '$Name' set to $StartupType"
    } catch {
        Write-Warning "Service '$Name' left as is: $($_.Exception.Message)"
    }
}
foreach ($name in $manualServices) { Set-RunsOnServiceStartup -Name $name -StartupType Manual }
foreach ($name in @("edgeupdate", "edgeupdatem")) { Set-RunsOnServiceStartup -Name $name -StartupType Disabled }
