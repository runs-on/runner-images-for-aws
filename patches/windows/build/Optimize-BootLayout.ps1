################################################################################
##  File:  Optimize-BootLayout.ps1
##  Desc:  Stop the boot trace armed by Start-BootTrace.ps1, list the files the
##         boot read in first-access order, and move them into contiguous
##         regions of the volume with bootpack.exe.
##
##         A fresh EBS volume fetches snapshot data on first access and serves
##         few of those fetches at once, so a cold Windows boot is bound by how
##         scattered its reads are: about 28,000 reads over the whole 100 GiB
##         volume when the boot files sit where the installers left them.
##         Packing the set in read order made cold boots about 10 s faster in
##         same-window A/B launches.
################################################################################

$ErrorActionPreference = "Stop"

$workDir = "C:\ProgramData\RunsOn"
$etl = Join-Path $workDir "boottrace.etl"
$csv = Join-Path $workDir "boottrace.csv"
$list = Join-Path $workDir "bootlayout.txt"
# Copied out of the image folder right after upload; cleanup removes that folder.
$bootpack = Join-Path $workDir "bootpack.exe"
if (-not (Test-Path $bootpack)) {
    throw "bootpack.exe is missing at $bootpack"
}
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

# wpr and tracerpt write progress to stderr, which would end the script under
# $ErrorActionPreference = "Stop"; run them through cmd.exe and use exit codes.
& cmd.exe /c "wpr.exe -stopboot `"$etl`" boot 2>&1"
if ($LASTEXITCODE -ne 0) {
    throw "wpr -stopboot failed with exit code $LASTEXITCODE"
}
Write-Host "Boot trace saved: $([math]::Round((Get-Item $etl).Length / 1MB)) MB"
& cmd.exe /c "tracerpt.exe `"$etl`" -o `"$csv`" -of CSV -y >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
    throw "tracerpt failed with exit code $LASTEXITCODE"
}
Remove-Item $etl -Force

# DiskIo/Read events carry the file object; FileIo/FileCreate and FileRundown
# events map file objects to names. Keep the files in first-read order.
$names = @{}
$first = @{}
$t0 = 0
foreach ($line in [IO.File]::ReadLines($csv)) {
    if ($line.StartsWith("      FileIo, FileCreate") -or $line.StartsWith("      FileIo, FileRundown")) {
        $parts = $line.Split(',')
        $names[$parts[19].Trim()] = ($parts[20..($parts.Length - 1)] -join ',').Trim().Trim('"')
        continue
    }
    if ($line.StartsWith("      DiskIo,       Read,")) {
        $parts = $line.Split(',')
        $ts = [int64]$parts[16].Trim()
        if ($t0 -eq 0) { $t0 = $ts }
        $fo = $parts[24].Trim()
        if (-not $first.ContainsKey($fo)) { $first[$fo] = $ts - $t0 }
    }
}
Remove-Item $csv -Force

$files = $first.GetEnumerator() | Sort-Object Value | ForEach-Object {
    if (-not $names.ContainsKey($_.Key)) { return }
    $name = $names[$_.Key] -replace '^\\Device\\HarddiskVolume\d+', 'C:'
    $name -replace ':WofCompressedData$', ''
} | Where-Object {
    $_ -notmatch '\\\$|:\$|\\pagefile\.sys$|\\config\\(SYSTEM|SOFTWARE|DEFAULT|SAM|SECURITY|DRIVERS|BBI|COMPONENTS)$|\.evtx$|\.etl$|\.log$|\\Temp\\' -and (Test-Path -LiteralPath $_ -PathType Leaf)
} | Select-Object -Unique
[IO.File]::WriteAllLines($list, [string[]]$files)
Write-Host "Boot file set: $($files.Count) files"

# Hives first: the kernel reads SOFTWARE in full before the first service.
$hives = "C:\Windows\System32\config\SOFTWARE,C:\Windows\System32\config\SYSTEM,C:\Windows\System32\config\DRIVERS"
& cmd.exe /c "`"$bootpack`" -list `"$list`" -extra `"$hives`" 2>&1"
if ($LASTEXITCODE -ne 0) {
    throw "bootpack failed with exit code $LASTEXITCODE"
}
Remove-Item $bootpack -Force
