################################################################################
##  File:  Install-Sbt.ps1
##  Desc:  Install sbt for Windows
################################################################################

# Install the latest version of sbt.
# See https://chocolatey.org/packages/sbt
Install-ChocoPackage sbt

$env:SBT_HOME="${env:ProgramFiles(x86)}\sbt"

# Add sbt binaries to the path
Add-MachinePathItem "$env:SBT_HOME\bin"

# removed: Invoke-PesterTests
