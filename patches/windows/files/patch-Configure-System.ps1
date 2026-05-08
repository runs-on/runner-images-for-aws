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

function Start-RunsOnRequiredService {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [scriptblock]$Validation
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "Required service '$Name' not present"
    }

    Write-Host "Setting required service '$Name' startup type to Automatic"
    Set-Service -Name $Name -StartupType Automatic -ErrorAction Stop

    if ($service.Status -ne "Running") {
        Write-Host "Starting required service '$Name'"
        Start-Service -Name $Name -ErrorAction Stop
    }

    (Get-Service -Name $Name).WaitForStatus("Running", "00:01:00")

    if ($Validation) {
        & $Validation
    }
}

Write-Host "Applying final Windows service policy"

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

$disabledServices | ForEach-Object {
    Set-RunsOnServicePolicy -Name $_ -StartupType Disabled
}

Start-RunsOnRequiredService -Name "docker" -Validation {
    docker version
    if ($LASTEXITCODE -ne 0) {
        throw "docker version failed with exit code $LASTEXITCODE"
    }
}
