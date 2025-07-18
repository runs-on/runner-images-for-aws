################################################################################
##  File:  Install-Apache.ps1
##  Desc:  Install Apache HTTP Server
################################################################################

# Stop w3svc service
Stop-Service -Name w3svc

# Install latest apache in chocolatey
$installDir = "C:\tools"
Install-ChocoPackage apache-httpd -ArgumentList "--force", "--params", "/installLocation:$installDir /port:80"

# Stop and disable Apache service
Stop-Service -Name Apache
Set-Service -Name Apache -StartupType Disabled

# Start w3svc service
Start-Service -Name w3svc

# Invoke Pester Tests
# removed: Invoke-PesterTests
