################################################################################
##  File:  Install-Rust.ps1
##  Desc:  Install Rust for Windows
##  Supply chain security: checksum validation for bootstrap, managed by rustup for workloads
################################################################################

# Rust Env
$env:RUSTUP_HOME = "C:\Users\Default\.rustup"
$env:CARGO_HOME = "C:\Users\Default\.cargo"

# Download the latest rustup-init.exe for Windows x64
# See https://rustup.rs/#
$rustupPath = Invoke-DownloadWithRetry "https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe"

#region Supply chain security
$distributorFileHash = (Invoke-RestMethod -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe.sha256').Trim()
Test-FileChecksum $rustupPath -ExpectedSHA256Sum $distributorFileHash
#endregion

# Install Rust by running rustup-init.exe (disabling the confirmation prompt with -y)
& $rustupPath -y --default-toolchain=stable --profile=minimal
if ($LASTEXITCODE -ne 0) {
    throw "Rust installation failed with exit code $LASTEXITCODE"
}

# Add %USERPROFILE%\.cargo\bin to USER PATH
Add-DefaultPathItem "%USERPROFILE%\.cargo\bin"
# Add Rust binaries to the path
$env:Path += ";$env:CARGO_HOME\bin"

# Add i686 target for building 32-bit binaries
rustup target add i686-pc-windows-msvc

# Add target for building mingw-w64 binaries
rustup target add x86_64-pc-windows-gnu

# Install common tools
rustup component add rustfmt clippy
if ($LASTEXITCODE -ne 0) {
    throw "Rust component installation failed with exit code $LASTEXITCODE"
}
if (-not (Test-IsWin25)) {
    cargo install --locked bindgen-cli cbindgen cargo-audit cargo-outdated
    if ($LASTEXITCODE -ne 0) {
        throw "Rust tools installation failed with exit code $LASTEXITCODE"
    }
    # Cleanup Cargo crates cache
    Remove-Item "${env:CARGO_HOME}\registry\*" -Recurse -Force
}

# removed: Invoke-PesterTests
# RunsOn patch: promote Rust install to machine-wide paths so cargo/rustc are available
# for all users (not only Default profile).
$globalRustRoot = 'C:\Rust'
$globalCargoHome = Join-Path $globalRustRoot '.cargo'
$globalRustupHome = Join-Path $globalRustRoot '.rustup'

New-Item -ItemType Directory -Path $globalRustRoot -Force | Out-Null

if (Test-Path -Path $env:CARGO_HOME) {
    robocopy $env:CARGO_HOME $globalCargoHome /E /NFL /NDL /NJH /NJS /NP | Out-Null
}

if (Test-Path -Path $env:RUSTUP_HOME) {
    robocopy $env:RUSTUP_HOME $globalRustupHome /E /NFL /NDL /NJH /NJS /NP | Out-Null
}

[Environment]::SetEnvironmentVariable('CARGO_HOME', $globalCargoHome, 'Machine')
[Environment]::SetEnvironmentVariable('RUSTUP_HOME', $globalRustupHome, 'Machine')
Add-MachinePathItem "$globalCargoHome\\bin"

# Keep this shell consistent for the rest of provisioning.
$env:CARGO_HOME = $globalCargoHome
$env:RUSTUP_HOME = $globalRustupHome
$env:Path += ";$globalCargoHome\\bin"

if (-not (Test-Path -Path "$globalCargoHome\\bin\\cargo.exe")) {
    throw "cargo.exe not found at $globalCargoHome\\bin"
}
if (-not (Test-Path -Path "$globalCargoHome\\bin\\rustc.exe")) {
    throw "rustc.exe not found at $globalCargoHome\\bin"
}

& "$globalCargoHome\\bin\\cargo.exe" --version | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "cargo validation failed with exit code $LASTEXITCODE"
}

& "$globalCargoHome\\bin\\rustc.exe" --version | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "rustc validation failed with exit code $LASTEXITCODE"
}
