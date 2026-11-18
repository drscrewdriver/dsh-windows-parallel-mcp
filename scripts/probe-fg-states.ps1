# probe-fg-states.ps1 — what window states can this session actually reach?
#
# Purpose: the background-enumeration test needs a target that is VISIBLE but NOT
# FOREGROUND. Choosing how to produce that state is a Win32 question, and the answer is
# session-dependent (the foreground lock refuses cross-process activation), so it is
# probed rather than assumed. Nothing here touches UIA; it only asks what the window
# manager reports after each ShowWindow verb.
param([string]$TitlePart = 'Calculator')
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FGS {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP c, IntPtr l);
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern int GetWindowTextLengthW(IntPtr h);
  public static string FgTitle() {
    IntPtr h = GetForegroundWindow();
    if (h == IntPtr.Zero) return "(none)";
    StringBuilder sb = new StringBuilder(256); GetWindowTextW(h, sb, sb.Capacity);
    StringBuilder cs = new StringBuilder(256); GetClassNameW(h, cs, cs.Capacity);
    return sb.ToString() + " || " + cs.ToString() + " || hwnd=" + h.ToInt64();
  }
  public static string State(IntPtr h) {
    return "iconic=" + IsIconic(h) + " visible=" + IsWindowVisible(h);
  }
}
'@
function Find-Win([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}
$w = Find-Win $TitlePart
if (-not $w) { throw "no window matching '$TitlePart'" }
$h = [IntPtr]$w.hwnd
"target hwnd=$h class='$($w.cls)'"
"foreground now : $(([FGS]::FgTitle()))"
"target now     : $([FGS]::State($h))"
''
foreach ($verb in @(
    @{ n = 'SW_MINIMIZE (2)'; c = 2 },
    @{ n = 'SW_SHOWNOACTIVATE (4)'; c = 4 },
    @{ n = 'SW_SHOWNA (8)'; c = 8 },
    @{ n = 'SW_RESTORE (9)'; c = 9 },
    @{ n = 'SW_MINIMIZE then SW_SHOWNOACTIVATE'; c = -1 }
  )) {
  if ($verb.c -eq -1) {
    [void][FGS]::ShowWindow($h, 2); Start-Sleep -Milliseconds 700
    [void][FGS]::ShowWindow($h, 4)
  } else {
    [void][FGS]::ShowWindow($h, $verb.c)
  }
  Start-Sleep -Milliseconds 1200
  "{0,-34} fg={1,-52} target={2}" -f $verb.n, ([FGS]::FgTitle()), ([FGS]::State($h))
}
[void][FGS]::ShowWindow($h, 9)
