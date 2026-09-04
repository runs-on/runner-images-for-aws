param(
    [string]$OutputDirectory = "C:\ProgramData\RunsOn\BootDiagnostics\export"
)

$ErrorActionPreference = "Stop"
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null

$channels = @(
    "System",
    "Application",
    "Microsoft-Windows-Hyper-V-Hypervisor-Admin",
    "Microsoft-Windows-Hyper-V-Hypervisor-Operational",
    "Microsoft-Windows-Kernel-Boot/Operational",
    "Microsoft-Windows-Kernel-PnP/Configuration",
    "Microsoft-Windows-Diagnostics-Performance/Operational",
    "Microsoft-Windows-UserPnp/DeviceInstall"
)

foreach ($channel in $channels) {
    & cmd.exe /d /c "wevtutil.exe get-log `"$channel`" >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { continue }
    $safeName = $channel -replace '[^A-Za-z0-9.-]', '_'
    & wevtutil.exe export-log $channel (Join-Path $OutputDirectory "$safeName.evtx") /overwrite:true
}

$pantherDestination = Join-Path $OutputDirectory "Panther"
New-Item -Path $pantherDestination -ItemType Directory -Force | Out-Null
foreach ($source in @("C:\Windows\Panther", "C:\Windows\System32\Sysprep\Panther")) {
    if (Test-Path $source) {
        Copy-Item -Path $source -Destination $pantherDestination -Recurse -Force
    }
}

$launchDirectory = "C:\ProgramData\RunsOn\Launch"
if (Test-Path $launchDirectory) {
    Copy-Item -Path $launchDirectory -Destination $OutputDirectory -Recurse -Force
}

$bootDiagnosticsDirectory = "C:\ProgramData\RunsOn\BootDiagnostics"
$wprTrace = Join-Path $bootDiagnosticsDirectory "first-boot.etl"
if (Test-Path $wprTrace) {
    Copy-Item -Path $wprTrace -Destination $OutputDirectory -Force
}

$bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
$portableEvents = foreach ($channel in $channels) {
    try {
        Get-WinEvent -FilterHashtable @{ LogName = $channel; StartTime = $bootTime } -ErrorAction Stop |
            Where-Object {
                $_.Level -le 3 -or
                $_.ProviderName -match "Hyper-V|Kernel-(Boot|PnP)|Service Control Manager|Sysprep|UserPnp"
            } |
            ForEach-Object {
                [ordered]@{
                    channel = $_.LogName
                    provider = $_.ProviderName
                    event_id = $_.Id
                    level = $_.LevelDisplayName
                    time_utc = $_.TimeCreated.ToUniversalTime().ToString("o")
                    message = $_.Message
                    properties = @($_.Properties | ForEach-Object { $_.Value })
                }
            }
    } catch {
        Write-Warning "Could not create portable event summary for ${channel}: $($_.Exception.Message)"
    }
}
$portableEvents | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $OutputDirectory "event-summary.json") -Encoding UTF8

$scmStart = Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = 6005; StartTime = $bootTime } -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated | Select-Object -First 1
$ssmRunning = Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = "Service Control Manager"; Id = 7036; StartTime = $bootTime } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match "AmazonSSMAgent|Amazon SSM Agent" } |
    Sort-Object TimeCreated | Select-Object -First 1

$launchStatePath = Join-Path $launchDirectory "timings.json"
$launchState = if (Test-Path $launchStatePath) { Get-Content $launchStatePath -Raw | ConvertFrom-Json } else { $null }
$sysprepCompletion = $null
$setupAct = Get-ChildItem -Path @("C:\Windows\Panther\setupact.log", "C:\Windows\System32\Sysprep\Panther\setupact.log") -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc | Select-Object -Last 1
if ($setupAct) {
    $sysprepLine = Select-String -Path $setupAct.FullName -Pattern "SYSPRP.*(?:complete|success)|specialize.*(?:complete|success)" |
        Select-Object -Last 1
    if ($sysprepLine -and $sysprepLine.Line -match '^\s*(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
        $sysprepCompletion = $Matches.time
    }
}
$ec2LaunchLog = "C:\ProgramData\Amazon\EC2Launch\log\agent.log"
$windowsReady = $null
if (Test-Path $ec2LaunchLog) {
    $readyLine = Select-String -Path $ec2LaunchLog -Pattern "Windows is Ready to use" | Select-Object -Last 1
    if ($readyLine -and $readyLine.Line -match '^(?<time>\d{4}-\d{2}-\d{2}T[^ ]+)') {
        $windowsReady = $Matches.time
    }
    Copy-Item -Path $ec2LaunchLog -Destination $OutputDirectory -Force
}

$hypervisorLaunchType = & bcdedit.exe /enum "{current}" | Select-String "hypervisorlaunchtype"
$summary = [ordered]@{
    boot_time_utc = $bootTime.ToString("o")
    service_control_start_utc = if ($scmStart) { $scmStart.TimeCreated.ToUniversalTime().ToString("o") } else { $null }
    sysprep_completion_log_time = $sysprepCompletion
    runs_on_launch = $launchState
    ssm_running_utc = if ($ssmRunning) { $ssmRunning.TimeCreated.ToUniversalTime().ToString("o") } else { $null }
    windows_ready_utc = $windowsReady
    hypervisorlaunchtype = if ($hypervisorLaunchType) { $hypervisorLaunchType.ToString().Trim() } else { "default" }
}
$summaryPath = Join-Path $OutputDirectory "milestones.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding UTF8

$archivePath = "$OutputDirectory.zip"
if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
Compress-Archive -Path (Join-Path $OutputDirectory "*") -DestinationPath $archivePath -CompressionLevel Optimal
$summary | ConvertTo-Json -Depth 8 -Compress | Write-Output
