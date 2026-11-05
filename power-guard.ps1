# power-guard.ps1 - protect against crashes when the PC switches between charger and battery. Run as Administrator.
#
#   Layer 1  Same device power policy on battery as on the charger, in every power plan: PCIe Link State Power
#            Management off, Wi-Fi adapter at maximum performance, USB selective suspend off. A charger cut-out then
#            no longer makes the GPU / Wi-Fi / Bluetooth drivers change power state at that very moment.
#   Layer 2  Lower load peaks: maximum processor state 99 % (turns Turbo Boost off) so the charger is less likely to be
#            overloaded and fall back to the battery. Costs some peak performance.
#   Layer 3  Black box: (a) a task that runs the instant the power source changes (Kernel-Power 105), records the load,
#            and pops up if the charger came back within 60 s (a cut-out, not an unplug); (b) a 1-second performance
#            log (CPU, GPU, temperatures, memory) in a circular file via Windows' own logging service; after an
#            unexpected shutdown RamWatch exports the minutes before it.
#
#   -Install        all three layers           -Status       show what is applied
#   -Uninstall      undo everything (original values come from power-guard-backup.json)
#   -CapTurbo / -UncapTurbo   only layer 2
param([switch]$Install, [switch]$Uninstall, [switch]$Status, [switch]$CapTurbo, [switch]$UncapTurbo)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$backupPath = Join-Path $root 'power-guard-backup.json'
$pd = 'C:\ProgramData\RamWatch'
$rec = Join-Path $pd 'recorder'

# (subgroup, setting, AC value, DC value) - layer 1
$Layer1 = @(
    @{ name = 'PCIe Link State Power Management'; sub = '501a4d13-42af-4429-9fd1-a8218c268e20'; set = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; ac = 0; dc = 0 },
    @{ name = 'Wi-Fi adapter power saving';        sub = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; set = '12bbebe6-58d6-4636-95bb-3217ef867c1a'; ac = 0; dc = 0 },
    @{ name = 'USB selective suspend';             sub = '2a737441-1930-4402-8d77-b2bebba308a3'; set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; ac = 0; dc = 0 }
)
$Layer2 = @{ name = 'Maximum processor state'; sub = '54533251-82be-4824-96c1-47b60b740d00'; set = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; ac = 99; dc = 99 }

$Counters = @(
    '\Processor Information(_Total)\% Processor Utility',
    '\Processor Information(_Total)\% Processor Performance',
    '\GPU Engine(*engtype_3D)\Utilization Percentage',
    '\Thermal Zone Information(*)\Temperature',
    '\Thermal Zone Information(*)\% Passive Limit',
    '\Memory\Available MBytes',
    '\Memory\% Committed Bytes In Use'
)   # no battery counters: on some machines the battery driver hangs every query

function Assert-Admin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this from PowerShell as Administrator.'
    }
}
function Get-Schemes { (powercfg /list) | Select-String '([0-9a-f-]{36})' | ForEach-Object { $_.Matches[0].Groups[1].Value } }
function Get-Value($scheme, $s) {
    $o = powercfg /query $scheme $s.sub $s.set 2>$null
    $ac = ($o | Select-String 'Current AC Power Setting Index: (0x[0-9a-f]+)').Matches.Groups[1].Value
    $dc = ($o | Select-String 'Current DC Power Setting Index: (0x[0-9a-f]+)').Matches.Groups[1].Value
    if ($ac) { [pscustomobject]@{ ac = [Convert]::ToInt32($ac, 16); dc = [Convert]::ToInt32($dc, 16) } }
}
function Set-Value($scheme, $s, $ac, $dc) {
    powercfg /setacvalueindex $scheme $s.sub $s.set $ac | Out-Null
    powercfg /setdcvalueindex $scheme $s.sub $s.set $dc | Out-Null
}
function Load-Backup { if (Test-Path $backupPath) { Get-Content $backupPath -Raw | ConvertFrom-Json } }
# remember the original values once (never overwrite an existing backup with already-changed values)
function Save-Backup($settings) {
    $b = @{}; $old = Load-Backup
    if ($old) { foreach ($p in $old.PSObject.Properties) { $b[$p.Name] = $p.Value } }
    foreach ($scheme in Get-Schemes) { foreach ($s in $settings) {
        $k = "$scheme|$($s.sub)|$($s.set)"
        if (-not $b.ContainsKey($k)) { $v = Get-Value $scheme $s; if ($v) { $b[$k] = $v } }
    } }
    $b | ConvertTo-Json | Set-Content $backupPath -Encoding UTF8
}
function Restore-Settings($settings) {
    $b = Load-Backup; if (-not $b) { 'No backup - nothing to restore.'; return }
    foreach ($scheme in Get-Schemes) { foreach ($s in $settings) {
        $v = $b."$scheme|$($s.sub)|$($s.set)"
        if ($v) { Set-Value $scheme $s $v.ac $v.dc }
    } }
    powercfg /setactive SCHEME_CURRENT | Out-Null
}
function Apply-Settings($settings) {
    Save-Backup $settings
    foreach ($scheme in Get-Schemes) { foreach ($s in $settings) { if (Get-Value $scheme $s) { Set-Value $scheme $s $s.ac $s.dc } } }
    powercfg /setactive SCHEME_CURRENT | Out-Null
}

function Install-Recorder {
    New-Item -ItemType Directory -Force $rec | Out-Null
    logman stop RamWatchRecorder 2>$null | Out-Null
    logman delete RamWatchRecorder 2>$null | Out-Null
    # bincirc + version suffix: a restart starts a new file, so the file from before a crash is never overwritten
    logman create counter RamWatchRecorder -c $Counters -si 00:00:01 -f bincirc -max 64 -v mmddhhmm -o "$rec\rw" | Out-Null
    @"
# start the RamWatch black box after boot; keep the 6 newest log files
Get-ChildItem '$rec' -Filter *.blg | Sort-Object LastWriteTime -Descending | Select-Object -Skip 6 | Remove-Item -Force -EA SilentlyContinue
logman start RamWatchRecorder | Out-Null
"@ | Set-Content "$pd\recorder-start.ps1" -Encoding UTF8
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$pd\recorder-start.ps1`""
    $trg = New-ScheduledTaskTrigger -AtStartup; $trg.Delay = 'PT30S'
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName 'RamWatchRecorderStart' -Action $act -Trigger $trg -Settings $set -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    logman start RamWatchRecorder | Out-Null
}

function Install-EventTask {
    $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trg = New-CimInstance -CimClass $cls -ClientOnly
    $trg.Enabled = $true
    $trg.Subscription = "<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=105)]]</Select></Query></QueryList>"
    $act = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$root\power-event.ps1`""
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
    # runs as the logged-on user (interactive) so its popup is visible
    Register-ScheduledTask -TaskName 'RamWatchPowerEvent' -Action $act -Trigger $trg -Settings $set -Description 'RamWatch: record load at every charger/battery switch' -Force | Out-Null
}

function Show-Status {
    $active = (powercfg /getactivescheme) -replace '.*: ([0-9a-f-]{36}).*', '$1'
    'Active power plan:'
    foreach ($s in $Layer1 + $Layer2) { $v = Get-Value $active $s; "  {0,-34} charger={1,-3} battery={2}" -f $s.name, $v.ac, $v.dc }
    $t = Get-ScheduledTask -TaskName RamWatchPowerEvent -EA SilentlyContinue
    "Power-switch task: $(if ($t) { $t.State } else { 'not installed' })"
    $q = logman query RamWatchRecorder 2>$null | Select-String 'Status:'
    "Black-box recorder: $(if ($q) { ($q.Line -replace '.*:\s*', '') } else { 'not installed' })"
    $last = Get-ChildItem $rec -Filter *.blg -EA SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($last) { "  newest log: $($last.Name) ($([math]::Round($last.Length / 1MB, 1)) MB)" }
    $ev = Get-ChildItem (Join-Path $root 'power-events') -Filter *.jsonl -EA SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($ev) { 'Last power switches:'; Get-Content $ev.FullName -Tail 5 | ForEach-Object { $e = $_ | ConvertFrom-Json; "  $($e.t)  $($e.kind)  cpu=$($e.cpu_pct)% gpu3d=$($e.gpu3d_pct)%" } }
}

if ($Status -or -not ($Install -or $Uninstall -or $CapTurbo -or $UncapTurbo)) { Show-Status; return }
Assert-Admin
if ($Install) {
    Apply-Settings ($Layer1 + $Layer2); 'Layers 1+2: battery policy now matches the charger in every plan; max processor state 99 %.'
    Install-EventTask; 'Layer 3a: power-switch task installed.'
    Install-Recorder;  "Layer 3b: black-box recorder running ($rec)."
    Show-Status
}
if ($CapTurbo)   { Apply-Settings @($Layer2); 'Turbo capped (max processor state 99 %).' }
if ($UncapTurbo) { Restore-Settings @($Layer2); 'Turbo restored to the original value.' }
if ($Uninstall) {
    Restore-Settings ($Layer1 + $Layer2)
    Unregister-ScheduledTask -TaskName RamWatchPowerEvent -Confirm:$false -EA SilentlyContinue
    Unregister-ScheduledTask -TaskName RamWatchRecorderStart -Confirm:$false -EA SilentlyContinue
    logman stop RamWatchRecorder 2>$null | Out-Null; logman delete RamWatchRecorder 2>$null | Out-Null
    Remove-Item "$pd\recorder-start.ps1" -Force -EA SilentlyContinue
    'Power guard removed; original power settings restored. Recorder files stay in ' + $rec
}
