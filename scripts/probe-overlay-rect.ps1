# probe-overlay-rect.ps1 -- an INDEPENDENT oracle for where the AI marker is.
#
# Why not just ask the engine: the engine reporting its own marker position is the plugin grading
# its own homework. This script knows nothing about overlay.ps1 -- it enumerates top-level windows,
# finds the one titled WpmOverlay, and reports the rect / ex-style / owning pid straight from
# Win32. Used by test/marker-e2e.mjs to check that the marker really covers the point a click hit,
# in the same physical-pixel space the click used.
#
# Exit 0 and one JSON line when found, exit 1 with {"found":false} when not.
param([string]$Title = 'WpmOverlay', [string]$Hwnd = '')
$ErrorActionPreference = 'Stop'
# THIS ORACLE MUST BE DPI AWARE FOR THE SAME REASON THE ENGINE IS. An unaware PowerShell process
# gets every coordinate virtualised by Windows, so it reported the marker at (459,399) while the
# aware engine had placed it at (694,410) -- the oracle was wrong, not the product. Both sides of a
# coordinate comparison have to agree about the coordinate space or the comparison means nothing.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OvDpi {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetProcessDPIAware();
}
'@
[void][OvDpi]::SetProcessDPIAware()
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class OvProbe {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public static List<IntPtr> Find(string title) {
        var hits = new List<IntPtr>();
        EnumWindows((h, l) => {
            var sb = new StringBuilder(512);
            GetWindowTextW(h, sb, sb.Capacity);
            if (sb.ToString() == title) hits.Add(h);
            return true;
        }, IntPtr.Zero);
        return hits;
    }
}
'@
$hits = [OvProbe]::Find($Title)
if ($hits.Count -eq 0) {
  '{"found":false}'
  exit 1
}
# ANCHOR WHEN GIVEN. $Hwnd is the overlay handle the product itself reported via status. Title
# matching alone can hit a leaked overlay from a previous run (or anyone else's window with the
# same caption); grading THAT would certify a marker we never placed. With an anchor, we pick our
# own window and report ambiguity openly when the desktop has more than one.
$ambiguous = ($hits.Count -gt 1)
$h = $null
if ($Hwnd -ne '') {
  foreach ($cand in $hits) { if ([int64]$cand -eq [int64]$Hwnd) { $h = $cand; break } }
  if ($null -eq $h) {
    (@{ found = $false; notOurs = $true; wantedHwnd = [int64]$Hwnd; seenTitles = $hits.Count } | ConvertTo-Json -Compress)
    exit 1
  }
} else {
  $h = $hits[0]
}
$r = New-Object 'OvProbe+RECT'
[void][OvProbe]::GetWindowRect($h, [ref]$r)
# NOT $pid: that is a read-only automatic variable in PowerShell, and assigning it fails with
# "VariableNotWritable" -- which is what the first run of this oracle reported instead of a rect.
$ownerPid = [uint32]0
[void][OvProbe]::GetWindowThreadProcessId($h, [ref]$ownerPid)
$ex = [OvProbe]::GetWindowLong($h, -20)
$o = [ordered]@{
  found = $true
  hwnd = [int64]$h
  ambiguous = $ambiguous
  pid = [int]$ownerPid
  left = $r.Left; top = $r.Top; right = $r.Right; bottom = $r.Bottom
  width = $r.Right - $r.Left; height = $r.Bottom - $r.Top
  visible = [OvProbe]::IsWindowVisible($h)
  exStyle = ('0x{0:X8}' -f $ex)
  topmost = [bool]($ex -band 0x00000008)
  noActivate = [bool]($ex -band 0x08000000)
  transparent = [bool]($ex -band 0x00000020)
}
$o | ConvertTo-Json -Compress
exit 0
