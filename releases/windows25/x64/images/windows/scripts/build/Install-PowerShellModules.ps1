################################################################################
##  File:  Install-PowershellModules.ps1
##  Desc:  Install common PowerShell modules
################################################################################

# Set TLS1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor "Tls12"

# Install PowerShell modules
$modules = (Get-ToolsetContent).powershellModules

foreach ($module in $modules) {
    $moduleName = $module.name
    Write-Host "Installing ${moduleName} module"

    if ($module.versions) {
        foreach ($version in $module.versions) {
            Write-Host " - $version"
            Install-Module -AllowClobber -Name $moduleName -RequiredVersion $version -Scope AllUsers -SkipPublisherCheck -Force
        }
    } else {
        Install-Module -AllowClobber -Name $moduleName -Scope AllUsers -SkipPublisherCheck -Force
    }
}

Import-Module Pester
# removed: Invoke-PesterTests
