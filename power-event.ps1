# power-event.ps1 - started by Task Scheduler the instant the power source changes (Kernel-Power 105).
# Records load and device state into power-events\<date>.jsonl. If the PC fell to battery and the charger came back
# within 60 s, that was a cut-out (not an unplug): it gets a report and a popup.
#   -ExportCrash   after an unexpected shutdown: export the black-box minutes before it to power-events\crash-*.csv
param([switch]$ExportCrash, [int]$Minutes = 10)
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$dir = Join-Path $root 'power-events'; New-Item -ItemType Directory -Force $dir | Out-Null
$rec = 'C:\ProgramData\RamWatch\recorder'

if ($ExportCrash) {
    # the log that was being written when the PC went down = newest file last written before this boot
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $blg = Get-ChildItem $rec -Filter *.blg -EA SilentlyContinue | Where-Object { $_.LastWriteTime -lt $boot } | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $blg) { 'No black-box log from before this boot.'; return }
    $out = Join-Path $dir ("crash-" + $blg.LastWriteTime.ToString('yyyy-MM-dd_HHmmss') + '.csv')
    if (Test-Path $out) { "Already exported: $out"; return }
    $fmt = 'M/d/yyyy H:mm:ss'
    $b = $blg.LastWriteTime.AddMinutes(-$Minutes).ToString($fmt, [Globalization.CultureInfo]::InvariantCulture)
    $e = $blg.LastWriteTime.AddMinutes(1).ToString($fmt, [Globalization.CultureInfo]::InvariantCulture)
    relog $blg.FullName -f csv -o $out -b $b -e $e -y | Out-Null
    "Exported $Minutes min before $($blg.LastWriteTime): $out"
    return
}

. (Join-Path $root 'collect.ps1')   # Get-DeviceState, WinForms

function Get-Load {
    $c = Get-Counter '\Processor Information(_Total)\% Processor Utility', '\GPU Engine(*engtype_3D)\Utilization Percentage' -EA SilentlyContinue
    $cpu = ($c.CounterSamples | Where-Object Path -like '*processor utility' | Select-Object -First 1).CookedValue
    $gpu = ($c.CounterSamples | Where-Object Path -like '*engtype_3d*' | Measure-Object CookedValue -Sum).Sum
    # top CPU users over one second
    $a = @{}; Get-Process | ForEach-Object { $a[$_.Id] = $_.CPU }
    Start-Sleep -Milliseconds 1000
    $n = [Environment]::ProcessorCount
    $top = Get-Process | ForEach-Object { if ($a.ContainsKey($_.Id) -and $_.CPU) { [pscustomobject]@{ n = $_.ProcessName; p = [math]::Round(100 * ($_.CPU - $a[$_.Id]) / $n, 1) } } } |
        Sort-Object p -Descending | Select-Object -First 5 | ForEach-Object { "$($_.n):$($_.p)%" }
    $g = Get-DeviceState 'Display' '*NVIDIA*', '*Radeon*', '*Arc*'
    if ($g.status -eq 'OK') {
        $smi = & "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=power.draw,temperature.gpu --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $smi) { $v = ($smi -split ',').Trim(); $g.power_w = $v[0]; $g.temp_c = $v[1] }
    }
    [ordered]@{ cpu_pct = [math]::Round($cpu); gpu3d_pct = [math]::Round([math]::Min(100, $gpu)); top = @($top); gpu = $g
                bluetooth = Get-DeviceState 'Bluetooth' '*Wireless Bluetooth*', '*Bluetooth*Adapter*', '*Bluetooth*Radio*', '*Bluetooth*' -exclude 'Microsoft Bluetooth*', 'Bluetooth Device*', '*Enumerator*' }
}

$t0 = Get-Date
$ps = [System.Windows.Forms.SystemInformation]::PowerStatus
$load = Get-Load
$ev = [ordered]@{ t = $t0.ToString('s'); battery_pct = [math]::Round($ps.BatteryLifePercent * 100) }

if ($ps.PowerLineStatus -eq 'Offline') {
    # on battery: did the charger come back by itself? (a cut-out under load, not an unplug)
    $back = $null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep 1
        if ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Online') { $back = Get-Date; break }
    }
    if ($back) { $ev.kind = 'charger_dropout'; $ev.seconds_on_battery = [math]::Round(($back - $t0).TotalSeconds, 1) }
    else { $ev.kind = 'on_battery' }
} else { $ev.kind = 'on_charger' }
foreach ($k in $load.Keys) { $ev[$k] = $load[$k] }
Add-Content (Join-Path $dir ($t0.ToString('yyyy-MM-dd') + '.jsonl')) ($ev | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8

if ($ev.kind -eq 'charger_dropout') {
    $stampFile = Join-Path $dir '.last-dropout-popup'
    $recent = (Test-Path $stampFile) -and ((Get-Date) - (Get-Item $stampFile).LastWriteTime).TotalMinutes -lt 10
    $today = @(Get-Content (Join-Path $dir ($t0.ToString('yyyy-MM-dd') + '.jsonl')) -EA SilentlyContinue | Where-Object { $_ -match 'charger_dropout' }).Count
    $md = Join-Path $dir ('dropout-' + $t0.ToString('yyyy-MM-dd_HHmmss') + '.md')
    @"
STATUS: ALERT
The charger cut out for $($ev.seconds_on_battery) s at $($t0.ToString('HH:mm:ss')) and the PC ran on battery ($today time(s) today).

Load at that moment: CPU $($ev.cpu_pct)%, GPU 3D $($ev.gpu3d_pct)%
GPU: $($ev.gpu.name) - $($ev.gpu.status) $(if ($ev.gpu.power_w) { "($($ev.gpu.power_w) W, $($ev.gpu.temp_c) C)" })
Bluetooth: $($ev.bluetooth.name) - $($ev.bluetooth.status)
Top CPU: $($ev.top -join ', ')

If this repeats under load: check the charger and its cable/plug, try another outlet or charger,
and consider "power-guard.ps1 -CapTurbo" to lower the load peaks.
"@ | Set-Content $md -Encoding UTF8
    if (-not $recent) {
        Set-Content $stampFile '' -Encoding ascii
        Start-Process conhost.exe -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$root\popup.ps1`" -Report `"$md`""
    }
}
