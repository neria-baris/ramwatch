# setup-admin.ps1 - one-time Administrator setup for RamWatch. Safe to run again.
#   1. Bigger event logs (System 256 MB, Application 128 MB) so crash evidence survives longer than a few days.
#   2. Daily SYSTEM task that records SSD health counters (temperature, wear, errors) for RamWatch.
#   3. Battery driver: on a non-Surface PC that picked up Microsoft's "Surface" battery INF, switch back to
#      Windows' own battery driver (the INF is exported first; it rolls back on failure).
#   4. Turn off the auto-start apps/services listed in startup-config.json (skipped if that file doesn't exist).
# Options: -SkipBattery  -SkipStartup  -RestoreBattery (undo step 3)
param([switch]$SkipBattery, [switch]$SkipStartup, [switch]$RestoreBattery)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from PowerShell as Administrator.'
}
$backup = Join-Path $root 'driver-backup\surface-battery'

function Get-BatteryDriverInfo {
    $id = (Get-PnpDevice -Class Battery | Where-Object FriendlyName -like '*Control Method Battery*' | Select-Object -First 1).InstanceId
    $inf = (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_DriverInfPath).Data
    $name = (Get-PnpDevice -InstanceId $id).FriendlyName
    [pscustomobject]@{ InstanceId = $id; Inf = $inf; Name = $name }
}

if ($RestoreBattery) {
    $inf = Get-ChildItem $backup -Filter *.inf -Recurse | Select-Object -First 1
    if (-not $inf) { throw "No backup found in $backup" }
    pnputil /add-driver $inf.FullName /install
    pnputil /scan-devices | Out-Null
    "Battery driver now: $((Get-BatteryDriverInfo).Name)"
    return
}

# ---- 1. event log sizes ----
Write-Host '[1/4] Event log sizes' -ForegroundColor Cyan
wevtutil sl System /ms:268435456
wevtutil sl Application /ms:134217728
foreach ($l in 'System', 'Application') { $x = Get-WinEvent -ListLog $l; "  $l log: $([math]::Round($x.MaximumSizeInBytes / 1MB)) MB" }

# ---- 2. SSD health task (runs as SYSTEM, script in an admin-only folder) ----
Write-Host '[2/4] SSD health task' -ForegroundColor Cyan
$pd = 'C:\ProgramData\RamWatch'
New-Item -ItemType Directory -Force $pd | Out-Null
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($idn in 'SYSTEM', 'Administrators') {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($idn, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('Users', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl $pd $acl
@'
$out = foreach ($d in Get-PhysicalDisk) {
    $r = $d | Get-StorageReliabilityCounter -EA SilentlyContinue
    [ordered]@{ name = $d.FriendlyName; health = "$($d.HealthStatus)"; temp_c = $r.Temperature; temp_max_c = $r.TemperatureMax
                wear = $r.Wear; read_errors = $r.ReadErrorsTotal; write_errors = $r.WriteErrorsTotal; power_on_hours = $r.PowerOnHours
                taken_at = (Get-Date).ToString('s') }
}
ConvertTo-Json @($out) -Depth 3 | Set-Content 'C:\ProgramData\RamWatch\disk-health.json' -Encoding UTF8
'@ | Set-Content "$pd\disk-health.ps1" -Encoding UTF8
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$pd\disk-health.ps1`""
$set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'RamWatchDiskHealth' -Action $act -Trigger @((New-ScheduledTaskTrigger -Daily -At 09:40), (New-ScheduledTaskTrigger -AtStartup)) `
    -Settings $set -User 'SYSTEM' -RunLevel Highest -Description 'SSD health counters for RamWatch' -Force | Out-Null
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$pd\disk-health.ps1"
Get-Content "$pd\disk-health.json" | ConvertFrom-Json | Format-Table name, health, temp_c, wear, read_errors, power_on_hours -AutoSize

# ---- 3. battery driver ----
if (-not $SkipBattery) {
    Write-Host '[3/4] Battery driver' -ForegroundColor Cyan
    $b = Get-BatteryDriverInfo
    "  current: $($b.Name)  ($($b.Inf))"
    $isSurface = (Get-CimInstance Win32_ComputerSystem).Manufacturer -match 'Microsoft'
    if (-not $isSurface -and $b.Name -like '*Surface*' -and $b.Inf -like 'oem*.inf') {
        New-Item -ItemType Directory -Force $backup | Out-Null
        pnputil /export-driver $b.Inf $backup | Out-Null
        "  backed up $($b.Inf) to $backup"
        pnputil /delete-driver $b.Inf /uninstall /force | Out-Null
        pnputil /scan-devices | Out-Null
        Start-Sleep 3
        $n = Get-BatteryDriverInfo
        "  now:     $($n.Name)  ($($n.Inf))"
        if (-not $n.Name -or $n.Name -like '*Surface*') {
            Write-Warning 'Windows did not pick its own battery driver; restoring the backup.'
            & $PSCommandPath -RestoreBattery
        }
    } else { '  already on the Windows battery driver - nothing to do.' }
}

# ---- 4. auto-start ----
if (-not $SkipStartup -and (Test-Path (Join-Path $root 'startup-config.json'))) {
    Write-Host '[4/4] Auto-start apps and services' -ForegroundColor Cyan
    & (Join-Path $root 'disable-startup.ps1')
}
Write-Host 'Done.' -ForegroundColor Green
