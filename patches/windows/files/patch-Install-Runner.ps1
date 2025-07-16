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