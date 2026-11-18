# show-unactivated.ps1 — make a window visible without activating it.
#
# WHY THIS IS NEEDED. A GUI process started with STARTUPINFO.wShowWindow = SW_HIDE --
# which is what node's `windowsHide: true` and PowerShell's `-WindowStyle Hidden` both do
# -- creates its first window already hidden. EnumWindows then reports nothing, and a
# driver waiting for a window times out and blames the launch. ShowWindow with SW_SHOWNA
# makes it appear without taking activation, which keeps the launch from stealing the
# foreground -- the one thing these experiments must not confuse with an injection.
param(
  [Parameter(Mandatory = $true)][long]$Hwnd,
  [ValidateSet('NA', 'SHOW')][string]$Mode = 'NA'
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SU {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public static string Report(IntPtr h, int cmd) {
    IntPtr before = GetForegroundWindow();
    bool ok = ShowWindow(h, cmd);
    IntPtr after = GetForegroundWindow();
    return "{\"shown\":" + (ok ? "true" : "false") + ",\"visible\":" + (IsWindowVisible(h) ? "true" : "false") +
           ",\"fgBefore\":" + before.ToInt64() + ",\"fgAfter\":" + after.ToInt64() +
           ",\"activationStolen\":" + (before != after ? "true" : "false") + "}";
  }
}
'@
$cmd = if ($Mode -eq 'NA') { 8 } else { 5 }   # SW_SHOWNA / SW_SHOW
[SU]::Report([IntPtr]$Hwnd, $cmd)
