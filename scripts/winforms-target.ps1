# winforms-target.ps1 — a known-reachable target for the reachability matrix.
#
# WHY THIS EXISTS: without it, a low ok-rate cannot be read. Either the channels really
# do not reach Win11 Notepad/Explorer/Chromium, or the matrix's method is wrong, or this
# session's UIA/environment is broken. A WinForms window has a classic Edit child window
# and a real Button, so if the channels work there and fail elsewhere, the failure belongs
# to the targets, not to the instrument. That is also the acceptance shape of task_18
# ("WinForms test window can be clicked, Edit writable, focus unchanged").
#
# STA and hidden-but-not-minimised: a WinForms message loop needs STA for the clipboard
# and UIA provider paths. The window is visible so UIA exposes its tree; it is positioned
# off the working area top-left corner so it does not cover the user's screen.
param(
  [int]$HoldMs = 90000,
  [string]$Title = 'WpmWinFormsTarget',
  [string]$ExitFile = '',
  # Explicit position. Two targets launched by this script would otherwise both default to
  # 60,60 and overlap EXACTLY, which silently breaks any experiment that guards on "the
  # cursor never entered the target rectangle": with identical rects, a cursor over one is
  # over both, and the guard cannot tell the acting window from the holder.
  [int]$X = 60,
  [int]$Y = 60,
  # After this many milliseconds the form takes the foreground ITSELF. It must be the
  # owning process that calls SetForegroundWindow: the foreground lock refuses the call
  # from any other process, so a driver script trying to background a target by activating
  # a window it does not own silently does nothing -- which is how the background-state
  # experiment reported a "background" reading for a window that was still foreground.
  # -1 disables.
  [int]$GrabFgAfterMs = -1,
  # When this file appears, the form takes the foreground AGAIN and deletes the file. It
  # exists because an experiment can lose its foreground hand-off mid-run: the first
  # attributed Calculator run found the target had kept the foreground from round 1 onward,
  # so rounds 2-8 silently measured "act on a FOREGROUND app" under a header claiming
  # background. Only the owning process may re-activate (the foreground lock refuses
  # outsiders), so the request has to be delivered to the owner through a file it polls.
  [string]$ReGrabFile = ''
)
$ErrorActionPreference = 'Stop'
# WinForms' UIA providers are behind AppContext switches, and powershell.exe runs with
# the legacy defaults -- under which every control surfaces through the MSAA bridge as a
# bare Pane with NO patterns. That made the positive control fail, which is precisely the
# thing a positive control is for: it told us the instrument, not the target, was broken.
# Turning the switches off before any WinForms type is touched restores real UIA.
foreach ($sw in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.2', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.3') {
  try { [AppContext]::SetSwitch($sw, $false) } catch { }
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.Size = New-Object System.Drawing.Size(420, 300)
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point($X, $Y)
$form.Topmost = $false
$form.ShowInTaskbar = $true

$edit = New-Object System.Windows.Forms.TextBox
$edit.Name = 'targetEdit'
$edit.Text = 'abc'
$edit.Location = New-Object System.Drawing.Point(20, 20)
$edit.Size = New-Object System.Drawing.Size(360, 26)
$form.Controls.Add($edit)

$btn = New-Object System.Windows.Forms.Button
$btn.Name = 'targetButton'
$btn.Text = 'Press'
$btn.Location = New-Object System.Drawing.Point(20, 60)
$btn.Size = New-Object System.Drawing.Size(120, 32)
$script:clicks = 0
$btn.Add_Click({ $script:clicks++; $btn.Text = "Press($($script:clicks))" })
$form.Controls.Add($btn)

# The click counter has to be observable without a pattern: expose it as part of the
# button's Name, which UIA reads as Current.Name. Effect verification then has something
# real to diff instead of guessing from pixels.
$edit2 = New-Object System.Windows.Forms.RichTextBox
$edit2.Name = 'targetRich'
$edit2.Text = 'rich-abc'
$edit2.Location = New-Object System.Drawing.Point(20, 110)
$edit2.Size = New-Object System.Drawing.Size(360, 80)
$form.Controls.Add($edit2)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$started = (Get-Date)
$timer.Add_Tick({
  if ($ExitFile -and (Test-Path -LiteralPath $ExitFile)) { $form.Close() }
  if (((Get-Date) - $started).TotalMilliseconds -gt $HoldMs) { $form.Close() }
  # Self-activation on the owning process's own UI thread. A driver script cannot do this
  # for us: the foreground lock refuses SetForegroundWindow from a process that owns
  # neither the current foreground window nor the last input event.
  if ($GrabFgAfterMs -ge 0 -and -not $script:grabTried -and
      ((Get-Date) - $started).TotalMilliseconds -ge $GrabFgAfterMs) {
    $script:grabTried = $true
    try { $ok = [WinShow]::Grab($form.Handle); Write-Output ("GRAB=" + $ok) } catch { Write-Output ("GRAB=error " + $_.Exception.Message) }
  }
  # Foreground re-claim on request, CONTINUOUSLY while the flag file exists. The first
  # version deleted the flag after one attempt, which made the driver's wait a race: if the
  # form's 400ms tick happened to land in the wrong place, the request was consumed without
  # effect and the driver reported an unrecoverable precondition that could have been fixed
  # one tick later. The file's existence is the request, and its removal by the driver is
  # the release -- so the owner keeps trying until told to stop, and no attempt is lost.
  if ($ReGrabFile -and (Test-Path -LiteralPath $ReGrabFile)) {
    if (-not $script:reGrabActive) { $script:reGrabActive = $true; Write-Output "REGRAB begin" }
    try {
      $ok = [WinShow]::Grab($form.Handle)
      if ($ok) { $script:reGrabOk = $true }
    } catch { Write-Output ("REGRAB=error " + $_.Exception.Message) }
  } elseif ($script:reGrabActive) {
    $script:reGrabActive = $false
    Write-Output ("REGRAB end ok=$([bool]$script:reGrabOk)")
  }
})
$timer.Start()

# A process launched with STARTUPINFO SW_HIDE -- which is what node's windowsHide:true and
# PowerShell's -WindowStyle Hidden both do -- creates its first window already hidden: the
# window exists but EnumWindows never lists it, and every driver waiting on the target
# concludes "launch failed". SW_SHOWNA restores visibility WITHOUT activation, which is
# also why showing the window does not steal the foreground.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinShow {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public static string Unactivate(IntPtr h) {
    ShowWindow(h, 8);              // SW_SHOWNA
    return h.ToInt64() + " visible=" + IsWindowVisible(h);
  }
  // Called from THIS process, which owns the window -- the only caller the foreground
  // lock will accept for an activation.
  public static bool Grab(IntPtr h) {
    ShowWindow(h, 5);              // SW_SHOW
    SetForegroundWindow(h);
    return GetForegroundWindow() == h;
  }
}
'@

$grabbedAt = -1
$grabTried = $false

$form.Add_Shown({
  try { [void][WinShow]::Unactivate($form.Handle) } catch { }
  # Print our own hwnd so the driver never has to guess which window appeared.
  Write-Output ("HWND=" + $form.Handle.ToInt64())
})

[System.Windows.Forms.Application]::Run($form)
