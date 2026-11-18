# find-window.ps1 — locate a top-level window by title substring, via EnumWindows.
#
# Why not Get-Process MainWindowTitle: when the owning process was started with its
# console hidden, MainWindowHandle can resolve to the console rather than the form, and
# the title reads empty. Enumerating real top-level windows is the only lookup that works
# for both a visible and a hidden host process, and it is what the reachability matrix
# already uses, so the baseline and the matrix agree on what "the target window" means.
# A reverse lookup (hwnd -> what window is this?) is here for the same reason the forward
# one exists: when a measurement attributes "the foreground changed to hwnd 657692", the
# actionable question is WHO that is. Without it a software-attributed foreground change is
# just a number, and the verdict cannot tell "our own target stole the desktop" from "the
# harness opened a panel next door" -- a distinction that decides whether the run is a
# violation or noise.
param(
  [string]$TitlePart,
  [long]$Hwnd = 0,
  [int]$TimeoutSec = 0
)
$ErrorActionPreference = 'Stop'
if (-not $TitlePart -and $Hwnd -eq 0) { throw 'give either -TitlePart or -Hwnd' }
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FW {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr l);
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowTextLengthW(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);

  static string Describe(IntPtr h) {
    StringBuilder sb = new StringBuilder(512);
    GetWindowTextW(h, sb, sb.Capacity);
    StringBuilder cls = new StringBuilder(512);
    GetClassNameW(h, cls, cls.Capacity);
    RECT r; GetWindowRect(h, out r);
    uint pid; GetWindowThreadProcessId(h, out pid);
    string proc = "";
    try { proc = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
    return h.ToInt64() + "|" + sb.ToString() + "|" + cls.ToString() + "|" + pid + "|" +
           (r.r - r.l) + "x" + (r.b - r.t) + "|" + proc + "|" + IsWindowVisible(h);
  }

  public static string Find(string part) {
    string result = null;
    EP cb = delegate (IntPtr h, IntPtr l) {
      if (result != null) return true;
      if (!IsWindowVisible(h)) return true;
      int n = GetWindowTextLengthW(h);
      if (n <= 0) return true;
      StringBuilder sb = new StringBuilder(n + 2);
      GetWindowTextW(h, sb, sb.Capacity);
      if (sb.ToString().IndexOf(part, StringComparison.OrdinalIgnoreCase) < 0) return true;
      result = Describe(h);
      return false;
    };
    EnumWindows(cb, IntPtr.Zero);
    return result;
  }

  // Reverse: no EnumWindows needed, and it must work for a window with an EMPTY title,
  // which is common for tool panels -- the forward path filters those out by design.
  public static string ByHandle(IntPtr h) {
    if (!IsWindow(h)) return null;
    return Describe(h);
  }
}
'@

if ($Hwnd -ne 0) {
  $hit = [FW]::ByHandle([IntPtr]$Hwnd)
  if (-not $hit) { "no such window: $Hwnd"; exit 3 }
  $p = $hit -split '\|'
  (@{ hwnd = [long]$p[0]; title = $p[1]; cls = $p[2]; procId = [int]$p[3]; size = $p[4]; process = $p[5]; visible = ($p[6] -eq 'True') } | ConvertTo-Json -Compress)
  exit 0
}

$deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSec))
while ($true) {
  $hit = [FW]::Find($TitlePart)
  if ($hit) {
    $p = $hit -split '\|'
    (@{ hwnd = [long]$p[0]; title = $p[1]; cls = $p[2]; procId = [int]$p[3]; size = $p[4]; process = $p[5]; visible = ($p[6] -eq 'True') } | ConvertTo-Json -Compress)
    exit 0
  }
  if ((Get-Date) -ge $deadline) { exit 3 }
  Start-Sleep -Milliseconds 350
}
