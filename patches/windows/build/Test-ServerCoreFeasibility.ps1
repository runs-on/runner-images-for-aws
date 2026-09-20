################################################################################
##  File:  Test-ServerCoreFeasibility.ps1
##  Desc:  Exercise the reduced-stack Server Core compatibility experiment
################################################################################

if ($env:SERVER_CORE_FEASIBILITY -ne "true") { exit 0 }
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$results = [ordered]@{}

function Invoke-FeasibilityCheck {
    param([string]$Name, [scriptblock]$Check)
    try {
        $results[$Name] = [bool](& $Check)
    } catch {
        $results[$Name] = $false
        Write-Warning "$Name failed: $_"
    }
}

Invoke-FeasibilityCheck "App Compatibility FOD" {
    (Get-WindowsCapability -Online -Name "ServerCore.AppCompatibility~~~~0.0.1.0").State -eq "Installed"
}
Invoke-FeasibilityCheck "Runner" { Test-Path "C:\actions-runner\bin\Runner.Listener.exe" }
Invoke-FeasibilityCheck "PowerShell" { (pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'); $LASTEXITCODE -eq 0 }
Invoke-FeasibilityCheck "Node" { (node --version); $LASTEXITCODE -eq 0 }
Invoke-FeasibilityCheck "Docker Windows engine" { (docker info --format '{{.OSType}}') -eq "windows" }
Invoke-FeasibilityCheck "Build tools" {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    -not [string]::IsNullOrWhiteSpace($installation)
}
Invoke-FeasibilityCheck "Chrome headless" {
    $page = "C:\Windows\Temp\runs-on-core-chrome.html"
    '<html><body>runs-on-core-ready</body></html>' | Set-Content $page -Encoding UTF8
    $dom = & "C:\Program Files\Google\Chrome\Application\chrome.exe" --headless=new --no-sandbox --disable-gpu --dump-dom "file:///$($page -replace '\\','/')" 2>$null
    $LASTEXITCODE -eq 0 -and ($dom -join "`n") -match "runs-on-core-ready"
}
Invoke-FeasibilityCheck "Chrome WebDriver" {
    $driver = Start-Process "C:\SeleniumWebDrivers\ChromeDriver\chromedriver.exe" -ArgumentList @("--port=9515", "--allowed-ips=") -WindowStyle Hidden -PassThru
    try {
        Start-Sleep 1
        $body = @{ capabilities = @{ alwaysMatch = @{ browserName = "chrome"; "goog:chromeOptions" = @{ args = @("--headless=new", "--no-sandbox") } } } } | ConvertTo-Json -Depth 8
        $session = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:9515/session" -ContentType "application/json" -Body $body
        $sessionId = if ($session.value.sessionId) { $session.value.sessionId } else { $session.sessionId }
        if ($sessionId) { Invoke-RestMethod -Method Delete -Uri "http://127.0.0.1:9515/session/$sessionId" | Out-Null }
        -not [string]::IsNullOrWhiteSpace($sessionId)
    } finally {
        Stop-Process $driver.Id -Force -ErrorAction SilentlyContinue
    }
}
Invoke-FeasibilityCheck "Playwright with installed Chrome" {
    $playwrightDirectory = "C:\Windows\Temp\runs-on-playwright-smoke"
    New-Item $playwrightDirectory -ItemType Directory -Force | Out-Null
    Push-Location $playwrightDirectory
    try {
        npm install --no-audit --no-fund --ignore-scripts playwright-core | Out-Null
        @'
const { chromium } = require("playwright-core");
(async () => {
  const browser = await chromium.launch({
    executablePath: "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    headless: true,
    args: ["--no-sandbox"]
  });
  const page = await browser.newPage();
  await page.setContent("<h1>runs-on-playwright-ready</h1>");
  if ((await page.textContent("h1")) !== "runs-on-playwright-ready") process.exitCode = 1;
  await browser.close();
})();
'@ | Set-Content "smoke.js" -Encoding UTF8
        node smoke.js
        $LASTEXITCODE -eq 0
    } finally {
        Pop-Location
    }
}
Invoke-FeasibilityCheck "Windows container" {
    $output = docker run --rm mcr.microsoft.com/windows/nanoserver:ltsc2025 cmd /c echo runs-on-core-container-ready
    $LASTEXITCODE -eq 0 -and ($output -join "`n") -match "runs-on-core-container-ready"
}

$outputPath = "C:\ProgramData\RunsOn\server-core-feasibility.json"
New-Item (Split-Path $outputPath) -ItemType Directory -Force | Out-Null
$results | ConvertTo-Json | Set-Content $outputPath -Encoding UTF8
$results.GetEnumerator() | ForEach-Object { "{0}: {1}" -f $_.Key, $_.Value }
if ($results.Values -contains $false) {
    throw "Server Core feasibility checks failed"
}
