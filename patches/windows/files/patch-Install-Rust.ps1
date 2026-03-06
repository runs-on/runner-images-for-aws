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
