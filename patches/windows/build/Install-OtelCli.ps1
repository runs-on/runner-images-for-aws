################################################################################
##  File:  Install-OtelCli.ps1
##  Desc:  Install otel-cli, to wrap workflow commands in spans for the
##         runner's local OpenTelemetry collector
##  Supply chain security: otel-cli - pinned version and SHA-256
################################################################################

# SHA-256 of the pinned release asset, from the release's checksums.txt.
$otelCliVersion = "0.4.5"
$otelCliSha256 = "129d7e5dfc3f0bf23797c7309e79c2b5d9d5ecd31c1cefb31c41c820d4288810"

$targetDir = "C:\ProgramData\otel-cli"
New-Item -Path $targetDir -ItemType Directory -Force | Out-Null

$archivePath = Invoke-DownloadWithRetry `
    -Url "https://github.com/equinix-labs/otel-cli/releases/download/v$otelCliVersion/otel-cli_${otelCliVersion}_windows_amd64.zip"
Test-FileChecksum $archivePath -ExpectedSHA256Sum $otelCliSha256
# 7-Zip is not installed yet at this point of the build.
Expand-Archive -Path $archivePath -DestinationPath $targetDir -Force
Add-MachinePathItem $targetDir

# With no OTLP endpoint, otel-cli only runs the command.
& "$targetDir\otel-cli.exe" exec -- cmd /c exit 0
if ($LASTEXITCODE -ne 0) {
    throw "otel-cli validation failed with exit code $LASTEXITCODE"
}
