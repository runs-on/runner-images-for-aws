################################################################################
##  File:  Install-Bazel.ps1
##  Desc:  Install Bazel and Bazelisk (A user-friendly launcher for Bazel)
################################################################################

Install-ChocoPackage bazel

npm install -g @bazel/bazelisk
if ($LASTEXITCODE -ne 0) {
    throw "Command 'npm install -g @bazel/bazelisk' failed"
}

# removed: Invoke-PesterTests
