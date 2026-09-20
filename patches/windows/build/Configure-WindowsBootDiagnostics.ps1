################################################################################
##  File:  Configure-WindowsBootDiagnostics.ps1
##  Desc:  Preserve first-boot evidence for Windows specialization experiments
################################################################################

$ErrorActionPreference = "Stop"
$diagnosticsDirectory = "C:\ProgramData\RunsOn\BootDiagnostics"
New-Item -Path $diagnosticsDirectory -ItemType Directory -Force | Out-Null

$channels = @(
    "Microsoft-Windows-Hyper-V-Hypervisor-Admin",
    "Microsoft-Windows-Hyper-V-Hypervisor-Operational",
    "Microsoft-Windows-Kernel-Boot/Operational",
    "Microsoft-Windows-Kernel-PnP/Configuration",
    "Microsoft-Windows-Diagnostics-Performance/Operational",
    "Microsoft-Windows-UserPnp/DeviceInstall"
)

foreach ($channel in $channels) {
    & cmd.exe /d /c "wevtutil.exe get-log `"$channel`" >nul 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Event channel is unavailable: $channel"
        continue
    }
    & cmd.exe /d /c "wevtutil.exe set-log `"$channel`" /enabled:true /retention:false /maxsize:67108864"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not configure event channel: $channel"
    }
}

foreach ($channel in @("System", "Application")) {
    & cmd.exe /d /c "wevtutil.exe set-log `"$channel`" /retention:false /maxsize:67108864"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not configure bounded $channel event logging"
    }
}

if ($env:CAPTURE_WPR_BOOT_TRACE -ne "true") {
    Write-Host "WPR boot capture is disabled for this build"
    exit 0
}

$wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
if (-not $wpr) {
    Write-Warning "WPR is unavailable; event collection remains enabled"
    exit 0
}

$stopScript = Join-Path $diagnosticsDirectory "Stop-WprBootTrace.ps1"
@'
$output = "C:\ProgramData\RunsOn\BootDiagnostics\first-boot.etl"
Start-Sleep -Seconds 120
& wpr.exe -boottrace -stopboot $output
if ($LASTEXITCODE -ne 0) {
    "WPR stop failed with exit code $LASTEXITCODE" | Set-Content "C:\ProgramData\RunsOn\BootDiagnostics\wpr-error.txt"
}
Unregister-ScheduledTask -TaskName "RunsOnStopWprBootTrace" -Confirm:$false -ErrorAction SilentlyContinue
'@ | Set-Content -Path $stopScript -Encoding UTF8

$action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$stopScript`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "RunsOnStopWprBootTrace" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

& wpr.exe -boottrace -addboot GeneralProfile -filemode
if ($LASTEXITCODE -ne 0) {
    Unregister-ScheduledTask -TaskName "RunsOnStopWprBootTrace" -Confirm:$false -ErrorAction SilentlyContinue
    Write-Warning "WPR could not arm a boot trace; event collection remains enabled"
}
