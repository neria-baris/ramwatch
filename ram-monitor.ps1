# ram-monitor.ps1 - runs every 15 minutes. Local rules only (no model call):
# records a compact health line to metrics\<date>.jsonl, and when a rule fires
# escalates to ram-watch.ps1 (ChatGPT review + notification). Pushes data to GitHub hourly.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
# Task Scheduler starts tasks below normal priority; under a long full-CPU load the check then never got to run,
# which is exactly when it matters. It is short (~10 s), so normal priority costs nothing.
try { (Get-Process -Id $PID).PriorityClass = 'Normal' } catch { }
# watchdog: never let an older RamWatch run linger (a hung WMI/event-log call, a stuck node child)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='node.exe' OR Name='gh.exe'" -EA SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'RamWatch' -and $_.CommandLine -notmatch 'popup\.ps1' -and $_.CreationDate -lt (Get-Date).AddMinutes(-20) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
. (Join-Path $root 'collect.ps1')
. (Join-Path $root 'github-sync.ps1')

# ---- thresholds ----
$RamLowGB        = 3      # available RAM below this
$CommitHighPct   = 85     # commit charge vs limit
$NonPagedHighMB  = 1500   # kernel non-paged pool
$ZombiesHigh     = 10     # processes that exited but are still alive
$HeadlessHigh    = 10     # headless browser processes in one family
$BigOldMB        = 4096   # single process private memory ...
$BigOldHours     = 24     # ... older than this
$HotC            = 90     # thermal zone temperature
# per-machine overrides, e.g. {"NonPagedHighMB": 2600} when an antivirus legitimately allocates a big pool at boot
$ovPath = Join-Path $root 'thresholds.json'
if (Test-Path $ovPath) { (Get-Content $ovPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { Set-Variable -Name $_.Name -Value $_.Value } }

$statePath = Join-Path $root 'state.json'
function ConvertTo-Hash($o) {
    if ($o -is [System.Management.Automation.PSCustomObject]) { $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }; return $h }
    if ($o -is [array]) { return @($o | ForEach-Object { ConvertTo-Hash $_ }) }
    $o
}
$state = @{}
if (Test-Path $statePath) { try { $state = ConvertTo-Hash (Get-Content $statePath -Raw | ConvertFrom-Json) } catch { $state = @{} } }
foreach ($k in 'cooldown', 'uploaded', 'devices') { if (-not $state[$k]) { $state[$k] = @{} } }

$now = Get-Date
$since = if ($state.last_sample) { [datetime]$state.last_sample } else { $now.AddMinutes(-15) }
$snap = Get-RamSnapshot
$health = Get-HealthSample -Since $since

# ---- compact metrics line ----
$wlanext = Get-Process wlanext -EA SilentlyContinue | Select-Object -First 1
$line = [ordered]@{
    t = $now.ToString('s'); uptime_h = $snap.uptime_h
    ram_avail_gb = $snap.ram_available_gb; commit_gb = $snap.commit_used_gb; commit_limit_gb = $snap.commit_limit_gb
    nonpaged_mb = $snap.nonpaged_pool_mb
    pool_top = @($snap.kernel_pool_top_tags | Select-Object -First 3 | ForEach-Object { "$($_.tag.Trim()):$([math]::Round($_.nonpaged_mb))MB" })
    wlanext_mb = if ($wlanext) { [math]::Round($wlanext.PrivateMemorySize64 / 1MB) } else { $null }
    zombies = $snap.exited_but_alive_total; procs = $snap.process_count
    big = @($snap.big_processes | ForEach-Object { "$($_.name):$($_.private_mb)MB/$($_.age_h)h" })
    ac = $health.ac; battery_pct = $health.battery_pct; battery_state = $health.battery_state; c_free_gb = $health.c_free_gb
    thermal_c = @($health.thermal | ForEach-Object { $_.c }); throttle = @($health.thermal | ForEach-Object { $_.throttle })
    gpu = $health.gpu; bluetooth = $health.bluetooth; wifi = $health.wifi.status
    events = $health.events
}
$metricsDir = Join-Path $root 'metrics'; New-Item -ItemType Directory -Force $metricsDir | Out-Null
Add-Content -Path (Join-Path $metricsDir ($now.ToString('yyyy-MM-dd') + '.jsonl')) -Value ($line | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8

# ---- rules: key, cooldown hours, description ----
$fired = New-Object System.Collections.Generic.List[object]
function Fire($key, $hours, $why) { $fired.Add([pscustomobject]@{ key = $key; hours = $hours; why = $why }) }

if ($snap.ram_available_gb -lt $RamLowGB) { Fire 'ram_low' 3 "available RAM $($snap.ram_available_gb) GB" }
if ($health.c_free_gb -lt 15) { Fire 'c_low' 12 "drive C: only $($health.c_free_gb) GB free" }
$commitPct = [math]::Round(100 * $snap.commit_used_gb / $snap.commit_limit_gb)
if ($commitPct -ge $CommitHighPct) { Fire 'commit_high' 3 "commit $commitPct% of limit" }
if ($snap.nonpaged_pool_mb -ge $NonPagedHighMB) { Fire 'nonpaged_high' 24 "non-paged pool $($snap.nonpaged_pool_mb) MB" }
if ($snap.exited_but_alive_total -ge $ZombiesHigh) { Fire 'zombies' 24 "$($snap.exited_but_alive_total) processes exited but still alive" }
foreach ($f in $snap.repeated_process_families | Where-Object { $_.flags -match '--headless' -and $_.count -ge $HeadlessHigh }) {
    Fire "headless:$($f.name)" 12 "$($f.count) headless $($f.name) processes ($($f.private_mb) MB, $($f.orphaned) orphaned)"
}
foreach ($b in $snap.big_processes | Where-Object { $_.private_mb -ge $BigOldMB -and $_.age_h -ge $BigOldHours }) {
    Fire "big_old:$($b.name)" 24 "$($b.name) holds $($b.private_mb) MB after $($b.age_h) h"
}
foreach ($z in $health.thermal | Where-Object { $_.c -ge $HotC -or $_.throttle -ne 0 }) { Fire "hot:$($z.zone)" 6 "thermal zone $($z.zone) at $($z.c) C, throttle=$($z.throttle)" }
foreach ($e in $health.events) {
    $crash = (($e.src -eq 'Microsoft-Windows-Kernel-Power' -and $e.id -eq 41) -or
              ($e.src -eq 'EventLog' -and $e.id -eq 6008) -or
              ($e.src -in 'Microsoft-Windows-WER-SystemErrorReporting', 'nvlddmkm', 'Display', 'Microsoft-Windows-WHEA-Logger') -or
              (($e.src -like 'Bth*' -or $e.src -eq 'BTHUSB') -and ($e.level -in 'Error', 'Critical')))
    if ($crash) { Fire "event:$($e.src):$($e.id)" 1 "$($e.t) $($e.src) $($e.id): $($e.msg)" }
}
foreach ($dev in 'gpu', 'bluetooth') {
    $cur = "$($health[$dev].status)/$($health[$dev].problem)"
    if ($state.devices[$dev] -and $state.devices[$dev] -ne $cur) { Fire "device:$dev`:$cur" 0 "$dev changed: $($state.devices[$dev]) -> $cur" }
    $state.devices[$dev] = $cur
}

$due = @($fired | Where-Object { -not $state.cooldown[$_.key] -or ($now - [datetime]$state.cooldown[$_.key]).TotalHours -ge $_.hours })
if ($due.Count) {
    foreach ($d in $due) { $state.cooldown[$d.key] = $now.ToString('s') }
    & (Join-Path $root 'ram-watch.ps1') -Trigger @($due | ForEach-Object { $_.why }) | Out-Null
} elseif ((Test-Path (Join-Path $root 'pending.json')) -and (Test-Online)) {
    # a review queued while the PC was offline: run it now that the network is back
    & (Join-Path $root 'ram-watch.ps1') | Out-Null; $ranQueued = $true
}

# ---- hourly GitHub push (also right after an escalation) ----
$sync = ''
if ($due.Count -or $ranQueued -or -not $state.last_push -or ($now - [datetime]$state.last_push).TotalMinutes -ge 55) {
    try { $sync = Sync-RamWatchData $root $state; $state.last_push = $now.ToString('s') } catch { $sync = "sync error: $($_.Exception.Message)" }
}

foreach ($k in @($state.cooldown.Keys)) { if (($now - [datetime]$state.cooldown[$k]).TotalDays -gt 7) { $state.cooldown.Remove($k) } }
$state.last_sample = $now.ToString('s')
[IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))

$logLine = "$($now.ToString('s')) fired=$($fired.Count) escalated=$($due.Count)$(if ($ranQueued) { ' queued-review=ran' }) $sync"
Add-Content (Join-Path $root 'monitor.log') $logLine
if ((Get-Item (Join-Path $root 'monitor.log')).Length -gt 200KB) { Get-Content (Join-Path $root 'monitor.log') -Tail 500 | Set-Content (Join-Path $root 'monitor.log') }
$logLine
