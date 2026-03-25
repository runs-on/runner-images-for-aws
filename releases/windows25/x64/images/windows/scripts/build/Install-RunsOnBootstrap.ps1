################################################################################
##  File:  Install-RunsOnBootstrap.ps1
##  Desc:  Preinstall RunsOn bootstrap binaries for runtime reuse
################################################################################

$bootstrapVersions = @(
    "v0.1.12",
    "v0.1.9"
)

$bootstrapDir = "C:\runs-on"
New-Item -Path $bootstrapDir -ItemType Directory -Force | Out-Null

foreach ($bootstrapVersion in $bootstrapVersions) {
    $bootstrapPath = Join-Path $bootstrapDir "bootstrap-$bootstrapVersion.exe"
    $bootstrapUrl = "https://github.com/runs-on/bootstrap/releases/download/$bootstrapVersion/bootstrap-$bootstrapVersion-windows-AMD64.exe"

    Write-Host "Preinstalling RunsOn bootstrap $bootstrapVersion"
    Invoke-DownloadWithRetry -Url $bootstrapUrl -Path $bootstrapPath | Out-Null

    & $bootstrapPath -h | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "RunsOn bootstrap validation failed for $bootstrapVersion with exit code $LASTEXITCODE"
    }
}
