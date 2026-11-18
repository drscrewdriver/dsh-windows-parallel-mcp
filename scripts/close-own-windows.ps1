# close-own-windows.ps1 — close ONLY windows this session's probes created.
#
# These linger because the shell wrapper kills a command's process tree on exit, so a
# script's own cleanup step never runs when it is interrupted mid-way. Left open, they
# both annoy the user and pollute later measurements: a stale target window from run N
# shows up as a live candidate in run N+1 and its numbers mean nothing.
#
# The allowlist is by probe marker string in the title. Nothing on this list can be a
# window the user opened: each marker is a GUID-ish name invented by these scripts.
param([switch]$DryRun)
$ErrorActionPreference = 'Continue'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class CW {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP c, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowTextLengthW(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);

  public static List<string> Match(string[] markers) {
    List<string> acc = new List<string>();
    EP cb = delegate (IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int n = GetWindowTextLengthW(h);
      if (n <= 0) return true;
      StringBuilder sb = new StringBuilder(n + 2);
      GetWindowTextW(h, sb, sb.Capacity);
      string t = sb.ToString();
      foreach (string m in markers) {
        if (t.IndexOf(m, StringComparison.OrdinalIgnoreCase) >= 0) {
          uint pid; GetWindowThreadProcessId(h, out pid);
          acc.Add(h.ToInt64() + "\t" + t + "\t" + pid);
          break;
        }
      }
      return true;
    };
    EnumWindows(cb, IntPtr.Zero);
    return acc;
  }
  public static void Close(IntPtr h) { PostMessageW(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
}
'@

$markers = @(
  'WpmWinFormsTarget',   # the WinForms positive control
  'WpmWpfTarget',        # the WPF positive control
  'WpmNeutr',            # Chromium data: URL used by the neutrality experiment
  'WpmReachProbe',       # Chromium data: URL used by the reachability matrix
  'wpm-reach-',          # Explorer windows opened on probe temp dirs
  'WpmReachConsole'      # console spawned by the matrix
)

$found = [CW]::Match($markers)
if (-not $found.Count) { "nothing to close"; exit 0 }
"candidates=$($found.Count)"
foreach ($line in $found) {
  $p = $line -split "`t"
  $hwnd = [IntPtr]([int64]$p[0]); $title = $p[1]
  # $ownerPid, never $pid: $PID is a read-only automatic variable in PowerShell, and
  # assigning it fails with VariableNotWritable while the loop keeps going, so the log
  # would print pid=1124 for every window and hide which process actually owns each one.
  $ownerPid = [int]$p[2]
  if ($DryRun) { "would close hwnd=$hwnd owner=$ownerPid title='$title'"; continue }
  # WM_CLOSE on the window only. Never Stop-Process: for Edge and Explorer the owning
  # process is shared with windows the user opened themselves.
  [CW]::Close($hwnd)
  Start-Sleep -Milliseconds 350
  $state = if (-not [CW]::IsWindow($hwnd)) { 'closed' } else { 'still open' }
  "close hwnd=$hwnd pid=$pid title='$title' -> $state"
}
$left = [CW]::Match($markers)
"remaining=$($left.Count)"
