param(
    [ValidateSet("Enabled", "Disabled")]
    [string]$NestedVirtualization = "Disabled",
    [switch]$RunWindowsContainer
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$imageFolder = "C:\image"
$testsFolder = Join-Path $imageFolder "tests"
$helpersModule = "C:\Program Files\WindowsPowerShell\Modules\TestsHelpers\TestsHelpers.psm1"
$env:IMAGE_FOLDER = $imageFolder
$env:TEMP = "C:\Windows\Temp"
$env:TMP = $env:TEMP
$env:TEMP_DIR = $env:TEMP

if (-not (Test-Path $testsFolder)) {
    throw "Image tests folder is missing: $testsFolder"
}

Import-Module Pester -MinimumVersion 5.0
Import-Module $helpersModule -Force
Update-Environment

$suites = @(
    @{ File = "Docker"; Filter = @("*docker is installed", "*docker service is up", "*docker compose", "*docker-wincred") },
    @{ File = "VisualStudio" },
    @{ File = "Wix" },
    @{ File = "Vsix" },
    @{ File = "PowerShellModules" },
    @{ File = "CLI.Tools"; Filter = @("*Azure CLI*", "*AWS*", "*GitHub CLI*") },
    @{ File = "ChocoPackages"; Filter = @("*7-Zip*", "*Aria2*", "*AzCopy*", "*Bicep*", "*InnoSetup*", "*Jq*", "*Nuget*", "*Packer*", "*Swig*", "*VSWhere*", "*CMake*", "*ImageMagick*", "*Ninja*") },
    @{ File = "Node" },
    @{ File = "DotnetSDK" },
    @{ File = "Rust"; Filter = @("*folders exist", "*is installed to the*") },
    @{ File = "Shell" },
    @{ File = "WinAppDriver" },
    @{ File = "ActionArchiveCache" },
    @{ File = "Databases"; Filter = "*PostgreSQL*" },
    @{ File = "Tools"; Filter = @("*PowerShell Core*", "*Sbt*", "*Vcpkg*", "*WebPlatformInstaller*", "*Zstd*") }
)

$results = foreach ($suite in $suites) {
    $path = Join-Path $testsFolder "$($suite.File).Tests.ps1"
    if (-not (Test-Path $path)) {
        throw "Test file is missing: $path"
    }

    $configuration = [PesterConfiguration]@{
        Run = @{ Path = $path; PassThru = $true }
        Output = @{ Verbosity = "None" }
    }
    if ($suite.Filter) {
        $configuration.Filter.FullName = $suite.Filter
    }

    $result = Invoke-Pester -Configuration $configuration
    [pscustomobject]@{
        Check = "Pester:$($suite.File)"
        Passed = $result.PassedCount
        Failed = $result.FailedCount
        Skipped = $result.SkippedCount
        Success = $result.FailedCount -eq 0 -and $result.PassedCount -gt 0
    }
}

$fileChecks = @(
    "C:\actions-runner\bin\Runner.Listener.exe",
    "C:\actions-runner\bin\Runner.Worker.exe",
    "C:\runs-on\bootstrap-v0.1.12.exe",
    "C:\runs-on\bootstrap-v0.1.9.exe",
    "C:\runs-on\bootstrap-v0.1.17.exe",
    "C:\runs-on\runs-on-launch.exe",
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files\Git\bin\bash.exe",
    "C:\ProgramData\Amazon\EC2Launch\config\agent-config.yml"
)

$results += foreach ($path in $fileChecks) {
    [pscustomobject]@{
        Check = "File:$path"
        Passed = [int](Test-Path $path)
        Failed = [int](-not (Test-Path $path))
        Skipped = 0
        Success = Test-Path $path
    }
}

$toolcacheChecks = @(
    @{ Name = "Python 3.14"; Path = "C:\hostedtoolcache\windows\Python\3.14.*\x64\python.exe"; Arguments = @("--version") },
    @{ Name = "Node 22"; Path = "C:\hostedtoolcache\windows\node\22.*\x64\node.exe"; Arguments = @("--version") },
    @{ Name = "Node 24"; Path = "C:\hostedtoolcache\windows\node\24.*\x64\node.exe"; Arguments = @("--version") },
    @{ Name = "Go 1.26"; Path = "C:\hostedtoolcache\windows\go\1.26.*\x64\bin\go.exe"; Arguments = @("version") }
)
$results += foreach ($check in $toolcacheChecks) {
    $executable = Get-Item -Path $check.Path -ErrorAction SilentlyContinue | Select-Object -First 1
    $success = $false
    if ($executable) {
        & $executable.FullName @($check.Arguments) | Out-Null
        $success = $LASTEXITCODE -eq 0
    }
    [pscustomobject]@{
        Check = "Toolcache:$($check.Name)"
        Passed = [int]$success
        Failed = [int](-not $success)
        Skipped = 0
        Success = $success
    }
}

$agentConfig = Get-Content "C:\ProgramData\Amazon\EC2Launch\config\agent-config.yml" -Raw
$hasRedundantRootExtension = $agentConfig -match "extendRootPartition"
$results += [pscustomobject]@{
    Check = "EC2Launch:extendRootPartition omitted"
    Passed = [int](-not $hasRedundantRootExtension)
    Failed = [int]$hasRedundantRootExtension
    Skipped = 0
    Success = -not $hasRedundantRootExtension
}

$requiredFeatures = @(
    "Containers",
    "Hyper-V",
    "NET-Framework-Features",
    "NET-Framework-45-Features"
)
$results += foreach ($featureName in $requiredFeatures) {
    $feature = Get-WindowsFeature -Name $featureName
    $installed = $feature.InstallState -eq "Installed"
    [pscustomobject]@{
        Check = "Feature:$featureName"
        Passed = [int]$installed
        Failed = [int](-not $installed)
        Skipped = 0
        Success = $installed
    }
}

$requiredOptionalFeatures = @(
    "Microsoft-Windows-Subsystem-Linux",
    "VirtualMachinePlatform"
)
$results += foreach ($featureName in $requiredOptionalFeatures) {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName
    $enabled = $feature.State -eq "Enabled"
    [pscustomobject]@{
        Check = "OptionalFeature:$featureName"
        Passed = [int]$enabled
        Failed = [int](-not $enabled)
        Skipped = 0
        Success = $enabled
    }
}

$operationalChecks = @(
    @{ Name = "EC2Launch configuration validates"; Run = {
        & "C:\Program Files\Amazon\EC2Launch\EC2Launch.exe" validate | Out-Null
        $LASTEXITCODE -eq 0
    } },
    @{ Name = "Windows is activated"; Run = {
        $windowsApplicationId = "55c92734-d682-4d71-983e-d6ec3f16059f"
        $null -ne (Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$windowsApplicationId' AND LicenseStatus=1" | Select-Object -First 1)
    } },
    @{ Name = "Administrator password was generated"; Run = {
        $administrator = Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
        $administrator.Enabled -and $administrator.PasswordRequired -and $null -ne $administrator.PasswordLastSet
    } },
    @{ Name = "DNS resolution works without EC2Launch suffix task"; Run = {
        $null -ne (Resolve-DnsName "amazon.com" -Type A -ErrorAction Stop | Select-Object -First 1)
    } },
    @{ Name = "IMDSv2 metadata works"; Run = {
        $token = Invoke-RestMethod -Method Put -Uri "http://169.254.169.254/latest/api/token" -Headers @{ "X-aws-ec2-metadata-token-ttl-seconds" = "60" }
        $instanceId = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/instance-id" -Headers @{ "X-aws-ec2-metadata-token" = $token }
        $instanceId -match '^i-[0-9a-f]+$'
    } },
    @{ Name = "RunsOnLaunch starts bootstrap before SSM"; Run = {
        $state = Get-Content "C:\ProgramData\RunsOn\Launch\timings.json" -Raw | ConvertFrom-Json
        $bootstrap = $state.Milestones | Where-Object Name -eq "runs-on-launch.bootstrap-started" | Select-Object -First 1
        $ssm = $state.Milestones | Where-Object Name -eq "runs-on-launch.ssm-started" | Select-Object -First 1
        $bootstrap -and $ssm -and ([DateTime]$bootstrap.Time) -lt ([DateTime]$ssm.Time)
    } },
    @{ Name = "Hyper-V and container services remain available"; Run = {
        @("HvHost", "hns", "vmcompute", "vmms", "wcnfs", "LanmanServer", "LanmanWorkstation") |
            ForEach-Object { (Get-CimInstance Win32_Service -Filter "Name='$_'").StartMode -ne "Disabled" } |
            Where-Object { -not $_ } | Measure-Object | Select-Object -ExpandProperty Count | ForEach-Object { $_ -eq 0 }
    } },
    @{ Name = "SMB client and server APIs work"; Run = {
        $null -ne (Get-SmbClientConfiguration) -and $null -ne (Get-SmbServerConfiguration)
    } },
    @{ Name = "Chrome headless renders a local page"; Run = {
        $page = "C:\Windows\Temp\runs-on-chrome-smoke.html"
        $stdout = "C:\Windows\Temp\runs-on-chrome-smoke.stdout.txt"
        $stderr = "C:\Windows\Temp\runs-on-chrome-smoke.stderr.txt"
        $profile = "C:\Windows\Temp\runs-on-chrome-smoke-profile"
        '<html><body><h1 id="ready">runs-on-ready</h1></body></html>' | Set-Content $page -Encoding UTF8
        Remove-Item $stdout, $stderr, $profile -Recurse -Force -ErrorAction SilentlyContinue
        $arguments = @(
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            "--no-first-run",
            "--user-data-dir=$profile",
            "--dump-dom",
            "file:///$($page -replace '\\','/')"
        )
        $chrome = Start-Process -FilePath "C:\Program Files\Google\Chrome\Application\chrome.exe" -ArgumentList $arguments -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $dom = if (Test-Path $stdout) { [IO.File]::ReadAllText($stdout) } else { "" }
        $chrome.ExitCode -eq 0 -and $dom -match "runs-on-ready"
    } },
    @{ Name = "Chrome WebDriver creates a session"; Run = {
        $driver = Start-Process -FilePath "C:\SeleniumWebDrivers\ChromeDriver\chromedriver.exe" -ArgumentList @("--port=9515", "--allowed-ips=") -WindowStyle Hidden -PassThru
        try {
            Start-Sleep -Seconds 1
            $body = @{ capabilities = @{ alwaysMatch = @{ browserName = "chrome"; "goog:chromeOptions" = @{ args = @("--headless=new", "--no-sandbox", "--disable-gpu") } } } } | ConvertTo-Json -Depth 8
            $session = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:9515/session" -ContentType "application/json" -Body $body
            $sessionId = if ($session.value.sessionId) { $session.value.sessionId } else { $session.sessionId }
            if ($sessionId) { Invoke-RestMethod -Method Delete -Uri "http://127.0.0.1:9515/session/$sessionId" | Out-Null }
            -not [string]::IsNullOrWhiteSpace($sessionId)
        } finally {
            Stop-Process -Id $driver.Id -Force -ErrorAction SilentlyContinue
        }
    } }
)

if ($NestedVirtualization -eq "Enabled") {
    $operationalChecks += @{ Name = "Hyper-V is immediately usable"; Run = {
        (Get-CimInstance Win32_ComputerSystem).HypervisorPresent -and $null -ne (Get-VMHost)
    } }
}

if ($RunWindowsContainer) {
    $operationalChecks += @{ Name = "Windows container starts"; Run = {
        $output = docker run --rm mcr.microsoft.com/windows/nanoserver:ltsc2025 cmd /c echo runs-on-container-ready
        $LASTEXITCODE -eq 0 -and ($output -join "`n") -match "runs-on-container-ready"
    } }
}

$results += foreach ($check in $operationalChecks) {
    $success = $false
    try { $success = [bool](& $check.Run) } catch { Write-Warning "$($check.Name): $_" }
    [pscustomobject]@{
        Check = "Operational:$($check.Name)"
        Passed = [int]$success
        Failed = [int](-not $success)
        Skipped = 0
        Success = $success
    }
}

$results | Format-Table -AutoSize | Out-String | Write-Host
$summary = [pscustomobject]@{
    Success = -not ($results.Success -contains $false)
    Checks = $results.Count
    FailedChecks = @($results | Where-Object { -not $_.Success } | Select-Object -ExpandProperty Check)
    Results = $results
}
$summary | ConvertTo-Json -Depth 5 -Compress | Write-Output

if (-not $summary.Success) {
    throw "Full-stack smoke validation failed: $($summary.FailedChecks -join ', ')"
}
