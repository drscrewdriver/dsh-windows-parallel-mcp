# probe-overlay-pixels.ps1 -- the marker's surface, measured in PIXELS rather than by its rect.
#
# WHY A RECT PROBE CANNOT SEE THIS DEFECT. test/marker-e2e.mjs verifies WHERE the marker is (rect vs the
# click point), and a white background does not move the rect. The defect is what the window PAINTS: a WPF
# Window's default background is SystemColors.WindowBrush, so a 22px marker with no explicit Background
# painted an opaque white tile with the blue ring inside it. That is invisible to geometry and obvious to
# a screenshot, which is exactly why this probe copies the pixels out of the window and prints their
# alpha/colour instead of trusting a claim about the style.
#
# It also prints the marker's own rendered colours so 'the ring is still there' is checked rather than
# assumed after the background fix.
param([string]$Hwnd = '')
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('WpmPixelProbe' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WpmPixelProbe {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@
}

$hwnd = [IntPtr]::Zero
if ($Hwnd) { $hwnd = [IntPtr][int64]$Hwnd }
if ($hwnd -eq [IntPtr]::Zero) { $hwnd = [WpmPixelProbe]::FindWindowW($null, 'WpmOverlay') }
if ($hwnd -eq [IntPtr]::Zero) {
  Write-Output '{"ok":false,"reason":"no WpmOverlay window found; start the marker first"}'
  exit 0
}
$r = New-Object 'WpmPixelProbe+RECT'
[void][WpmPixelProbe]::GetWindowRect($hwnd, [ref]$r)
$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
if ($w -le 0 -or $h -le 0) {
  Write-Output '{"ok":false,"reason":"window has an empty rect (it is parked offscreen)"}'
  exit 0
}

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
# PW_RENDERFULLCONTENT (2): a layered/transparent window does not paint through a plain WM_PRINT.
$printed = [WpmPixelProbe]::PrintWindow($hwnd, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()

# Sample the four corners and the centre. A transparent background reads as alpha 0 at the corners while
# the ring's stroke reads as opaque blue at the centre of an edge.
$sample = {
  param([int]$x, [int]$y)
  $p = $bmp.GetPixel($x, $y)
  return @{ x = $x; y = $y; a = [int]$p.A; r = [int]$p.R; g = [int]$p.G; b = [int]$p.B }
}
$corner = & $sample 1 1
$corner2 = & $sample ($w - 2) ($h - 2)
$center = & $sample ([int]($w / 2)) ([int]($h / 2))
$edge = & $sample ([int]($w / 2)) 1
$bmp.Dispose()

$out = @{
  ok = $true
  hwnd = [int64]$hwnd
  rect = "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
  size = "$w x $h"
  printWindow = [bool]$printed
  cornerTopLeft = $corner
  cornerBottomRight = $corner2
  center = $center
  edgeTopMiddle = $edge
  # The verdict the fix is about: a transparent background means the corner has zero alpha (nothing painted).
  cornersTransparent = ($corner.a -eq 0 -and $corner2.a -eq 0)
  centerPainted = ($center.a -gt 0)
}
$out | ConvertTo-Json -Compress -Depth 5
exit 0