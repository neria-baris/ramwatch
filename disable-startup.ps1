# disable-startup.ps1 - turn off auto-start apps and set background services to Manual.
# Same effect as Task Manager > Startup apps > Disable (reversible there). Run as Administrator.
# The lists come from startup-config.json (copy startup-config.example.json and edit it).
# -WhatIf: only show what would change.
param([switch]$WhatIf, [string]$Config = (Join-Path $PSScriptRoot 'startup-config.json'))

if (-not (Test-Path $Config)) { throw "No $Config. Copy startup-config.example.json to startup-config.json and list your apps/services." }
$cfg = Get-Content $Config -Raw | ConvertFrom-Json
$apps = @($cfg.run_key_apps)                  # names under ...\CurrentVersion\Run (wildcards allowed)
$startupFolderApps = @($cfg.startup_folder)   # shortcut names in the Startup folders (wildcards allowed)
$services = @($cfg.services_to_manual)        # service names to switch from Automatic to Manual

$disabled = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
$approved = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Disable-Entry($hive, $sub, $name) {
    $key = "${hive}:\$approved\$sub"
    if ($WhatIf) { "would disable: $name  [$hive $sub]"; return }
    if ($hive -eq 'HKLM' -and -not $isAdmin) { Write-Warning "skip (needs admin): $name"; return }
    if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name $name -Value $disabled -Type Binary
    "disabled: $name  [$hive $sub]"
}

# Run-key apps (HKCU/HKLM, 64 and 32 bit)
$runKeys = @(
    @{ Hive = 'HKCU'; Run = 'Software\Microsoft\Windows\CurrentVersion\Run'; Sub = 'Run' },
    @{ Hive = 'HKLM'; Run = 'Software\Microsoft\Windows\CurrentVersion\Run'; Sub = 'Run' },
    @{ Hive = 'HKLM'; Run = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Sub = 'Run32' }
)
foreach ($pattern in $apps) {
    $found = $false
    foreach ($rk in $runKeys) {
        $names = (Get-Item "$($rk.Hive):\$($rk.Run)" -ErrorAction SilentlyContinue).GetValueNames()
        foreach ($n in $names | Where-Object { $_ -like $pattern }) { Disable-Entry $rk.Hive $rk.Sub $n; $found = $true }
    }
    if (-not $found) {
        # app registered itself only in StartupApproved (e.g. Steam/GOG launch via their own key)
        foreach ($hive in 'HKCU', 'HKLM') { foreach ($sub in 'Run', 'Run32') {
            $names = (Get-Item "${hive}:\$approved\$sub" -ErrorAction SilentlyContinue).GetValueNames()
            foreach ($n in $names | Where-Object { $_ -like $pattern }) { Disable-Entry $hive $sub $n; $found = $true }
        } }
    }
    if (-not $found) { "not found: $pattern" }
}

# Startup-folder shortcuts
$folders = @(
    @{ Hive = 'HKCU'; Path = [Environment]::GetFolderPath('Startup') },
    @{ Hive = 'HKLM'; Path = [Environment]::GetFolderPath('CommonStartup') }
)
foreach ($pattern in $startupFolderApps) {
    foreach ($f in $folders) {
        Get-ChildItem $f.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $pattern } |
            ForEach-Object { Disable-Entry $f.Hive 'StartupFolder' $_.Name }
    }
}

# Services -> Manual (they still start if an app needs them)
foreach ($s in $services) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if (-not $svc) { "service not found: $s"; continue }
    if ($WhatIf) { "would set Manual + stop: $s ($($svc.StartType), $($svc.Status))"; continue }
    if (-not $isAdmin) { Write-Warning "skip service (needs admin): $s"; continue }
    try {
        Set-Service -Name $s -StartupType Manual -ErrorAction Stop
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        "service set to Manual: $s"
    } catch { Write-Warning "failed: $s - $($_.Exception.Message)" }
}
