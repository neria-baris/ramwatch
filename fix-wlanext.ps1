# fix-wlanext.ps1 - deal with wlanext.exe memory growth.
# wlanext.exe is the Windows host for the Wi-Fi vendor's "IHV extension" DLL (for Intel adapters:
# IntelIHVRouter*.dll). When wlanext keeps growing, the leak normally lives in that vendor DLL, not in Windows.
#
#   -Status              show wlanext memory, the loaded extension, and the guard state (no admin needed)
#   -DisableIhv          root fix: stop wlanext from loading the vendor extension (backed up, reversible). Admin.
#   -RestoreIhv          undo -DisableIhv. Admin.
#   -InstallGuard        fallback: hourly SYSTEM task restarts WlanSvc when wlanext exceeds -LimitMB. Admin.
#   -RemoveGuard         remove that task. Admin.
param(
    [switch]$Status, [switch]$DisableIhv, [switch]$RestoreIhv, [switch]$InstallGuard, [switch]$RemoveGuard,
    [int]$LimitMB = 1500
)
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
function Need-Admin { if (-not $isAdmin) { throw 'Run this from PowerShell as Administrator.' } }

function Get-WifiClassKey {
    $guid = (Get-NetAdapter -Physical | Where-Object { $_.PhysicalMediaType -match '802.11' -or $_.InterfaceDescription -match 'Wireless|Wi-Fi' } | Select-Object -First 1).InterfaceGuid
    if (-not $guid) { throw 'No Wi-Fi adapter found.' }
    $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    foreach ($k in Get-ChildItem $class -EA SilentlyContinue) {
        if ((Get-ItemProperty $k.PSPath -EA SilentlyContinue).NetCfgInstanceId -eq $guid) { return "$($k.PSPath)\Ndi\IHVExtensions" }
    }
    throw 'Wi-Fi adapter registry key not found.'
}
function Restart-Wlan { Write-Host 'Restarting WLAN AutoConfig (Wi-Fi drops for a few seconds)...'; Restart-Service WlanSvc -Force; Start-Sleep 3 }

$ihv = Get-WifiClassKey
$props = Get-ItemProperty $ihv -EA SilentlyContinue
$guardDir = 'C:\ProgramData\RamWatch'

if ($DisableIhv) {
    Need-Admin
    if (-not $props.ExtensibilityDLL) { 'Intel IHV extension is already disabled.'; return }
    # rename instead of delete: the original value stays right there for -RestoreIhv
    Rename-ItemProperty -Path $ihv -Name ExtensibilityDLL -NewName ExtensibilityDLL_DisabledByRamWatch
    "Disabled: $($props.ExtensibilityDLL)"
    Restart-Wlan
    'Done. Check that Wi-Fi reconnects. If anything misbehaves: .\fix-wlanext.ps1 -RestoreIhv'
    'Note: a Wi-Fi driver update re-registers the extension; run -Status after updates.'
    return
}
if ($RestoreIhv) {
    Need-Admin
    if (-not $props.ExtensibilityDLL_DisabledByRamWatch) { 'Nothing to restore.'; return }
    Rename-ItemProperty -Path $ihv -Name ExtensibilityDLL_DisabledByRamWatch -NewName ExtensibilityDLL
    "Restored: $($props.ExtensibilityDLL_DisabledByRamWatch)"
    Restart-Wlan
    return
}
if ($InstallGuard) {
    Need-Admin
    # The task runs as SYSTEM, so its script lives in an admin-only folder (not in the user-writable RamWatch folder).
    New-Item -ItemType Directory -Force $guardDir | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($id in 'SYSTEM', 'Administrators') {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('Users', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl $guardDir $acl
    @"
`$p = Get-Process wlanext -EA SilentlyContinue | Sort-Object PrivateMemorySize64 -Descending | Select-Object -First 1
if (`$p -and `$p.PrivateMemorySize64 -gt $LimitMB * 1MB) {
    `$mb = [math]::Round(`$p.PrivateMemorySize64 / 1MB)
    Restart-Service WlanSvc -Force
    Add-Content '$guardDir\wlanext-guard.log' "`$(Get-Date -Format s) wlanext at `$mb MB > $LimitMB MB -> WlanSvc restarted"
}
"@ | Set-Content "$guardDir\wlanext-guard.ps1" -Encoding UTF8
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$guardDir\wlanext-guard.ps1`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName 'RamWatchWlanGuard' -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Description "Restart WlanSvc when wlanext.exe exceeds $LimitMB MB" -Force | Out-Null
    "Guard installed: hourly, restarts WlanSvc when wlanext > $LimitMB MB. Log: $guardDir\wlanext-guard.log"
    return
}
if ($RemoveGuard) {
    Need-Admin
    Unregister-ScheduledTask -TaskName 'RamWatchWlanGuard' -Confirm:$false -EA SilentlyContinue
    # the folder is shared with the SSD-health task from setup-admin.ps1; remove only the guard's files
    Remove-Item "$guardDir\wlanext-guard.ps1", "$guardDir\wlanext-guard.log" -Force -EA SilentlyContinue
    'Guard removed.'
    return
}

# default / -Status
$w = Get-Process wlanext -EA SilentlyContinue | Select-Object -First 1
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
if ($w) {
    $mb = [math]::Round($w.PrivateMemorySize64 / 1MB)
    $h = [math]::Round(((Get-Date) - $boot).TotalHours, 1)
    "wlanext.exe: $mb MB private after $h h of uptime (~$([math]::Round($mb / [math]::Max($h, 0.1))) MB/h)"
} else { 'wlanext.exe is not running (no IHV extension loaded, or Wi-Fi off).' }
if ($props.ExtensibilityDLL) {
    $dll = [Environment]::ExpandEnvironmentVariables($props.ExtensibilityDLL)
    "Intel IHV extension: ENABLED  $dll  v$((Get-Item $dll -EA SilentlyContinue).VersionInfo.FileVersion)"
} elseif ($props.ExtensibilityDLL_DisabledByRamWatch) { "Intel IHV extension: DISABLED by RamWatch ($($props.ExtensibilityDLL_DisabledByRamWatch))" }
else { 'Intel IHV extension: none registered' }
$t = Get-ScheduledTask -TaskName RamWatchWlanGuard -EA SilentlyContinue
"Guard task: $(if ($t) { "installed ($($t.State))" } else { 'not installed' })"
if (Test-Path "$guardDir\wlanext-guard.log") { 'Recent guard restarts:'; Get-Content "$guardDir\wlanext-guard.log" -Tail 5 }
