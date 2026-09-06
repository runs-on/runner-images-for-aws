param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Auto", "Off")]
    [string]$Mode
)

$ErrorActionPreference = "Stop"
$value = $Mode.ToLowerInvariant()
& bcdedit.exe /set "{current}" hypervisorlaunchtype $value
if ($LASTEXITCODE -ne 0) {
    throw "bcdedit failed with exit code $LASTEXITCODE"
}

Write-Host "Set hypervisorlaunchtype=$value. Reboot before measuring."
Write-Warning "This is a diagnostic derivative only. Never publish an AMI with hypervisorlaunchtype=off."
