# daily.ps1 - once a day (09:45): slower health data - battery, drivers, reliability, updates, disks, log reach.
# Saves daily\<date>.json (uploaded to GitHub by the monitor) and escalates to ram-watch.ps1 when something changed.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'collect.ps1')

$dir = Join-Path $root 'daily'; New-Item -ItemType Directory -Force $dir | Out-Null
$prevFile = Get-ChildItem $dir -Filter '*.json' -EA SilentlyContinue | Sort-Object Name | Select-Object -Last 1
$prev = if ($prevFile) { Get-Content $prevFile.FullName -Raw | ConvertFrom-Json } else { $null }

$day = Get-DailyHealth $root
$path = Join-Path $dir "$($day.date).json"
[IO.File]::WriteAllText($path, ($day | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))

# ---- what is worth a ChatGPT review + popup ----
$why = @()
if ($day.drivers.changes) { $why += "driver changes since yesterday: " + ($day.drivers.changes -join '; ') }
if ($prev -and $prev.battery.responsive -ne $day.battery.responsive) { $why += "battery query responsiveness changed: $($prev.battery.responsive) -> $($day.battery.responsive)" }
if ($day.battery.health_pct -and $day.battery.health_pct -lt 60) { $why += "battery health $($day.battery.health_pct)% of design capacity" }
if ($prev -and $prev.battery.health_pct -and $day.battery.health_pct -and ($prev.battery.health_pct - $day.battery.health_pct) -ge 3) {
    $why += "battery capacity dropped $($prev.battery.health_pct)% -> $($day.battery.health_pct)% in a day (check for swelling)"
}
foreach ($d in $day.disks | Where-Object { $_.health -ne 'Healthy' }) { $why += "disk $($d.name) health: $($d.health)" }
foreach ($c in @($day.disk_counters)) {
    if ($c.wear -ge 80 -or $c.read_errors -gt 0 -or $c.temp_c -ge 70) { $why += "disk $($c.name): wear $($c.wear)%, read errors $($c.read_errors), $($c.temp_c) C" }
}
$crashes = @($day.reliability | Where-Object { $_ -isnot [string] -and $_.source -match 'Windows Error Reporting|Application Error|Application Hang|Microsoft-Windows-WER' })
if ($crashes.Count -ge 3) { $why += "$($crashes.Count) app crashes/hangs in 24h" }

if ($why.Count) { & (Join-Path $root 'ram-watch.ps1') -Trigger $why | Out-Null }
"daily saved: $path; escalated: $($why.Count)"
