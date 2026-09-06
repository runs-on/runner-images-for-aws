param(
    [string[]]$Services,
    [switch]$Restore,
    [string]$ReceiptPath = "C:\ProgramData\RunsOn\BootDiagnostics\service-screen.json"
)

$ErrorActionPreference = "Stop"
$protectedServices = @(
    "AmazonSSMAgent", "BITS", "docker", "hns", "HvHost", "LanmanServer",
    "LanmanWorkstation", "msiserver", "TrustedInstaller", "vmcompute", "vmms",
    "wcnfs", "Winmgmt", "wuauserv"
)

if ($Restore) {
    if (-not (Test-Path $ReceiptPath)) { throw "Screening receipt not found: $ReceiptPath" }
    $receipt = Get-Content $ReceiptPath -Raw | ConvertFrom-Json
    foreach ($item in $receipt.services) {
        Set-Service -Name $item.name -StartupType $item.original_startup_type
    }
    Write-Host "Restored $($receipt.services.Count) service startup modes"
    exit 0
}

if (-not $Services -or $Services.Count -eq 0) {
    throw "Pass only services shown on the measured critical path"
}

$screen = foreach ($name in $Services | Sort-Object -Unique) {
    if ($protectedServices -contains $name) {
        throw "Refusing to screen protected capability service: $name"
    }
    $service = Get-CimInstance Win32_Service -Filter "Name='$name'"
    if (-not $service) { throw "Service not found: $name" }
    if ($service.StartMode -eq "Disabled") { throw "Service is already Disabled: $name" }

    $startupType = switch ($service.StartMode) {
        "Auto" { "Automatic" }
        "Manual" { "Manual" }
        default { throw "Unsupported startup mode $($service.StartMode) for $name" }
    }
    [pscustomobject]@{ name = $name; original_startup_type = $startupType }
}

New-Item (Split-Path $ReceiptPath) -ItemType Directory -Force | Out-Null
[ordered]@{
    created_utc = [DateTime]::UtcNow.ToString("o")
    policy = "Automatic-to-Manual screening only"
    services = @($screen)
} | ConvertTo-Json -Depth 4 | Set-Content $ReceiptPath -Encoding UTF8

foreach ($item in $screen) {
    Set-Service -Name $item.name -StartupType Manual
    Write-Host "Set $($item.name) to Manual for one derivative AMI screen"
}
