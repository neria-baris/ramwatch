# run-in-job.ps1 - run a command so that everything it starts dies with it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-in-job.ps1 <program> [arguments...]
#   e.g.  ... run-in-job.ps1 python make_pdf.py report.html
#         ... run-in-job.ps1 npx @playwright/mcp@latest          (also as an MCP server "command": stdio passes through)
#
# The wrapper puts itself in a Windows Job Object with "kill on job close" and then starts the program, so the program
# and every process it starts (headless browsers included) are in the job. When the wrapper ends - normally, killed,
# or because the agent session that ran it died - Windows closes the job and kills whatever is left. A print script
# that forgets browser.close() can no longer leave a browser behind.
# Prints nothing itself (safe for stdio protocols); exit code = the program's exit code.
#   -TimeoutSec N (first argument): stop after N seconds - the program and everything it started - exit code 124.
#   Use it for one-shot jobs such as printing: headless Edge, for one, writes the PDF but then keeps running.
$timeout = 0
if ($args.Count -ge 2 -and $args[0] -eq '-TimeoutSec') { $timeout = [int]$args[1]; $args = @($args | Select-Object -Skip 2) }
if (-not $args) { [Console]::Error.WriteLine('usage: run-in-job.ps1 [-TimeoutSec N] <program> [arguments...]'); exit 2 }
$ErrorActionPreference = 'Stop'
Add-Type -Namespace RwJob -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr a, string name);
[DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, int len);
[DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
[DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
// JOBOBJECT_EXTENDED_LIMIT_INFORMATION is 144 bytes on x64; LimitFlags sits at offset 16
public static IntPtr KillOnCloseJob() {
    IntPtr job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
    IntPtr info = Marshal.AllocHGlobal(144);
    try {
        for (int i = 0; i < 144; i++) Marshal.WriteByte(info, i, 0);
        Marshal.WriteInt32(info, 16, 0x2000);                      // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(job, 9, info, 144)) throw new System.ComponentModel.Win32Exception();   // ExtendedLimitInformation
    } finally { Marshal.FreeHGlobal(info); }
    if (!AssignProcessToJobObject(job, GetCurrentProcess())) throw new System.ComponentModel.Win32Exception();
    return job;   // never closed by us: the handle closes when this process ends, and that kills the job
}
'@
$script:job = [RwJob.Native]::KillOnCloseJob()

$exe = $args[0]
$cmd = Get-Command $exe -CommandType Application -EA SilentlyContinue | Select-Object -First 1
if ($cmd) { $exe = $cmd.Source }
# Windows command-line quoting (CommandLineToArgvW rules)
function Quote([string]$a) {
    if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
    '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}
$psi = New-Object Diagnostics.ProcessStartInfo $exe
$psi.Arguments = (@($args | Select-Object -Skip 1 | ForEach-Object { Quote "$_" }) -join ' ')
$psi.UseShellExecute = $false          # inherit this console and stdin/stdout/stderr as they are
$p = [Diagnostics.Process]::Start($psi)
if ($timeout -gt 0) {
    if (-not $p.WaitForExit($timeout * 1000)) {
        [Console]::Error.WriteLine("run-in-job: $timeout s passed - stopping $(Split-Path $exe -Leaf) and everything it started")
        exit 124   # this process ends -> the job closes -> Windows kills the rest
    }
} else { $p.WaitForExit() }
exit $p.ExitCode
