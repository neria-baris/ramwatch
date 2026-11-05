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
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'RamWatch' -and $_.CommandLine -notmatch 'popup\.ps1' -and $_.CreationDate -lt (Get-Date).AddMinutes(-20) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
$reportDir = Join-Path $root 'reports'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
if (-not $Node) { $Node = 'node' }

# ---------- collect ----------
. (Join-Path $root 'collect.ps1')
$snapshot = Get-RamSnapshot
$snapshot.health = Get-HealthSample -Since (Get-Date).AddHours(-24)
$dailyFile = Get-ChildItem (Join-Path $root 'daily') -Filter '*.json' -EA SilentlyContinue | Sort-Object Name | Select-Object -Last 1
if ($dailyFile) { $snapshot.daily = Get-Content $dailyFile.FullName -Raw | ConvertFrom-Json }
# charger/battery switches from the last 24 h (power-event.ps1)
$since = (Get-Date).AddHours(-24)
$pe = @(Get-ChildItem (Join-Path $root 'power-events') -Filter '*.jsonl' -EA SilentlyContinue | Sort-Object Name | Select-Object -Last 2 |
    ForEach-Object { Get-Content $_.FullName } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { [datetime]$_.t -gt $since })
if ($pe) { $snapshot.power_switches_24h = $pe | Select-Object -Last 30 }
if ($Trigger) { $snapshot.local_triggers = $Trigger }
$json = $snapshot | ConvertTo-Json -Depth 5 -Compress
$snapPath = Join-Path $reportDir "$stamp.snapshot.json"
[IO.File]::WriteAllText($snapPath, $json, (New-Object Text.UTF8Encoding $false))

# ---------- ask the model (Sign in with ChatGPT) ----------
$outPath = Join-Path $reportDir "$stamp.answer.txt"
$log = & $Node (Join-Path $root 'ram-watch.mjs') review $snapPath $outPath 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outPath)) {
    $text = "STATUS: ALERT`nRAM watch could not reach ChatGPT: $($log.Trim())`nTo reconnect run: `"$Node`" `"$(Join-Path $root 'ram-watch.mjs')`" login"
} else {
    $text = [IO.File]::ReadAllText($outPath, [Text.Encoding]::UTF8)
    Remove-Item $outPath -Force
}
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
