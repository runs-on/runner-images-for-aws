# Patched into Configure-System.ps1

function Set-RunsOnServicePolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Automatic", "Manual", "Disabled")]
        [string]$StartupType,

        [bool]$StopIfRunning = $true
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Host "Service '$Name' not present, skipping"
        return
    }

    Write-Host "Setting service '$Name' startup type to $StartupType"
    Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop

    if ($StopIfRunning -and $service.Status -eq "Running") {
        Write-Host "Stopping service '$Name'"
        Stop-Service -Name $Name -Force -ErrorAction Stop
        (Get-Service -Name $Name).WaitForStatus("Stopped", "00:01:00")
    }
}

Write-Host "Applying final Windows service policy"

$manualServices = @(
    "docker"
)

$disabledServices = @(
    "W3SVC",
    "WAS",
    "AppHostSvc",
    "MSMQ",
    "NetMsmqActivator",
    "NetPipeActivator",
    "NetTcpActivator",
    "RemoteRegistry",
    "Spooler",
    "SQLWriter"
)

$manualServices | ForEach-Object {
    Set-RunsOnServicePolicy -Name $_ -StartupType Manual
}

$disabledServices | ForEach-Object {
    Set-RunsOnServicePolicy -Name $_ -StartupType Disabled
}

Set-RunsOnServicePolicy -Name "WinRM" -StartupType Disabled -StopIfRunning $false
