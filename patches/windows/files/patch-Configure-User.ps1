# Patched into Configure-User.ps1

# Check if CloudWatch agent is already installed
if (-not (Test-Path "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1")) {
    Write-Host "Installing CloudWatch agent..."
    
    # Get the AWS region from environment variable
    $region = $env:AWS_DEFAULT_REGION
    if (-not $region) {
        Write-Warning "AWS_DEFAULT_REGION not set, using us-east-1 as default"
        $region = "us-east-1"
    }
    
    # Download and install CloudWatch agent
    $cloudwatchUrl = "https://amazoncloudwatch-agent.s3.amazonaws.com/windows/amd64/latest/amazon-cloudwatch-agent.msi"
    
    try {
        $output = & msiexec.exe /i $cloudwatchUrl | Write-Verbose
        Write-Host "CloudWatch agent installation completed successfully"
    }
    catch {
        Write-Warning "Failed to install CloudWatch agent: $($_.Exception.Message)"
    }
}

# Cleanup

Write-Host "Cleaning up Package Cache..."
$packageCachePath = "$env:ProgramData\Package Cache"
if (Test-Path $packageCachePath) {
    Write-Host "Removing $packageCachePath"
    cmd /c "takeown /d Y /R /f `"$packageCachePath`" 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to take ownership of $packageCachePath"
    }
    cmd /c "icacls `"$packageCachePath`" /grant:r administrators:f /t /c /q 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to grant administrators full control of $packageCachePath"
    }
    Remove-Item $packageCachePath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "Starting Component Store (WinSxS) cleanup..."
# This command cleans up superseded components. It's safe and effective.
Dism.exe /Online /Cleanup-Image /StartComponentCleanup

# For maximum space saving on a final image, you can use /ResetBase.
# This makes all existing updates permanent and not uninstallable.
# This is generally what you want for a "golden" runner image.
Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase

Write-Host "Component Store cleanup completed."

#
# Cleans up the .NET Framework Native Image Cache (Ngen) to reduce image size.
# This script dynamically detects all installed .NET Framework versions.
#
Write-Host "--- Starting .NET Framework Native Image Cache (Ngen) cleanup ---"

# Base paths for 32-bit and 64-bit .NET Framework installations
$frameworkBasePaths = @(
    "C:\Windows\Microsoft.NET\Framework64",
    "C:\Windows\Microsoft.NET\Framework"
)

# Dynamically find all ngen.exe paths
$ngenPaths = @()
foreach ($basePath in $frameworkBasePaths) {
    if (Test-Path $basePath) {
        Get-ChildItem -Path $basePath -Directory -Filter "v*" | ForEach-Object {
            $ngenExePath = Join-Path -Path $_.FullName -ChildPath "ngen.exe"
            if (Test-Path $ngenExePath) {
                $ngenPaths += $ngenExePath
            }
        }
    }
}

if ($ngenPaths.Count -eq 0) {
    Write-Host "No ngen.exe instances found. Nothing to do."
} else {
    Write-Host "Found the following ngen.exe instances to process:"
    $ngenPaths | ForEach-Object { Write-Host "- $_" }

    # Uninstall all existing native images to save space.
    Write-Host "Uninstalling all native images..."
    foreach ($ngen in $ngenPaths) {
        Write-Host "Executing uninstall for: $ngen"
        & $ngen uninstall *
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "ngen.exe uninstall failed for $ngen with exit code $LASTEXITCODE"
        }
    }

    # Execute any queued items to clear out pending compilation tasks.
    Write-Host "Executing queued items..."
    foreach ($ngen in $ngenPaths) {
        Write-Host "Executing queued items for: $ngen"
        & $ngen executeQueuedItems
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "ngen.exe executeQueuedItems failed for $ngen with exit code $LASTEXITCODE"
        }
    }
}

Write-Host "--- .NET Framework cleanup complete ---"

# Remove the installer user to save space
if ($env:INSTALL_USER) {
    $userProfilePath = "C:\Users\$($env:INSTALL_USER)"
    Write-Host "Removing installer user: $env:INSTALL_USER"
    try {
        net user $env:INSTALL_USER /delete
        Write-Host "Successfully removed user account $env:INSTALL_USER."

        if (Test-Path $userProfilePath) {
            Write-Host "Removing user profile directory: $userProfilePath"
            Remove-Item -Path $userProfilePath -Recurse -Force
            Write-Host "Successfully removed user profile directory."
        }
    } catch {
        Write-Warning "Failed to remove user $env:INSTALL_USER. Error: $_"
    }
}

if (Get-WindowsFeature -Name Windows-Defender) {
    Uninstall-WindowsFeature -Name Windows-Defender -Remove
} 