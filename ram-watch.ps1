# ram-watch.ps1 - RAM/health snapshot (10:00, 20:00, or on a monitor trigger), reviewed by an OpenAI model via "Sign in with ChatGPT" (no API key).
# The model call lives in ram-watch.mjs (needs Node 22+). Reports go to .\reports\.
param(
    [string]$Node = (Get-Content (Join-Path $PSScriptRoot 'node-path.txt') -ErrorAction SilentlyContinue | Select-Object -First 1),
    [switch]$NoNotify,
    [string[]]$Trigger   # set by ram-monitor.ps1 when a local rule fired
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
# watchdog: never let an older RamWatch run linger (a hung WMI/event-log call, a stuck node child)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='node.exe' OR Name='gh.exe'" -EA SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'RamWatch' -and $_.CommandLine -notmatch 'popup\.ps1|run-in-job\.ps1' -and $_.CreationDate -lt (Get-Date).AddMinutes(-20) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
$reportDir = Join-Path $root 'reports'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
if (-not $Node) { $Node = 'node' }
# A review that could not run because the PC was offline waits in pending.json - no popup - and runs, with fresh
# data, once the network is back (ram-monitor.ps1 checks every 15 minutes).
$pendingPath = Join-Path $root 'pending.json'
$queued = $null
if (Test-Path $pendingPath) { try { $queued = Get-Content $pendingPath -Raw | ConvertFrom-Json } catch { } }
$ownTrigger = @($Trigger | Where-Object { $_ })
if ($queued) { $Trigger = @($ownTrigger) + @($queued.triggers | Where-Object { $_ } | ForEach-Object { "(found while offline, since $($queued.since)) $_" }) }
function Save-Pending([string]$why) {
    $all = @(@($queued.triggers) + $ownTrigger | Where-Object { $_ } | Select-Object -Unique | Select-Object -Last 20)
    $o = [ordered]@{ since = $(if ($queued.since) { $queued.since } else { (Get-Date).ToString('s') }); last_try = (Get-Date).ToString('s'); reason = $why; triggers = $all }
    [IO.File]::WriteAllText($pendingPath, ($o | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding $false))
    Write-Output "STATUS: PENDING - $why; the review is queued in pending.json and runs once the PC is online"
}

# ---------- collect ----------
. (Join-Path $root 'collect.ps1')
if (-not (Test-Online)) { Save-Pending 'no network'; return }
$snapshot = Get-RamSnapshot
$snapshot.health = Get-HealthSample -Since (Get-Date).AddHours(-24)
$dailyFile = Get-ChildItem (Join-Path $root 'daily') -Filter '*.json' -EA SilentlyContinue | Sort-Object Name | Select-Object -Last 1
if ($dailyFile) {
    $snapshot.daily = Get-Content $dailyFile.FullName -Raw | ConvertFrom-Json
    # The daily file can be up to a day old (or from before a reboot / driver fix). Never let the model alert on
    # stale data: re-measure the battery now (~5 s) and say how old the rest of the daily section is.
    $taken = try { [datetime]$snapshot.daily.taken_at } catch { $dailyFile.LastWriteTime }
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if (((Get-Date) - $taken).TotalHours -gt 3 -or $taken -lt $boot) {
        $snapshot.daily | Add-Member -NotePropertyName battery -NotePropertyValue (Get-BatteryHealth) -Force
        $snapshot.daily | Add-Member -NotePropertyName freshness -NotePropertyValue ("battery re-measured now; everything else in 'daily' is from $($taken.ToString('s'))" + $(if ($taken -lt $boot) { ', before the last boot' })) -Force
    }
}
# Alerts already shown in the last 48 h: the model reports a known, unchanged problem without a new ALERT.
# (Failed reviews are left out - they say nothing about the PC.)
$prev = @(Get-ChildItem $reportDir -Filter '*.md' -EA SilentlyContinue | Where-Object LastWriteTime -gt (Get-Date).AddHours(-48) |
    Sort-Object LastWriteTime | ForEach-Object {
        $t = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
        if ($t -match 'STATUS:\s*ALERT' -and $t -notmatch 'model review failed|not connected to ChatGPT|could not reach ChatGPT') {
            [ordered]@{ at = $_.LastWriteTime.ToString('s'); report = $(if ($t.Length -gt 1500) { $t.Substring(0, 1500) + '...' } else { $t }) }
        }
    } | Select-Object -Last 3)
if ($prev) { $snapshot.previous_alerts = $prev }
if ($Trigger) { $snapshot.local_triggers = $Trigger }
$json = $snapshot | ConvertTo-Json -Depth 5 -Compress
$snapPath = Join-Path $reportDir "$stamp.snapshot.json"
[IO.File]::WriteAllText($snapPath, $json, (New-Object Text.UTF8Encoding $false))

# ---------- ask the model (Sign in with ChatGPT) ----------
$outPath = Join-Path $reportDir "$stamp.answer.txt"
function Invoke-Review {
    # Continue: under Stop, Windows PowerShell 5.1 turns node's stderr (its error message) into an exception and the run died
    $ErrorActionPreference = 'Continue'
    $script:log = & $Node (Join-Path $root 'ram-watch.mjs') review $snapPath $outPath 2>&1 | ForEach-Object { "$_" } | Out-String
    $LASTEXITCODE -eq 0 -and (Test-Path $outPath)
}
$ok = Invoke-Review
$signedOut = $log -match 'Not connected to ChatGPT|unauthori|\b401\b'
if (-not $ok -and -not $signedOut) { Start-Sleep 60; $ok = Invoke-Review }   # one retry: network blip, API hiccup, busy PC
if (-not $ok -and -not $signedOut -and ($log -match 'fetch failed|ENOTFOUND|EAI_AGAIN|getaddrinfo|ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENETUNREACH|EHOSTUNREACH|socket hang up|UND_ERR' -or -not (Test-Online))) {
    Remove-Item $snapPath -Force -EA SilentlyContinue
    Save-Pending 'network lost during the review'; return
}
if (-not $ok) {
    $reason = if ($log.Trim()) { $log.Trim() } else { 'no answer - the call was interrupted (e.g. the PC was overloaded and the watchdog stopped it)' }
    $text = if ($signedOut) {
        "STATUS: ALERT`nRAM watch is not connected to ChatGPT: $reason`nTo reconnect run: `"$Node`" `"$(Join-Path $root 'ram-watch.mjs')`" login"
    } elseif ($Trigger) {
        # the local rules saw something real; show it unreviewed rather than lose it
        "STATUS: ALERT`nThe model review failed ($reason), so these local findings are shown unreviewed:`n" + (($Trigger | ForEach-Object { "- $_" }) -join "`n")
    } else {
        # scheduled run, nothing fired locally: no popup, the next run tries again
        "STATUS: ERROR`nThe scheduled model review failed ($reason). No local rule had fired; the next run tries again."
    }
} else {
    $text = [IO.File]::ReadAllText($outPath, [Text.Encoding]::UTF8)
    Remove-Item $outPath -Force
}
Remove-Item $pendingPath -Force -EA SilentlyContinue   # anything queued is in this report now
$model = if ($log -match 'model=(\S+)') { $Matches[1] } else { 'n/a' }
$why = if ($Trigger) { "monitor trigger: " + ($Trigger -join '; ') } else { 'scheduled' }

$reportPath = Join-Path $reportDir "$stamp.md"
"# RAM watch $stamp`n`n$text`n`n---`nmodel: $model | run: $why" | Out-File -Encoding utf8 $reportPath
Copy-Item $reportPath (Join-Path $root 'latest.md') -Force

# uploaded files are pruned after 7 days by github-sync.ps1; this is only a fallback
Get-ChildItem $reportDir -File | Where-Object LastWriteTime -lt (Get-Date).AddDays(-30) | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Output $text

# ---------- notify on ALERT ----------
# A top-most window rather than a toast, so it also shows in Do Not Disturb / Focus.
# Started detached so this run (and the 15-min monitor) finishes while the window waits for you.
if (-not $NoNotify -and $text -match '^\s*STATUS:\s*ALERT') {
    # conhost --headless hides the console without -WindowStyle Hidden, which Windows would also apply to the popup itself
    Start-Process conhost.exe -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$root\popup.ps1`" -Report `"$reportPath`""
}
