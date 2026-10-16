################################################################################
##  File:  Install-Runner.ps1
##  Desc:  Install Runner for GitHub Actions
##  Supply chain security: checksum validation
################################################################################

# github.com/runs-on/runner publishes RunsOn's build of each actions/runner
# release as v<version>-runs-on.<revision>, with upstream's file names. Take
# the newest revision for upstream's latest version, and fail the build until
# the fork publishes that version. Upstream's release helpers skip tags with a
# suffix like this, so resolve the tag here.
Write-Host "Download the RunsOn build of the latest Runner for GitHub Actions"
$latest = Invoke-ScriptBlockWithRetry -Command {
    Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest"
}
$version = $latest.tag_name -replace '^v', ''
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Unexpected actions/runner version: $version"
}

$prefix = "v$version-runs-on."
$releases = Invoke-ScriptBlockWithRetry -Command {
    Invoke-RestMethod -Uri "https://api.github.com/repos/runs-on/runner/releases?per_page=100"
}
$tag = $releases.tag_name |
    Where-Object { $_.StartsWith($prefix) } |
    Sort-Object { [int] $_.Substring($prefix.Length) } |
    Select-Object -Last 1
if (-not $tag) {
    throw "runs-on/runner has not published actions/runner v$version yet"
}

$fileName = "actions-runner-win-x64-$version.zip"
$releaseUrl = "https://github.com/runs-on/runner/releases/download/$tag"
Write-Host "Installing $fileName from runs-on/runner $tag"
New-Item -Path "C:\ProgramData\runner" -ItemType Directory
Invoke-DownloadWithRetry -Url "$releaseUrl/$fileName" -Path "C:\ProgramData\runner\$fileName"
$checksum = Get-ChecksumFromUrl -Url "$releaseUrl/SHA256SUMS" -FileName $fileName -HashType "SHA256"
Test-FileChecksum -Path "C:\ProgramData\runner\$fileName" -ExpectedSHA256Sum $checksum

# removed: Invoke-PesterTests
# Patched into Install-Runner.ps1

# Create runner user
$User = "runner"
New-LocalUser -Name $User -NoPassword
Add-LocalGroupMember -Group "Administrators" -Member $User

# Extract runner binary
$runnerZipFile = "C:\ProgramData\runner\$fileName"
$destination = "C:\actions-runner"

New-Item -Path $destination -ItemType Directory -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($runnerZipFile, $destination)

# Remove runner binary after extraction
Remove-Item $runnerZipFile -Force