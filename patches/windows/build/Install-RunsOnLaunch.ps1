################################################################################
##  File:  Install-RunsOnLaunch.ps1
##  Desc:  Install the early RunsOn Windows launch service
################################################################################

$serviceName = "RunsOnLaunch"
$installDirectory = "C:\runs-on"
$sourcePath = "C:\Windows\Temp\runs-on-launch.exe"
$servicePath = Join-Path $installDirectory "runs-on-launch.exe"

if (-not (Test-Path $sourcePath)) {
    throw "RunsOnLaunch binary not found at $sourcePath"
}

New-Item -Path $installDirectory -ItemType Directory -Force | Out-Null
Copy-Item -Path $sourcePath -Destination $servicePath -Force
Remove-Item -Path $sourcePath -Force

$existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not replace $serviceName"
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((Get-Service -Name $serviceName -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        throw "$serviceName remained marked for deletion"
    }
}

& sc.exe create $serviceName binPath= "`"$servicePath`"" start= demand obj= LocalSystem DisplayName= "RunsOn early launch"
if ($LASTEXITCODE -ne 0) {
    throw "Could not create $serviceName"
}

& sc.exe description $serviceName "Starts the RunsOn bootstrap before Amazon SSM Agent."
& sc.exe failure $serviceName reset= 86400 actions= restart/1000/restart/5000/restart/30000
& sc.exe failureflag $serviceName 1
& sc.exe config AmazonSSMAgent start= demand

$service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
if (-not $service -or $service.StartMode -ne "Manual" -or $service.StartName -ne "LocalSystem") {
    throw "$serviceName service configuration is invalid"
}

Write-Host "$serviceName installed at $servicePath"
