$ErrorActionPreference = "Stop"
Write-Host "=== RunsOn Windows Boot Configuration ==="

function Disable-RunsOnService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    Write-Host "  Disabling $Name"
    Set-Service -Name $Name -StartupType Disabled -ErrorAction SilentlyContinue
    if ($svc.Status -eq "Running") {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

function Set-RunsOnServiceManual {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    Write-Host "  Manual $Name"
    Set-Service -Name $Name -StartupType Manual -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 1. AGGRESSIVE SERVICE DEBLOAT (maps to Ubuntu's 40+ unit disables)
# ---------------------------------------------------------------------------

Write-Host "Disabling unnecessary services..."

# === Boot/UI ===
Disable-RunsOnService "Themes"              # visual styles
Disable-RunsOnService "FontCache"           # font cache (Ubuntu: console-setup)
Disable-RunsOnService "FontCache3.0.0.0"
Disable-RunsOnService "hidserv"             # Human Interface Devices (Ubuntu: keyboard-setup)

# === Disk I/O ===
Disable-RunsOnService "SysMain"             # Superfetch (Ubuntu: no equivalent, but expensive)
Disable-RunsOnService "defragsvc"           # Disk defrag (Ubuntu: e2scrub_reap)
Disable-RunsOnService "wcnfs"               # Windows Container FS

# === Windows Search ===
Disable-RunsOnService "WSearch"             # Indexing (not useful for CI)

# === Windows Update ===
Disable-RunsOnService "wuauserv"            # Windows Update (Ubuntu: ubuntu-advantage, apt-news, esm-cache)
Disable-RunsOnService "UsoSvc"              # Update Orchestrator
Disable-RunsOnService "WaaSMedicSvc"        # Update Medic
Disable-RunsOnService "TrustedInstaller"    # Windows Modules Installer

# === Telemetry / Diagnostics ===
Disable-RunsOnService "DiagTrack"           # Connected User Experiences (Ubuntu: apport telemetry)
Disable-RunsOnService "dmwappushservice"    # Device Management WAP Push
Disable-RunsOnService "DPS"                 # Diagnostic Policy
Disable-RunsOnService "WdiServiceHost"      # Diagnostic Service Host
Disable-RunsOnService "WdiSystemHost"       # Diagnostic System Host
Disable-RunsOnService "WerSvc"              # Windows Error Reporting (Ubuntu: apport)
Disable-RunsOnService "wercplsupport"       # Problem Reports
Disable-RunsOnService "PcaSvc"              # Program Compatibility Assistant

# === Push Notifications ===
Disable-RunsOnService "WpnService"          # Push Notifications (Ubuntu: update-notifier)

# === Xbox / Gaming ===
Disable-RunsOnService "XblAuthManager"      # Xbox Live Auth
Disable-RunsOnService "XblGameSave"         # Xbox Live Game Save
Disable-RunsOnService "XboxNetApiSvc"       # Xbox Live Networking
Disable-RunsOnService "XboxGipSvc"          # Xbox Game Input Protocol

# === Customer Experience / Tips ===
Disable-RunsOnService "wisvc"               # Windows Insider Service
Disable-RunsOnService "WpcMonSvc"           # Parental Controls

# === Store / Licensing ===
Disable-RunsOnService "LicenseManager"      # Windows Store License
Disable-RunsOnService "ClipSVC"             # Client License Service
Disable-RunsOnService "InstallService"      # Microsoft Store Install (Ubuntu: snapd)

# === Bluetooth / Wireless ===
Disable-RunsOnService "BthAvctpSvc"         # Bluetooth Audio
Disable-RunsOnService "bthserv"             # Bluetooth Support
Disable-RunsOnService "wlansvc"             # WLAN AutoConfig

# === Geolocation / Sensors ===
Disable-RunsOnService "lfsvc"               # Geolocation
Disable-RunsOnService "SensrSvc"            # Sensor Service

# === Maps / Location ===
Disable-RunsOnService "MapsBroker"          # Downloaded Maps Manager

# === Delivery Optimization (P2P updates) ===
Disable-RunsOnService "DoSvc"               # Delivery Optimization
Disable-RunsOnService "DusmSvc"             # Data Usage

# === Network Discovery (SMB peers) ===
Disable-RunsOnService "FDResPub"            # Function Discovery Resource Publication
Disable-RunsOnService "SSDPSRV"             # SSDP Discovery
Disable-RunsOnService "upnphost"            # UPnP Device Host
Disable-RunsOnService "browser"             # Computer Browser
Disable-RunsOnService "LanmanServer"        # SMB Server
Disable-RunsOnService "LanmanWorkstation"   # SMB Client

# === Telephony / Modem ===
Disable-RunsOnService "TapiSrv"             # Telephony (Ubuntu: ModemManager)
Disable-RunsOnService "SmsRouter"           # SMS Router

# === Internet Connection Sharing ===
Disable-RunsOnService "SharedAccess"        # ICS

# === Tablet / Touch ===
Disable-RunsOnService "TabletInputService"  # Touch Keyboard

# === Microsoft Account ===
Disable-RunsOnService "wlidsvc"             # Microsoft Account Sign-in

# === BitLocker ===
Disable-RunsOnService "BDESVC"              # BitLocker Drive Encryption

# === Windows Time (reconfigured, not disabled) ===
Set-RunsOnServiceManual "W32Time"

# === Print Spooler (already disabled in patch-Configure-System) ===

# === Time Broker (keep as-is, needed by some apps) ===

# === Secondary logon (keep) ===

# === IP Helper (keep for containers) ===

# ---------------------------------------------------------------------------
# 2. NETWORK CATEGORY PRESET (avoid NLA delay on first boot)
# ---------------------------------------------------------------------------

Write-Host "Setting network category to Private (avoid NLA delay)..."
$null = Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  Setting $($_.Name) to Private"
    Set-NetConnectionProfile -Name $_.Name -NetworkCategory Private -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 3. REGISTRY BOOT TWEAKS (maps to Ubuntu GRUB/kernel cmdline tuning)
# ---------------------------------------------------------------------------

Write-Host "Applying registry boot optimizations..."

# --- Verbose vs normal boot ---
# Remove /bootlog, /sos flags if present
$bcdHive = "HKLM:\BCD00000000"
# Set boot timeout to 0
bcdedit.exe /timeout 0 | Out-Null

# --- Disable GUI boot (server core style, faster) ---
try { bcdedit.exe /set bootstatuspolicy ignoreallfailures | Out-Null } catch {}
try { bcdedit.exe /set quietboot on | Out-Null } catch {}
try { bcdedit.exe /set nx OptOut | Out-Null } catch {}
try { bcdedit.exe /set tpmbootentropy ForceDisable 2>$null | Out-Null } catch {}

# --- Auto-end tasks at shutdown for faster reboot during build ---
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "AutoEndTasks" -Value "1" -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "HungAppTimeout" -Value "1000" -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WaitToKillAppTimeout" -Value "2000" -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "WaitToKillServiceTimeout" -Value "2000" -Force -ErrorAction SilentlyContinue

# --- Disable Windows startup sound ---
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableAutomaticRestartSignOn" -Value 1 -Force -ErrorAction SilentlyContinue

# --- Disable last access timestamp (NTFS) ---
fsutil behavior set disablelastaccess 1 | Out-Null

# --- Disable 8.3 filename creation ---
fsutil behavior set disable8dot3 1 | Out-Null

# --- Faster service timeout ---
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "ServicesPipeTimeout" -Value "30000" -Type DWord -Force -ErrorAction SilentlyContinue

# --- Disable hibernation (already off on server, but just in case) ---
powercfg /h off | Out-Null

# --- Disable system restore ---
Disable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue

# --- Disable NTFS short name creation ---
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "NtfsDisable8dot3NameCreation" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

# --- Disable NTFS last access update ---
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "NtfsDisableLastAccessUpdate" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "Registry boot configuration complete."

# ---------------------------------------------------------------------------
# 4. TELEMETRY / CEIP COMPLETE BLOCK (maps to Ubuntu's telemetry-free stance)
# ---------------------------------------------------------------------------

Write-Host "Blocking telemetry and CEIP..."

Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "MaxTelemetryAllowed" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "DoNotShowFeedbackNotifications" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowCommercialDataPipeline" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SQMClient\Windows" -Name "CEIPEnable" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SQMClient\Reliability" -Name "CEIPEnable" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

# Disable Windows tips, tricks, and suggestions
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableSoftLanding" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "Telemetry blocked."

# ---------------------------------------------------------------------------
# 5. SCHEDULED TASK CLEANUP (maps to Ubuntu timer/cron disable)
# ---------------------------------------------------------------------------

Write-Host "Disabling boot-triggered scheduled tasks..."

$tasksToDisable = @(
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "\Microsoft\Windows\Application Experience\StartupAppTask",
    "\Microsoft\Windows\Autochk\Proxy",
    "\Microsoft\Windows\Chkdsk\ProactiveScan",
    "\Microsoft\Windows\Chkdsk\SyspartRepair",
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
    "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
    "\Microsoft\Windows\Defrag\ScheduledDefrag",
    "\Microsoft\Windows\Diagnosis\Scheduled",
    "\Microsoft\Windows\DiskCleanup\SilentCleanup",
    "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
    "\Microsoft\Windows\DiskFootprint\Diagnostics",
    "\Microsoft\Windows\Location\Notifications",
    "\Microsoft\Windows\Maps\MapsToastTask",
    "\Microsoft\Windows\Maps\MapsUpdateTask",
    "\Microsoft\Windows\MemoryDiagnostic\RunFullMemoryDiagnostic",
    "\Microsoft\Windows\MemoryDiagnostic\ProcessMemoryDiagnosticEvents",
    "\Microsoft\Windows\PI\Sqm-Tasks",
    "\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem",
    "\Microsoft\Windows\Registry\RegIdleBackup",
    "\Microsoft\Windows\Server Manager\ServerManager",
    "\Microsoft\Windows\SoftwareProtectionPlatform\SvcRestartTask",
    "\Microsoft\Windows\Speech\SpeechModelDownloadTask",
    "\Microsoft\Windows\Sysmain\HybridDriveCachePrepopulate",
    "\Microsoft\Windows\Sysmain\ResPriStaticDbSync",
    "\Microsoft\Windows\Sysmain\WsSwapAssessmentTask",
    "\Microsoft\Windows\Time Synchronization\SynchronizeTime",
    "\Microsoft\Windows\Time Zone\SynchronizeTimeZone",
    "\Microsoft\Windows\UPnP\UPnPHostConfig",
    "\Microsoft\Windows\UpdateOrchestrator\Schedule Scan",
    "\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker",
    "\Microsoft\Windows\WaaSMedic\PerformRemediation",
    "\Microsoft\Windows\Windows Error Reporting\QueueReporting",
    "\Microsoft\Windows\Windows Filtering Platform\BfeOnServiceStartTypeChange"
)

foreach ($taskPath in $tasksToDisable) {
    try {
        Disable-ScheduledTask -TaskPath (Split-Path $taskPath -Parent) -TaskName (Split-Path $taskPath -Leaf) -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  Could not disable $taskPath : $_" 
    }
}

Write-Host "Scheduled tasks pruned."

# ---------------------------------------------------------------------------
# 6. WINDOWS UPDATE FULL BLOCK
# ---------------------------------------------------------------------------

Write-Host "Blocking Windows Update..."

# No auto-restart for updates
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AutomaticMaintenanceEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

# Disable driver search via Windows Update
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "SearchOrderConfig" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

# Disable Windows Update for device drivers
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "Windows Update blocked."

# ---------------------------------------------------------------------------
# 7. WINDOWS DEFENDER HARD DISABLE (maps to Ubuntu AppArmor disable)
# ---------------------------------------------------------------------------

Write-Host "Hard-disabling Windows Defender..."

# Disable real-time protection via registry
$defenderPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
if (-not (Test-Path $defenderPath)) {
    New-Item -Path $defenderPath -Force | Out-Null
}
Set-ItemProperty -Path $defenderPath -Name "DisableAntiSpyware" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "$defenderPath\Real-Time Protection" -Name "DisableRealtimeMonitoring" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "$defenderPath\Real-Time Protection" -Name "DisableBehaviorMonitoring" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "$defenderPath\Real-Time Protection" -Name "DisableOnAccessProtection" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "$defenderPath\Real-Time Protection" -Name "DisableScanOnRealtimeEnable" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "Windows Defender disabled."

# ---------------------------------------------------------------------------
# 8. WINDOWS TIME FOR AWS (maps to Ubuntu chrony @ 169.254.169.123)
# ---------------------------------------------------------------------------

Write-Host "Configuring Windows Time for AWS..."

w32tm /config /manualpeerlist:169.254.169.123 /syncfromflags:manual /reliable:yes /update | Out-Null
w32tm /resync | Out-Null

Write-Host "Windows Time configured."

# ---------------------------------------------------------------------------
# 9. FAST USER PROFILE (maps to rolaunch user-data execution)
# ---------------------------------------------------------------------------

Write-Host "Optimizing user profile..."

# Don't create a pagefile at all
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "PagingFiles" -Value @() -Force -ErrorAction SilentlyContinue

# Disable user profile cleanup at logoff
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -Name "DeleteRoamingCache" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "User profile optimized."

# ---------------------------------------------------------------------------
# 10. CLEAR PREFETCH / MEMORY DUMP / AUTOCHEK
# ---------------------------------------------------------------------------

Write-Host "Clearing prefetch cache..."
Remove-Item -Path "C:\Windows\Prefetch\*" -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" -Name "EnablePrefetcher" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" -Name "EnableSuperfetch" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "Disabling memory dumps and autocheck..."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" -Name "CrashDumpEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" -Name "LogEvent" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" -Name "SendAlert" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

# Disable autochk (disk check at boot)
cmd /c "chkntfs /x C:" 2>$null | Out-Null

Write-Host "Prefetch, dump, and autocheck disabled."

# ---------------------------------------------------------------------------
# 11. VERBOSE SHUTDOWN TO CATCH PROBLEMS
# ---------------------------------------------------------------------------

Write-Host "Setting verbose shutdown to surface issues..."

Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "VerboseStatus" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "=== RunsOn Windows Boot Configuration Complete ==="
