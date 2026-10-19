# File keys are reused. Resolve reads within each key's lifetime, then keep
# the first read per path. Delete/rundown names also identify reads of files
# opened before tracing started.
function Get-BootTraceFiles {
    param([Parameter(Mandatory)][string]$Path)

    $order = 0
    $events = foreach ($line in [IO.File]::ReadLines($Path)) {
        $parts = $line.Split(',')
        if ($parts.Count -lt 21) { continue }
        $provider = $parts[0].Trim()
        $kind = $parts[1].Trim()
        if ($provider -eq 'FileIo' -and $kind -in @('FileCreate', 'FileDelete', 'FileRundown')) {
            [PSCustomObject]@{
                Time = [int64]$parts[16].Trim(); Order = $order++
                Kind = $kind; Key = $parts[19].Trim()
                Name = ($parts[20..($parts.Length - 1)] -join ',').Trim().Trim('"')
            }
        } elseif ($provider -eq 'DiskIo' -and $kind -eq 'Read' -and $parts.Count -ge 25) {
            [PSCustomObject]@{
                Time = [int64]$parts[16].Trim(); Order = $order++
                Kind = 'Read'; Key = $parts[24].Trim(); Name = $null
            }
        }
    }

    $names = @{}
    $pending = @{}
    $first = @{}
    foreach ($event in ($events | Sort-Object Time, Order)) {
        $key = $event.Key
        if ($event.Kind -eq 'FileCreate') {
            $names[$key] = $event.Name
            # Unresolved reads before this creation belong to a prior lifetime.
            $pending.Remove($key)
            continue
        }
        if ($event.Kind -eq 'Read') {
            if (-not $names.ContainsKey($key)) {
                if (-not $pending.ContainsKey($key)) { $pending[$key] = $event.Time }
                continue
            }
            $name = $names[$key]
            $time = $event.Time
        } else {
            $name = $event.Name
            $time = $pending[$key]
            $names.Remove($key)
            $pending.Remove($key)
            if ($null -eq $time) { continue }
        }
        if (-not $first.ContainsKey($name) -or $time -lt $first[$name]) {
            $first[$name] = $time
        }
    }
    $first.GetEnumerator() | Sort-Object Value, Name | ForEach-Object { $_.Key }
}

Export-ModuleMember -Function Get-BootTraceFiles
