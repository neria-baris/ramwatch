# setup.ps1 - install RamWatch for the current user (no Administrator needed). Safe to run again.
#   1. finds Node.js 22+  2. fetches + builds OpenAI's Sign-in-with-ChatGPT DevKit (@siwc/local) and enables
#   reasoning effort in it  3. registers the scheduled tasks  4. opens the ChatGPT sign-in.
# Options:
#   -Node <path to node.exe>       use this Node 22+ instead of searching
#   -GitHubRepo <owner/name>       also back data up to this (private) GitHub repo via the gh CLI
#   -Uninstall                     remove the scheduled tasks (files and data stay)
param([string]$Node, [string]$GitHubRepo, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$tasks = 'RamWatch', 'RamWatchMonitor', 'RamWatchDaily'

if ($Uninstall) {
    foreach ($t in $tasks) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -EA SilentlyContinue }
    'Scheduled tasks removed.'; return
}

# ---- 1. Node.js 22+ ----
function Test-Node([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe)) { return $false }
    $v = & $exe --version 2>$null
    $v -match '^v(\d+)\.' -and [int]$Matches[1] -ge 22
}
if (-not $Node) {
    $cands = @((Get-Command node -EA SilentlyContinue).Source) +
             @(Get-ChildItem "$env:LOCALAPPDATA\nvm", "$env:APPDATA\nvm", 'C:\nvm4w' -Directory -Filter 'v2*' -EA SilentlyContinue |
               Sort-Object { [version]($_.Name.TrimStart('v')) } -Descending | ForEach-Object { Join-Path $_.FullName 'node.exe' })
    $Node = $cands | Where-Object { Test-Node $_ } | Select-Object -First 1
}
if (-not (Test-Node $Node)) { throw 'Node.js 22 or newer is required (e.g. "nvm install 22"), or pass -Node <path to node.exe>.' }
Set-Content (Join-Path $root 'node-path.txt') $Node -Encoding ascii
"Node: $Node ($(& $Node --version))"
$npm = Join-Path (Split-Path $Node) 'npm.cmd'
$env:Path = "$(Split-Path $Node);$env:Path"

# ---- 2. Sign in with ChatGPT DevKit (OpenAI, noncommercial license - fetched, not bundled) ----
$kit = Join-Path $root 'siwc-devkit'
$commit = '0a36fefeb913055c8c7a1a29b63d82b96b2e841a'   # version this was tested with
if (-not (Test-Path (Join-Path $kit 'packages\local\dist\index.js'))) {
    if (-not (Test-Path $kit)) {
        git clone --quiet https://github.com/openai/sign-in-with-chatgpt-devkit.git $kit
        git -C $kit -c advice.detachedHead=false checkout --quiet $commit
    }
    Push-Location $kit
    try {
        & $npm ci --workspace '@siwc/local' --include-workspace-root --no-audit --no-fund
        if ($LASTEXITCODE) { throw 'npm ci failed (antivirus locking node_modules? delete siwc-devkit\node_modules and retry)' }
        & $npm run build -w '@siwc/local'
        if ($LASTEXITCODE) { throw 'DevKit build failed' }
    } finally { Pop-Location }
}
# Local change: let requests pass a reasoning effort (and allow it more time). Marked in the file.
$resp = Join-Path $kit 'packages\local\dist\responses.js'
$js = Get-Content $resp -Raw
if ($js -notmatch 'reasoningEffort') {
    $js = $js.Replace('const requestSignal = AbortSignal.any([signal, AbortSignal.timeout(180_000)]);',
        "// RamWatch local change: optional reasoning effort, with a longer deadline for it.`n    const requestSignal = AbortSignal.any([signal, AbortSignal.timeout(options.reasoningEffort ? 600_000 : 180_000)]);")
    $js = $js.Replace('...(options.instructions !== undefined ? { instructions: options.instructions } : {}),',
        "...(options.instructions !== undefined ? { instructions: options.instructions } : {}),`n            ...(options.reasoningEffort ? { reasoning: { effort: options.reasoningEffort } } : {}),")
    if ($js -notmatch 'reasoningEffort') { Write-Warning 'Could not enable reasoning effort in the DevKit (it changed?) - RamWatch still works without it.' }
    else { [IO.File]::WriteAllText($resp, $js) }
}
'DevKit ready.'

# ---- 3. scheduled tasks (hidden: conhost --headless, never two copies at once) ----
function Act($script) { New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$root\$script`"" }
function New-TaskSettings([int]$minutes) { New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes $minutes) -MultipleInstances IgnoreNew }
Register-ScheduledTask -TaskName 'RamWatch' -Action (Act 'ram-watch.ps1') -Settings (New-TaskSettings 15) -Force `
    -Trigger @((New-ScheduledTaskTrigger -Daily -At 10:00), (New-ScheduledTaskTrigger -Daily -At 20:00)) -Description 'RamWatch: ChatGPT review at 10:00 and 20:00' | Out-Null
Register-ScheduledTask -TaskName 'RamWatchMonitor' -Action (Act 'ram-monitor.ps1') -Settings (New-TaskSettings 15) -Force `
    -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 15)) -Description 'RamWatch: local checks every 15 min' | Out-Null
Register-ScheduledTask -TaskName 'RamWatchDaily' -Action (Act 'daily.ps1') -Settings (New-TaskSettings 20) -Force `
    -Trigger (New-ScheduledTaskTrigger -Daily -At 09:45) -Description 'RamWatch: daily battery/driver/reliability/disk health' | Out-Null
"Scheduled tasks: $($tasks -join ', ')"

# ---- optional GitHub backup ----
if ($GitHubRepo) {
    $gh = (Get-Command gh -EA SilentlyContinue).Source
    if (-not $gh) { throw 'GitHub CLI (gh) is required for -GitHubRepo. Install it and run "gh auth login".' }
    & $gh repo view $GitHubRepo 2>$null | Out-Null
    if ($LASTEXITCODE) { & $gh repo create $GitHubRepo --private --description 'RamWatch data' | Out-Null }
    Set-Content (Join-Path $root 'github-repo.txt') $GitHubRepo -Encoding ascii
    "GitHub backup: $GitHubRepo (private)"
}

# ---- 4. sign in ----
'Opening the browser for Sign in with ChatGPT...'
& $Node (Join-Path $root 'ram-watch.mjs') login
''
'Next (optional): copy machine-notes.example.txt to machine-notes.txt, and run setup-admin.ps1 as Administrator.'
