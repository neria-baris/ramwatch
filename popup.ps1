# popup.ps1 - always-on-top RamWatch alert window (shows even in Do Not Disturb / Focus).
# Started detached by ram-watch.ps1; only one popup at a time (a newer alert replaces the old one).
param([Parameter(Mandatory)][string]$Report)

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match ('^"?\S*powershell(\.exe)?"?\s+-NoProfile -ExecutionPolicy Bypass -File "?' + [regex]::Escape($PSCommandPath)) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }

# Render at the real display DPI (125% here) instead of being bitmap-stretched, which looks blurry.
Add-Type -Namespace RamWatch -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern uint GetDpiForSystem();
'@
try { [void][RamWatch.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { [void][RamWatch.Dpi]::SetProcessDPIAware() }
$scale = [RamWatch.Dpi]::GetDpiForSystem() / 96

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$text = [IO.File]::ReadAllText($Report, [Text.Encoding]::UTF8) -replace '\*\*', '' -replace '`', ''
$text = $text -replace "`r?`n", "`r`n"

$form = New-Object System.Windows.Forms.Form
$form.Text = 'RamWatch - ALERT  (' + (Get-Date -Format 'HH:mm') + ')'
$form.Size = New-Object System.Drawing.Size([int](600 * $scale), [int](420 * $scale))
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.RightToLeft = 'Yes'
$form.RightToLeftLayout = $true
$form.Icon = [System.Drawing.SystemIcons]::Warning

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Vertical'; $box.WordWrap = $true
$box.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$box.BackColor = [System.Drawing.Color]::White
$box.RightToLeft = 'Yes'
$box.Dock = 'Fill'
$box.Text = $text

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock = 'Bottom'; $panel.Height = [int](44 * $scale); $panel.Padding = New-Object System.Windows.Forms.Padding([int](6 * $scale))
$open = New-Object System.Windows.Forms.Button
$open.Text = 'Open report'; $open.AutoSize = $true
$open.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$Report`"" })
$close = New-Object System.Windows.Forms.Button
$close.Text = 'Close'; $close.AutoSize = $true
$close.Add_Click({ $form.Close() })
$panel.Controls.AddRange(@($close, $open))
$form.CancelButton = $close

$form.Controls.Add($box)
$form.Controls.Add($panel)
Add-Type -Namespace RamWatch -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@
$form.Add_Shown({
    # a hidden start-up state (SW_HIDE) would otherwise swallow the first show
    if (-not [RamWatch.Win]::IsWindowVisible($form.Handle)) { [void][RamWatch.Win]::ShowWindow($form.Handle, 5) }
    [void][RamWatch.Win]::SetForegroundWindow($form.Handle)
    $form.Activate(); $box.SelectionLength = 0; [System.Media.SystemSounds]::Exclamation.Play()
})
[void]$form.ShowDialog()
