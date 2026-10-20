$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../patches/windows/files/BootTrace.psm1') -Force

function New-Event {
    param([string]$Kind, [long]$Time, [string]$Key, [string]$Name = '')
    $parts = [string[]]::new(25)
    $parts[0] = if ($Kind -eq 'Read') { '      DiskIo' } else { '      FileIo' }
    $parts[1] = $Kind.PadLeft(11)
    $parts[16] = [string]$Time
    if ($Kind -eq 'Read') { $parts[24] = $Key } else {
        $parts = $parts[0..20]
        $parts[19] = $Key
        $parts[20] = '"' + $Name + '"'
    }
    $parts -join ','
}

$cases = @(
    @{
        Name = 'Reused key keeps both files and their read order'
        Events = @(
            (New-Event FileCreate 10 1 'A.dll'), (New-Event Read 20 1),
            (New-Event FileDelete 30 1 'A.dll'), (New-Event FileCreate 40 1 'B.dll'),
            (New-Event Read 50 1), (New-Event FileRundown 60 1 'B.dll')
        )
        Expected = @('A.dll', 'B.dll')
    },
    @{
        Name = 'Creation separates lifetimes even without a delete event'
        Events = @(
            (New-Event FileCreate 10 1 'A.dll'), (New-Event Read 20 1),
            (New-Event FileCreate 30 1 'B.dll'), (New-Event Read 40 1)
        )
        Expected = @('A.dll', 'B.dll')
    },
    @{
        Name = 'Delete and rundown resolve files open before the trace'
        Events = @(
            (New-Event Read 10 1), (New-Event FileDelete 20 1 'A.dll'),
            (New-Event Read 30 1), (New-Event FileRundown 40 1 'B.dll')
        )
        Expected = @('A.dll', 'B.dll')
    },
    @{
        Name = 'An unresolved prior lifetime is not attributed to a new file'
        Events = @(
            (New-Event Read 10 1), (New-Event FileCreate 20 1 'B.dll'),
            (New-Event FileCreate 30 2 'C.dll'), (New-Event Read 40 2), (New-Event Read 50 1)
        )
        Expected = @('C.dll', 'B.dll')
    },
    @{
        Name = 'Timestamps determine order and repeated paths are emitted once'
        Events = @(
            (New-Event Read 60 2), (New-Event FileCreate 40 2 'A.dll'),
            (New-Event FileCreate 10 1 'A.dll'), (New-Event Read 20 1),
            (New-Event FileCreate 30 3 'B,comma.dll'), (New-Event Read 50 3)
        )
        Expected = @('A.dll', 'B,comma.dll')
    }
)
$csv = [IO.Path]::GetTempFileName()
try {
    foreach ($case in $cases) {
        [IO.File]::WriteAllLines($csv, [string[]]$case.Events)
        $actual = @(Get-BootTraceFiles -Path $csv)
        if (($actual -join '|') -cne ($case.Expected -join '|')) {
            throw "$($case.Name): expected $($case.Expected -join ', '), got $($actual -join ', ')"
        }
        Write-Host "PASS: $($case.Name)"
    }
} finally { Remove-Item $csv -Force }
