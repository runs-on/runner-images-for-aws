################################################################################
##  File:  Start-BootTrace.ps1
##  Desc:  Arm a Windows Performance Recorder boot trace (file and disk I/O)
##         so the next restart records which files the boot reads.
##         Optimize-BootLayout.ps1 consumes it after the restart.
################################################################################

# wpr writes its status to stderr; under $ErrorActionPreference = "Stop" that
# would end the script, so native calls go through cmd.exe and the exit code.
$ErrorActionPreference = "Stop"

& cmd.exe /c "wpr.exe -cancelboot >nul 2>&1"
& cmd.exe /c "wpr.exe -addboot FileIO -addboot DiskIO -filemode 2>&1"
if ($LASTEXITCODE -ne 0) {
    throw "wpr -addboot failed with exit code $LASTEXITCODE"
}
Write-Host "Boot trace armed for the next restart"
