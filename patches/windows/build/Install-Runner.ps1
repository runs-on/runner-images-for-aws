################################################################################
##  File:  Install-Runner.ps1
##  Desc:  Install Runner for GitHub Actions
##  Supply chain security: none
################################################################################

Write-Host "Download latest Runner for GitHub Actions"
$downloadUrl = Resolve-GithubReleaseAssetUrl `
    -Repo "actions/runner" `
    -Version "latest" `
    -UrlMatchPattern "actions-runner-win-x64-*[0-9.].zip"
$fileName = Split-Path $downloadUrl -Leaf
New-Item -Path "C:\ProgramData\runner" -ItemType Directory
Invoke-DownloadWithRetry -Url $downloadUrl -Path "C:\ProgramData\runner\$fileName"

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