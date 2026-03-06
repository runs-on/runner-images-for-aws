################################################################################
##  File: Install-NativeImages.ps1
##  Desc: Generate and install native images for .NET assemblies
##  Note: NGen update may intermittently return non-zero on Windows 2025 after
##        heavy image slimming. This is an optimization step, so we retry and
##        continue if updates still fail.
################################################################################

$ngen64 = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\ngen.exe"
$ngen32 = "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\ngen.exe"

function Invoke-NgenUpdate {
    param (
        [string]$NgenPath,
        [string]$Architecture
    )

    Write-Host "NGen: update $Architecture native images..."
    & $NgenPath update | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        return
    }

    Write-Warning "NGen update for $Architecture failed with exit code $exitCode. Retrying after executeQueuedItems."
    & $NgenPath executeQueuedItems | Out-Null
    & $NgenPath update | Out-Null
    $retryExitCode = $LASTEXITCODE
    if ($retryExitCode -eq 0) {
        Write-Host "NGen: update $Architecture native images succeeded on retry."
        return
    }

    Write-Warning "NGen update for $Architecture failed again with exit code $retryExitCode. Continuing build."
}

Write-Host "NGen: install Microsoft.PowerShell.Utility.Activities..."
& $ngen64 install "Microsoft.PowerShell.Utility.Activities, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Installation of Microsoft.PowerShell.Utility.Activities failed with exit code $LASTEXITCODE"
}

Invoke-NgenUpdate -NgenPath $ngen64 -Architecture "x64"
Invoke-NgenUpdate -NgenPath $ngen32 -Architecture "x86"
