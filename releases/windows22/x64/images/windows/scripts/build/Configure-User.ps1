################################################################################
##  File:  Configure-User.ps1
##  Desc:  Performs user part of warm up and moves data to C:\Users\Default
################################################################################

#
# more: https://github.com/actions/runner-images-internal/issues/5320
#       https://github.com/actions/runner-images/issues/5301#issuecomment-1648292990
#

Write-Host "Warmup 'devenv.exe /updateconfiguration'"
$vsInstallRoot = (Get-VisualStudioInstance).InstallationPath
cmd.exe /c "`"$vsInstallRoot\Common7\IDE\devenv.exe`" /updateconfiguration"
if ($LASTEXITCODE -ne 0) {
    # removed: throw "Failed to warmup 'devenv.exe /updateconfiguration'"
}

# we are fine if some file is locked and cannot be copied
Copy-Item ${env:USERPROFILE}\AppData\Local\Microsoft\VisualStudio -Destination c:\users\default\AppData\Local\Microsoft\VisualStudio -Recurse -ErrorAction SilentlyContinue

Mount-RegistryHive `
    -FileName "C:\Users\Default\NTUSER.DAT" `
    -SubKey "HKLM\DEFAULT"

reg.exe copy HKCU\Software\Microsoft\VisualStudio HKLM\DEFAULT\Software\Microsoft\VisualStudio /s
if ($LASTEXITCODE -ne 0) {
    # removed: throw "Failed to copy HKCU\Software\Microsoft\VisualStudio to HKLM\DEFAULT\Software\Microsoft\VisualStudio"
}

# TortoiseSVN not installed on Windows 2025 image due to Sysprep issues
if (-not (Test-IsWin25)) {
    # disable TSVNCache.exe
    $registryKeyPath = 'HKCU:\Software\TortoiseSVN'
    if (-not(Test-Path -Path $registryKeyPath)) {
        New-Item -Path $registryKeyPath -ItemType Directory -Force
    }

    New-ItemProperty -Path $registryKeyPath -Name CacheType -PropertyType DWORD -Value 0
    reg.exe copy HKCU\Software\TortoiseSVN HKLM\DEFAULT\Software\TortoiseSVN /s
    if ($LASTEXITCODE -ne 0) {
        # removed: throw "Failed to copy HKCU\Software\TortoiseSVN to HKLM\DEFAULT\Software\TortoiseSVN"
    }
}
# Accept by default "Send Diagnostic data to Microsoft" consent.
if (Test-IsWin25) {
    $registryKeyPath = 'HKLM:\DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy'
    New-ItemProperty -Path $registryKeyPath -Name PrivacyConsentPresentationVersion -PropertyType DWORD -Value 3 | Out-Null
    New-ItemProperty -Path $registryKeyPath -Name PrivacyConsentSettingsValidMask -PropertyType DWORD -Value 4 | Out-Null
    New-ItemProperty -Path $registryKeyPath -Name PrivacyConsentSettingsVersion -PropertyType DWORD -Value 5 | Out-Null
}

Dismount-RegistryHive "HKLM\DEFAULT"

# Remove the "installer" (var.install_user) user profile for Windows 2025 image
if (Test-IsWin25) {
    Get-CimInstance -ClassName Win32_UserProfile | where-object {$_.LocalPath -match $env:INSTALL_USER} | Remove-CimInstance -Confirm:$false
    & net user $env:INSTALL_USER /DELETE
}

Write-Host "Configure-User.ps1 - completed"
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