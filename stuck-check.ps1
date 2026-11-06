# stuck-check.ps1 - details on processes that were told to exit but are still there ("exited but alive").
# Runs as SYSTEM every 15 minutes (installed by setup-admin.ps1, which copies it to the admin-only
# C:\ProgramData\RamWatch) and writes stuck-holders.json there, which RamWatch reads without admin rights.
#
# Such a process has an exit code (it was killed or asked to exit) but is still listed because some of its threads
# never finished: they are blocked inside a driver, usually on I/O that never completes. Nobody can kill them -
# only the driver finishing that I/O, or a reboot, frees them. (A process kept only by someone's open handle
# disappears from the process list, so it is not what we see here.)
# What this records, per stuck process: its live threads and what they wait on, which kinds of kernel objects it
# still has open (e.g. many "File" handles on network sockets), and whether another process holds a handle to it.
# The driver itself is named only by kernel stacks: Task Manager (as Administrator) > Details > right-click
# "System" > "Create live kernel memory dump file", then analyse the dump.
param([string]$Out = 'C:\ProgramData\RamWatch\stuck-holders.json')
$ErrorActionPreference = 'Stop'

$stuck = foreach ($p in Get-Process) {
    try { if ($p.Id -gt 4 -and $p.HasExited) { $p } } catch { }   # protected processes can't be opened
}
$result = [ordered]@{ checked_at = (Get-Date).ToString('s'); stuck_count = @($stuck).Count; processes = @(); held_open_by = @() }

if ($stuck) {
    if (-not ('RwStuck' -as [type])) {
        Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class RwStuck {
  [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int c, IntPtr b, int l, out int r);
  [DllImport("ntdll.dll")] static extern int NtQueryObject(IntPtr h, int c, IntPtr b, int l, out int r);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern int GetCurrentProcessId();
  static IntPtr Query(int cls, bool obj, out int st) {
    int len = 1 << 20, ret; IntPtr buf;
    while (true) {
      buf = Marshal.AllocHGlobal(len);
      st = obj ? NtQueryObject(IntPtr.Zero, cls, buf, len, out ret) : NtQuerySystemInformation(cls, buf, len, out ret);
      if (st == unchecked((int)0xC0000004) && len < (1 << 28)) { Marshal.FreeHGlobal(buf); len = Math.Max(ret + (1 << 20), len * 2); continue; }
      return buf;
    }
  }
  static Dictionary<int, string> TypeNames() {             // ObjectTypesInformation: index -> "File", "Event", ...
    var names = new Dictionary<int, string>(); int st; IntPtr buf = Query(3, true, out st);
    try {
      if (st != 0) return names;
      int n = Marshal.ReadInt32(buf); long off = 8;
      for (int i = 0; i < n; i++) {
        IntPtr e = new IntPtr(buf.ToInt64() + off);
        int len = Marshal.ReadInt16(e); int max = Marshal.ReadInt16(e, 2); IntPtr s = Marshal.ReadIntPtr(e, 8);
        names[Marshal.ReadByte(e, 0x5A)] = Marshal.PtrToStringUni(s, len / 2);
        off += 0x68 + ((max + 7) & ~7);
      }
    } catch { } finally { Marshal.FreeHGlobal(buf); }
    return names;
  }
  // rows: "H,<stuckPid>,<holderPid>,<count>"  and  "T,<stuckPid>,<typeName>,<count>"
  public static List<string> Inspect(int[] pids) {
    var rows = new List<string>(); var mine = new Dictionary<long, int>(); var opened = new List<IntPtr>(); var want = new HashSet<long>();
    int self = GetCurrentProcessId();
    foreach (int pid in pids) {
      want.Add(pid);
      IntPtr h = OpenProcess(0x1000, false, pid);              // PROCESS_QUERY_LIMITED_INFORMATION
      if (h != IntPtr.Zero) { opened.Add(h); mine[h.ToInt64()] = pid; }
    }
    var types = TypeNames(); int st; IntPtr buf = Query(64, false, out st);   // SystemExtendedHandleInformation
    try {
      if (st != 0) throw new Exception("NTSTATUS 0x" + st.ToString("X8"));
      long n = Marshal.ReadInt64(buf); const int size = 40, start = 16;
      var objOf = new Dictionary<long, int>(); var tally = new Dictionary<string, int>();
      for (long i = 0; i < n; i++) {
        IntPtr e = new IntPtr(buf.ToInt64() + start + i * size);
        long owner = Marshal.ReadInt64(e, 8);
        if (owner == self) { int z; long o = Marshal.ReadInt64(e); if (o != 0 && mine.TryGetValue(Marshal.ReadInt64(e, 16), out z)) objOf[o] = z; }   // 0 = address hidden (not admin)
        else if (want.Contains(owner)) {                       // what the stuck process still has open
          int ti = Marshal.ReadInt16(e, 30); string tn; if (!types.TryGetValue(ti, out tn)) tn = "type" + ti;
          string k = "T," + owner + "," + tn; int c; tally.TryGetValue(k, out c); tally[k] = c + 1;
        }
      }
      for (long i = 0; i < n; i++) {                           // who else holds a handle to the stuck process
        IntPtr e = new IntPtr(buf.ToInt64() + start + i * size); int z;
        if (!objOf.TryGetValue(Marshal.ReadInt64(e), out z)) continue;
        long owner = Marshal.ReadInt64(e, 8); if (owner == self || owner == z) continue;
        string k = "H," + z + "," + owner; int c; tally.TryGetValue(k, out c); tally[k] = c + 1;
      }
      foreach (var kv in tally) rows.Add(kv.Key + "," + kv.Value);
    } finally { Marshal.FreeHGlobal(buf); foreach (var h in opened) CloseHandle(h); }
    return rows;
  }
}
"@
    }
    $names = @{}; foreach ($p in Get-Process) { $names[$p.Id] = $p.ProcessName }
    $rows = @([RwStuck]::Inspect([int[]]@($stuck | ForEach-Object Id)) | ForEach-Object { $a = $_ -split ','; [pscustomobject]@{ k = $a[0]; z = [int]$a[1]; x = $a[2]; n = [int]$a[3] } })
    $result.processes = @($stuck | Sort-Object Id | ForEach-Object {
        $z = $_
        $threads = @(try { $z.Threads } catch { })
        $waits = @($threads | ForEach-Object { try { if ("$($_.ThreadState)" -eq 'Wait') { "$($_.WaitReason)" } else { "$($_.ThreadState)" } } catch { 'unknown' } } |
            Group-Object | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) x$($_.Count)" })
        [ordered]@{
            pid = $z.Id; name = $z.ProcessName
            exit_code = $(try { $z.ExitCode } catch { $null })
            started = $(try { $z.StartTime.ToString('s') } catch { $null })
            live_threads = $threads.Count; thread_waits = $waits
            open_handles = @($rows | Where-Object { $_.k -eq 'T' -and $_.z -eq $z.Id } | Sort-Object n -Descending | ForEach-Object { "$($_.x) x$($_.n)" })
            held_by = @($rows | Where-Object { $_.k -eq 'H' -and $_.z -eq $z.Id } | ForEach-Object { "$(if ([int]$_.x -eq 4) { 'System (kernel handle)' } else { $names[[int]$_.x] }) ($($_.x))" })
        }
    })
    $result.held_open_by = @($result.processes | ForEach-Object { $_.held_by } | ForEach-Object { $_ -replace ' \(\d+\)$' } |
        Group-Object | Sort-Object Count -Descending | ForEach-Object { "$($_.Name): $($_.Count)" })
}
[IO.File]::WriteAllText($Out, ($result | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
