################################################################################
##  File:  Install-RunsOnBootstrap.ps1
##  Desc:  Preinstall RunsOn bootstrap binaries for runtime reuse
################################################################################

# SHA-256 of each pinned release asset, from the release's checksums.txt. v0.1.9
# publishes only per-asset .md5 files; its hash matches that.
$bootstrapVersions = [ordered]@{
    "v0.1.17" = "bfcf7ee37fcc66c843d6abb8b48bc87b32f8065ab3c6fa23edfc79d00e83c0ee"
    "v0.1.12" = "16b9c4c582d761ebc47a3f7f8e04d4300440e00beb80d100b859b4a7782dd118"
    "v0.1.9"  = "40c6f93ec879e910a84807cf9ee812093cffcf1b05f46d3cddfb4722d14a556b"
}

$bootstrapDir = "C:\runs-on"
New-Item -Path $bootstrapDir -ItemType Directory -Force | Out-Null

foreach ($bootstrapVersion in $bootstrapVersions.Keys) {
    $bootstrapPath = Join-Path $bootstrapDir "bootstrap-$bootstrapVersion.exe"
    $bootstrapUrl = "https://github.com/runs-on/bootstrap/releases/download/$bootstrapVersion/bootstrap-$bootstrapVersion-windows-AMD64.exe"

    Write-Host "Preinstalling RunsOn bootstrap $bootstrapVersion"
    Invoke-DownloadWithRetry -Url $bootstrapUrl -Path $bootstrapPath | Out-Null
    Test-FileChecksum $bootstrapPath -ExpectedSHA256Sum $bootstrapVersions[$bootstrapVersion]

    & $bootstrapPath -h | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "RunsOn bootstrap validation failed for $bootstrapVersion with exit code $LASTEXITCODE"
    }
}
