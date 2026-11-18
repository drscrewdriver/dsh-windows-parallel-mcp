# find-window.ps1 — locate a top-level window by title substring, via EnumWindows.
#
# Why not Get-Process MainWindowTitle: when the owning process was started with its
# console hidden, MainWindowHandle can resolve to the console rather than the form, and
# the title reads empty. Enumerating real top-level windows is the only lookup that works
# for both a visible and a hidden host process, and it is what the reachability matrix
# already uses, so the baseline and the matrix agree on what "the target window" means.
param(
  [Parameter(Mandatory = $true)][string]$TitlePart,
  [int]$TimeoutSec = 0
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FW {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr l);
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowTextLengthW(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);

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
      StringBuilder cls = new StringBuilder(256);
      GetClassNameW(h, cls, cls.Capacity);
      RECT r; GetWindowRect(h, out r);
      uint pid; GetWindowThreadProcessId(h, out pid);
      result = h.ToInt64() + "|" + sb.ToString() + "|" + cls.ToString() + "|" + pid + "|" + (r.r - r.l) + "x" + (r.b - r.t);
      return false;
    };
    EnumWindows(cb, IntPtr.Zero);
    return result;
  }
}
'@

$deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSec))
while ($true) {
  $hit = [FW]::Find($TitlePart)
  if ($hit) {
    $p = $hit -split '\|'
    (@{ hwnd = [long]$p[0]; title = $p[1]; cls = $p[2]; procId = [int]$p[3]; size = $p[4] } | ConvertTo-Json -Compress)
    exit 0
  }
  if ((Get-Date) -ge $deadline) { exit 3 }
  Start-Sleep -Milliseconds 350
}
