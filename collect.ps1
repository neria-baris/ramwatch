# collect.ps1 - shared RAM snapshot collection (dot-sourced by ram-watch.ps1 and ram-monitor.ps1).

function Redact([string]$s) {
    $s = $s -replace '(sk-[A-Za-z0-9_\-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|eyJ[A-Za-z0-9_\-\.]{20,})', '<redacted>'
    $s -replace '(?i)((?:token|key|secret|password|pwd)[=:])\S+', '$1<redacted>'
}
# exe name + flags (values stripped) + script file, never full arguments
function Summarize-Cmd([string]$cmd) {
    if (-not $cmd) { return '' }
    $parts = [regex]::Matches($cmd, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') }
    $out = foreach ($p in ($parts | Select-Object -Skip 1)) {
        if ($p -match '^--?([A-Za-z0-9\-]+)') { '--' + $Matches[1] }
        elseif ($p -match '\.(py|js|ts|mjs|ps1|bat|cmd|jar)$') { Split-Path $p -Leaf }
    }
    Redact ((($out | Select-Object -Unique) -join ' '))
}

function Get-PoolTags {
    if (-not ('RwPool' -as [type])) {
        Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class RwPool {
  [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int c, IntPtr b, int l, out int r);
  public static object[] Get() {
    int len = 1 << 20, ret, st; IntPtr buf;
    while (true) { buf = Marshal.AllocHGlobal(len); st = NtQuerySystemInformation(22, buf, len, out ret);
      if (st == unchecked((int)0xC0000004)) { Marshal.FreeHGlobal(buf); len = Math.Max(ret, len * 2); continue; } break; }
    if (st != 0) { Marshal.FreeHGlobal(buf); throw new Exception("NTSTATUS " + st); }
    int n = Marshal.ReadInt32(buf); var res = new object[n];
    for (int i = 0, o = 8; i < n; i++, o += 40) { IntPtr p = IntPtr.Add(buf, o); var t = new byte[4]; Marshal.Copy(p, t, 0, 4);
      res[i] = new object[] { System.Text.Encoding.ASCII.GetString(t), Marshal.ReadInt64(p, 32), (long)(uint)Marshal.ReadInt32(p, 24) - (uint)Marshal.ReadInt32(p, 28), Marshal.ReadInt64(p, 16) }; }
    Marshal.FreeHGlobal(buf); return res; } }
"@
    }
    [RwPool]::Get() | ForEach-Object { [pscustomobject]@{ tag = $_[0]; nonpaged_mb = [math]::Round($_[1] / 1MB, 1); np_outstanding = $_[2]; paged_mb = [math]::Round($_[3] / 1MB, 1) } } |
        Sort-Object nonpaged_mb -Descending | Select-Object -First 12
}

function Get-RamSnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $now = Get-Date
    $cim = Get-CimInstance Win32_Process
    $byPid = @{}; foreach ($c in $cim) { $byPid[[int]$c.ProcessId] = $c }
    $gp = @{}; foreach ($p in Get-Process) { $gp[$p.Id] = $p }

    $procs = foreach ($c in $cim) {
        $p = $gp[[int]$c.ProcessId]
        $parent = $byPid[[int]$c.ParentProcessId]
        $orphan = (-not $parent) -or ($parent.CreationDate -gt $c.CreationDate)
        $exited = $false; try { if ($p) { $exited = $p.HasExited } } catch {}
        [pscustomobject]@{
            Name = $c.Name; Id = $c.ProcessId
            WS = if ($p) { $p.WorkingSet64 } else { 0 }
            Priv = [double]$c.PrivatePageCount
            AgeH = if ($c.CreationDate) { [math]::Round(($now - $c.CreationDate).TotalHours, 1) } else { $null }
            Orphan = $orphan; Exited = $exited
            Flags = Summarize-Cmd $c.CommandLine
        }
    }
    $system = 'System', 'Registry', 'smss.exe', 'csrss.exe', 'wininit.exe', 'winlogon.exe', 'services.exe', 'lsass.exe', 'explorer.exe', 'Memory Compression', 'Secure System'

    $groups = $procs | Group-Object Name | ForEach-Object {
        [pscustomobject]@{
            name = $_.Name; count = $_.Count
            ws_mb = [math]::Round(($_.Group | Measure-Object WS -Sum).Sum / 1MB)
            private_mb = [math]::Round(($_.Group | Measure-Object Priv -Sum).Sum / 1MB)
            oldest_h = ($_.Group | Measure-Object AgeH -Maximum).Maximum
            orphaned = @($_.Group | Where-Object Orphan).Count
            exited_but_alive = @($_.Group | Where-Object Exited).Count
        }
    } | Sort-Object private_mb -Descending | Select-Object -First 50

    # process "families": same exe + same flags (e.g. many headless chromes / duplicate servers)
    $families = $procs | Where-Object Flags | Group-Object Name, Flags | Where-Object Count -ge 3 | ForEach-Object {
        [pscustomobject]@{
            name = $_.Group[0].Name; flags = $_.Group[0].Flags; count = $_.Count
            private_mb = [math]::Round(($_.Group | Measure-Object Priv -Sum).Sum / 1MB)
            orphaned = @($_.Group | Where-Object Orphan).Count
            oldest_h = ($_.Group | Measure-Object AgeH -Maximum).Maximum
        }
    } | Sort-Object private_mb -Descending | Select-Object -First 25

    $suspicious = $procs | Where-Object { $_.Exited -or ($_.Orphan -and $_.Priv -gt 100MB -and $_.Name -notin $system) } |
        Sort-Object Priv -Descending | Select-Object -First 30 |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; pid = $_.Id; private_mb = [math]::Round($_.Priv / 1MB); age_h = $_.AgeH; orphan = $_.Orphan; exited_but_alive = $_.Exited; flags = $_.Flags } }

    $big = $procs | Where-Object { $_.Priv -gt 2GB } | Sort-Object Priv -Descending | Select-Object -First 15 |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; pid = $_.Id; private_mb = [math]::Round($_.Priv / 1MB); ws_mb = [math]::Round($_.WS / 1MB); age_h = $_.AgeH; orphan = $_.Orphan; flags = $_.Flags } }

    $poolTop = @(); try { $poolTop = Get-PoolTags } catch {}

    [ordered]@{
        taken_at = $now.ToString('s')
        uptime_h = [math]::Round(($now - $os.LastBootUpTime).TotalHours, 1)
        ram_total_gb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        ram_available_gb = [math]::Round($pm.AvailableBytes / 1GB, 1)
        commit_used_gb = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1)
        commit_limit_gb = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1)
        nonpaged_pool_mb = [math]::Round($pm.PoolNonpagedBytes / 1MB)
        paged_pool_mb = [math]::Round($pm.PoolPagedBytes / 1MB)
        process_count = @($procs).Count
        exited_but_alive_total = @($procs | Where-Object Exited).Count
        big_processes = $big
        top_process_groups = $groups
        repeated_process_families = $families
        suspicious_processes = $suspicious
        kernel_pool_top_tags = $poolTop
    }
}

# ---------- power / thermal / device health (cheap; runs every 15 min) ----------
$script:HealthEventProviders = @(
    'Microsoft-Windows-Kernel-Power',                 # 41 unexpected reboot, 105 AC/battery switch, 172 connectivity
    'EventLog',                                       # 6008 unexpected shutdown
    'Microsoft-Windows-WER-SystemErrorReporting',     # 1001 bugcheck (BSOD)
    'nvlddmkm', 'Display',                            # NVIDIA driver errors / TDR 4101
    'Microsoft-Windows-WHEA-Logger',                  # hardware errors
    'BTHUSB', 'BthEnum', 'BthMini', 'BTHPORT',        # Bluetooth stack
    'Microsoft-Windows-Kernel-PnP',                   # device failed to start / surprise removal
    'User32',                                         # 1074 who/what initiated a shutdown or restart
    'Microsoft-Windows-Power-Troubleshooter'          # 1 resumed from sleep (with wake source)
)
$script:HealthEventIds = @{
    'Microsoft-Windows-Kernel-Power' = 41, 42, 105, 107, 172   # + 42 entering sleep, 107 resumed
    'EventLog' = 6008; 'Microsoft-Windows-Kernel-PnP' = 219, 411; 'User32' = 1074
}

# First present device of $class whose name matches the earliest pattern (patterns in priority order).
function Get-DeviceState([string]$class, [string[]]$patterns, [string[]]$exclude = @()) {
    if (-not $script:PnpCache) { $script:PnpCache = @(Get-PnpDevice -PresentOnly -Class Display, Bluetooth, Net -EA SilentlyContinue) }
    $cands = @($script:PnpCache | Where-Object { $_.Class -eq $class -and $_.FriendlyName } |
        Where-Object { $n = $_.FriendlyName; -not ($exclude | Where-Object { $n -like $_ }) })
    $d = $null
    foreach ($p in $patterns) { $d = $cands | Where-Object FriendlyName -like $p | Select-Object -First 1; if ($d) { break } }
    if (-not $d) { return [ordered]@{ present = $false } }
    [ordered]@{ present = $true; name = $d.FriendlyName; status = "$($d.Status)"; problem = "$($d.Problem)" }
}

function Get-HealthSample([datetime]$Since) {
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    $zones = Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -OperationTimeoutSec 5 -EA SilentlyContinue |
        ForEach-Object { [ordered]@{ zone = $_.Name; c = $_.Temperature - 273; passive_limit_pct = $_.PercentPassiveLimit; throttle = $_.ThrottleReasons } }
    $gpu = Get-DeviceState 'Display' '*NVIDIA*', '*Radeon*', '*Arc*'   # the discrete GPU, if any
    if ($gpu.status -eq 'OK') {
        $smi = & "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=temperature.gpu,power.draw,pstate,utilization.gpu --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $smi) { $v = ($smi -split ',').Trim(); $gpu.temp_c = $v[0]; $gpu.power_w = $v[1]; $gpu.pstate = $v[2]; $gpu.util_pct = $v[3] }
    }
    $events = @()
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $script:HealthEventProviders; StartTime = $Since } -EA Stop |
            Where-Object { -not $script:HealthEventIds.ContainsKey($_.ProviderName) -or $script:HealthEventIds[$_.ProviderName] -contains $_.Id } |
            Select-Object -First 40 | ForEach-Object {
                $msg = ($_.Message -split "`n")[0]
                [ordered]@{ t = $_.TimeCreated.ToString('s'); src = $_.ProviderName; id = $_.Id; level = "$($_.LevelDisplayName)"; msg = $msg.Substring(0, [math]::Min(160, $msg.Length)).Trim() }
            }
    } catch {}
    [ordered]@{
        ac = "$($ps.PowerLineStatus)"
        battery_pct = [math]::Round($ps.BatteryLifePercent * 100)
        battery_state = "$($ps.BatteryChargeStatus)"
        thermal = @($zones)
        gpu = $gpu
        bluetooth = Get-DeviceState 'Bluetooth' '*Wireless Bluetooth*', '*Bluetooth*Adapter*', '*Bluetooth*Radio*', '*Bluetooth*' -exclude 'Microsoft Bluetooth*', 'Bluetooth Device*', '*Enumerator*'
        wifi = Get-DeviceState 'Net' '*Wi-Fi*', '*Wireless*', '*WLAN*', '*802.11*' -exclude '*Wi-Fi Direct*', '*Virtual*'
        c_free_gb = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
        events = @($events)
    }
}
Add-Type -AssemblyName System.Windows.Forms

# ---------- daily health (slower queries; each one is time-boxed in a child process) ----------
# Runs $block in a separate PowerShell job; a hung driver/WMI call is killed after $seconds.
function Invoke-WithTimeout([scriptblock]$block, [int]$seconds, [object[]]$arguments = @()) {
    $job = Start-Job -ScriptBlock $block -ArgumentList $arguments
    if (Wait-Job $job -Timeout $seconds) { $r = Receive-Job $job -EA SilentlyContinue; Remove-Job $job -Force; return [pscustomobject]@{ ok = $true; value = $r } }
    Stop-Job $job -EA SilentlyContinue; Remove-Job $job -Force -EA SilentlyContinue
    [pscustomobject]@{ ok = $false; value = $null }
}

function Get-DailyHealth([string]$root) {
    $day = [ordered]@{ date = (Get-Date).ToString('yyyy-MM-dd'); taken_at = (Get-Date).ToString('s') }

    # battery: capacity / wear / cycles. Known to hang on this machine, so record responsiveness too.
    $batStart = Get-Date
    # A hung battery query leaves powercfg stuck in the kernel (unkillable until the driver answers or a reboot).
    # Never add another one on top of it.
    $stuck = @(Get-Process powercfg -EA SilentlyContinue)
    $bat = if ($stuck.Count) { [pscustomobject]@{ ok = $false; value = $null; stuck = $true } } else { Invoke-WithTimeout {
        $x = Join-Path $env:TEMP 'ramwatch-battery.xml'
        powercfg /batteryreport /xml /output $x | Out-Null
        [xml]$b = Get-Content $x -Raw; Remove-Item $x -Force -EA SilentlyContinue
        $bt = $b.BatteryReport.Batteries.Battery | Select-Object -First 1
        [ordered]@{ design_mwh = [int]$bt.DesignCapacity; full_mwh = [int]$bt.FullChargeCapacity; cycles = [int]$bt.CycleCount; chemistry = "$($bt.Chemistry)"; id = "$($bt.Id)" }
    } 30 }
    $day.battery = if ($bat.ok -and $bat.value) {
        $v = $bat.value
        $o = [ordered]@{ responsive = $true; design_mwh = $v.design_mwh; full_mwh = $v.full_mwh; cycles = $v.cycles; chemistry = $v.chemistry; id = $v.id }
        if ($v.design_mwh) { $o.health_pct = [math]::Round(100 * $v.full_mwh / $v.design_mwh) }
        $o
    } elseif ($bat.stuck) {
        [ordered]@{ responsive = $false; note = "skipped: an earlier battery query is still stuck in the driver since $($stuck[0].StartTime.ToString('s'))" }
    } else { [ordered]@{ responsive = $false; note = 'battery report did not answer within 30s (driver/EC hang)' } }
    # the job is gone, but a hung powercfg child would stay behind - don't leave our own leftovers
    Get-Process powercfg -EA SilentlyContinue | Where-Object { $_.StartTime -ge $batStart } | Stop-Process -Force -EA SilentlyContinue
    $day.battery.driver = (Get-PnpDevice -Class Battery -EA SilentlyContinue | Where-Object FriendlyName -like '*Battery*' | Select-Object -First 1).FriendlyName

    # driver inventory + what changed since the previous day
    $drv = Invoke-WithTimeout {
        Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -and $_.InfName } |
            ForEach-Object { [pscustomobject]@{ Device = $_.DeviceName; Version = $_.DriverVersion; Date = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { '' }; Provider = $_.DriverProviderName; Inf = $_.InfName } } |
            Sort-Object Device, Inf -Unique
    } 120
    if ($drv.ok -and $drv.value) {
        $dir = Join-Path $root 'drivers'; New-Item -ItemType Directory -Force $dir | Out-Null
        $latest = Join-Path $dir 'latest.csv'
        $prev = if (Test-Path $latest) { @(Import-Csv $latest) } else { @() }
        $cur = @($drv.value | Select-Object Device, Version, Date, Provider, Inf)
        $changes = @()
        if ($prev.Count) {
            $pk = @{}; foreach ($p in $prev) { $pk["$($p.Device)|$($p.Inf)"] = $p }
            $ck = @{}; foreach ($c in $cur) { $ck["$($c.Device)|$($c.Inf)"] = $c }
            foreach ($k in $ck.Keys) {
                if (-not $pk.ContainsKey($k)) { $changes += "added: $($ck[$k].Device) $($ck[$k].Version) ($($ck[$k].Provider))" }
                elseif ($pk[$k].Version -ne $ck[$k].Version) { $changes += "updated: $($ck[$k].Device) $($pk[$k].Version) -> $($ck[$k].Version)" }
            }
            foreach ($k in $pk.Keys) { if (-not $ck.ContainsKey($k)) { $changes += "removed: $($pk[$k].Device) $($pk[$k].Version)" } }
        }
        $cur | Export-Csv $latest -NoTypeInformation -Encoding UTF8
        $day.drivers = [ordered]@{ count = $cur.Count; changes = @($changes | Sort-Object) }
    } else { $day.drivers = [ordered]@{ error = 'driver inventory timed out' } }

    # Reliability Monitor: app crashes, Windows failures, installs (last 24h)
    $rel = Invoke-WithTimeout {
        $since = (Get-Date).AddHours(-24)
        # skip MSI "reconfigured" noise (1035 etc.); keep crashes, hangs, Windows failures, real installs/updates
        Get-CimInstance Win32_ReliabilityRecords -OperationTimeoutSec 90 |
            Where-Object { $_.TimeGenerated -gt $since -and -not ($_.SourceName -eq 'MsiInstaller' -and $_.EventIdentifier -notin 11707, 11724) } |
            Select-Object -First 40 |
            ForEach-Object { $m = ($_.Message -split "`n")[0]; "$($_.TimeGenerated.ToString('s'))|$($_.SourceName)|$($_.EventIdentifier)|$($_.ProductName)|$($m.Substring(0, [math]::Min(160, $m.Length)).Trim())" }
    } 120
    $day.reliability = if ($rel.ok) {
        @($rel.value | ForEach-Object { $f = "$_" -split '\|', 5; [ordered]@{ t = $f[0]; source = $f[1]; id = $f[2]; product = $f[3]; msg = $f[4] } })
    } else { 'timed out' }

    # pending reboot + waiting updates
    $day.reboot_pending = [bool]((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                                 (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
    $upd = Invoke-WithTimeout {
        $s = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        @($s.Search('IsInstalled=0 and IsHidden=0').Updates | ForEach-Object { $_.Title })
    } 300
    $day.pending_updates = if ($upd.ok) { @($upd.value) } else { 'timed out' }

    # disks: free space for every volume; SMART-style counters come from the admin SYSTEM task
    $day.volumes = @(Get-Volume -EA SilentlyContinue | Where-Object { $_.DriveLetter -and $_.Size } |
        ForEach-Object { [ordered]@{ drive = "$($_.DriveLetter):"; free_gb = [math]::Round($_.SizeRemaining / 1GB, 1); size_gb = [math]::Round($_.Size / 1GB) } })
    $day.disks = @(Get-PhysicalDisk -EA SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.FriendlyName; health = "$($_.HealthStatus)"; status = "$($_.OperationalStatus)" } })
    $dh = 'C:\ProgramData\RamWatch\disk-health.json'
    if (Test-Path $dh) { $day.disk_counters = Get-Content $dh -Raw | ConvertFrom-Json }

    # how far back the System log reaches (crash evidence is lost when it rolls over)
    $log = Get-WinEvent -ListLog System -EA SilentlyContinue
    $oldest = Get-WinEvent -LogName System -MaxEvents 1 -Oldest -EA SilentlyContinue
    $day.system_log = [ordered]@{ max_mb = [math]::Round($log.MaximumSizeInBytes / 1MB); oldest = if ($oldest) { $oldest.TimeCreated.ToString('s') } else { $null } }
    $day
}
