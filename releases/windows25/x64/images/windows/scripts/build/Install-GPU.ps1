##  File:  Install-GPU.ps1
##  Desc:  Install and verify NVIDIA GPU support for Windows GPU images.

$ErrorActionPreference = 'Stop'

$markerDirectory = 'C:\ProgramData\RunsOn'
$markerFile = Join-Path $markerDirectory 'gpu-installed.txt'
$downloadDirectory = Join-Path $markerDirectory 'GPU'
$driverLogDirectory = Join-Path $downloadDirectory 'Logs'
$driverInstaller = Join-Path $downloadDirectory 'nvidia-grid-driver.exe'
$cudaVersion = '12.9.1.576'
$cudaVersionLabel = '12.9'
$driverBucketUrl = 'https://ec2-windows-nvidia-drivers.s3.amazonaws.com'
$gridLicenseRegistryPath = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\GridLicensing'

function New-RunsOnDirectory {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$ValidExitCodes = @(0)
    )

    Write-Host "Running: $FilePath $($ArgumentList -join ' ')"
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow
    if ($ValidExitCodes -notcontains $process.ExitCode) {
        throw "Command failed with exit code $($process.ExitCode): $FilePath $($ArgumentList -join ' ')"
    }

    return $process.ExitCode
}

function Get-LatestAwsGridDriverKey {
    [xml]$listing = (Invoke-WebRequest -Uri "$driverBucketUrl/?prefix=latest/" -UseBasicParsing).Content
    $keys = @($listing.ListBucketResult.Contents | ForEach-Object { $_.Key })

    $matchingKey = $keys |
        Where-Object { $_ -match '^latest/.+server2025.+\.exe$' } |
        Select-Object -First 1

    if (-not $matchingKey) {
        $matchingKey = $keys |
            Where-Object { $_ -match '^latest/.+\.exe$' } |
            Select-Object -First 1
    }

    if (-not $matchingKey) {
        throw 'Unable to locate an AWS Windows GRID driver installer in the latest bucket listing.'
    }

    return $matchingKey
}

function Ensure-AwsGridDriverInstaller {
    New-RunsOnDirectory -Path $downloadDirectory
    New-RunsOnDirectory -Path $driverLogDirectory

    if (Test-Path -Path $driverInstaller) {
        Write-Host "Reusing AWS GRID driver installer from $driverInstaller"
        return
    }

    $driverKey = Get-LatestAwsGridDriverKey
    $driverUri = "$driverBucketUrl/$driverKey"

    Write-Host "Downloading AWS GRID driver from $driverUri"
    Invoke-WebRequest -Uri $driverUri -OutFile $driverInstaller -UseBasicParsing
}

function Install-AwsGridDriver {
    Ensure-AwsGridDriverInstaller

    Invoke-ExternalCommand -FilePath $driverInstaller -ArgumentList @(
        '-s',
        '-n',
        'Display.Driver',
        "-log:$driverLogDirectory",
        '-loglevel:6'
    ) -ValidExitCodes @(0, 1)

    New-Item -Path $gridLicenseRegistryPath -Force | Out-Null
    New-ItemProperty `
        -Path $gridLicenseRegistryPath `
        -Name 'NvCplDisableManageLicensePage' `
        -PropertyType DWord `
        -Value 1 `
        -Force | Out-Null
}

function Install-CudaToolkit {
    $choco = (Get-Command choco.exe -ErrorAction Stop).Source
    Invoke-ExternalCommand -FilePath $choco -ArgumentList @(
        'upgrade',
        'cuda',
        '--version',
        $cudaVersion,
        '--source',
        'https://community.chocolatey.org/api/v2/',
        '--no-progress',
        '-y'
    ) -ValidExitCodes @(0, 1605, 1614, 1641, 3010)
}

function Get-NvidiaSmiPath {
    $command = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $fallbackPath = 'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe'
    if (Test-Path -Path $fallbackPath) {
        return $fallbackPath
    }

    throw 'nvidia-smi.exe not found'
}

function Get-NvccPath {
    $command = Get-Command nvcc.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $fallbackPath = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$cudaVersionLabel\bin\nvcc.exe"
    if (Test-Path -Path $fallbackPath) {
        return $fallbackPath
    }

    throw 'nvcc.exe not found'
}

if (Test-Path -Path $markerFile) {
    $nvidiaSmi = Get-NvidiaSmiPath
    & $nvidiaSmi
    & $nvidiaSmi -L

    $nvcc = Get-NvccPath
    & $nvcc --version

    Remove-Item -Path $markerFile -Force
    exit 0
}

New-RunsOnDirectory -Path $markerDirectory
Set-Content -Path $markerFile -Value 'installed'

Install-AwsGridDriver
Install-CudaToolkit
Install-AwsGridDriver
