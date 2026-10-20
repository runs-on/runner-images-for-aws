# Patched into Configure-User.ps1

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
# Native images for Windows PowerShell. A fresh runner pays about 25 s on a
# 2 vCPU instance for the first powershell.exe when they are missing, because
# every assembly is JIT-compiled from a cold EBS volume. The upstream image
# used to uninstall all native images to save space; keep them, and make sure
# the assemblies a typical PowerShell session loads have one.
#
Write-Host "--- Generating native images for Windows PowerShell ---"
$ngen64 = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\ngen.exe"
$assemblies = & powershell.exe -NoProfile -NonInteractive -Command {
    Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility, Microsoft.PowerShell.Security, CimCmdlets -ErrorAction SilentlyContinue
    Get-Date | Out-Null
    Get-CimInstance Win32_OperatingSystem | Out-Null
    try { Invoke-WebRequest -Uri http://127.0.0.1:1/ -UseBasicParsing -TimeoutSec 1 | Out-Null } catch { }
    [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.Location -and -not $_.IsDynamic } | ForEach-Object { $_.Location } | Sort-Object -Unique
}
$installed = 0
foreach ($assembly in $assemblies) {
    & $ngen64 install $assembly /nologo /silent 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $installed++ }
}
& $ngen64 executeQueuedItems /nologo /silent 2>&1 | Out-Null
Write-Host "Native images installed for $installed of $($assemblies.Count) PowerShell assemblies."

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
    try {
        $result = Uninstall-WindowsFeature -Name Windows-Defender -Remove
        if ($result.Success) {
            Write-Host "Successfully uninstalled Windows Defender."
            if ($result.RestartNeeded -eq 'Yes') {
                Write-Host "A restart is required to complete the removal."
                exit 0
            }
        } else {
            Write-Warning "Failed to uninstall Windows Defender."
        }
    } catch {
        Write-Warning "Failed to uninstall Windows Defender. Error: $_"
    }
} else {
    Write-Host "Windows Defender is not installed. Nothing to do."
    exit 0
}
