# geometry-oracle.ps1 -- an INDEPENDENT measurement of the two facts test/geometry-truth.mjs grades.
#
# WHY IT IS SEPARATE FROM src/engine. The test must not grade the engine with the engine. This file
# P/Invokes DwmGetWindowAttribute and GetWindowRect itself, and decodes the PNG itself; it does not
# dot-source anything from src/engine, so a bug in Get-WpmFrameRect cannot hide inside its own oracle.
# That is the same rule test/uia-click-truth.mjs already follows by reading the counter file the app
# writes instead of reading our own Invoke back through UIA.
#
# Modes:
#   frame      -> { frame:'dwm'|'none', hr, dwm:{l,t,r,b}, win32:{l,t,r,b}, virtualScreen:{...} }
#   image      -> { ok, reason, width, height, nonBlank, samples, regionNonBlank }   (PNG on disk)
#   makeblank  -> writes an all-white PNG of the requested size (the non-vacuity instrument)
#
# Exit code is 0 when the requested measurement itself succeeded (the ANSWER may be negative: a blank
# image is a successful measurement of blankness).
param(
  [ValidateSet('frame', 'image', 'makeblank')][string]$Mode = 'frame',
  [string]$Hwnd = '',
  [string]$File = '',
  [int]$Width = 0,
  [int]$Height = 0,
  # Optional sub-rectangle to sample as well, as "left,top,right,bottom".
  [string]$Region = ''
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

if (-not ('WpmGeoOracle' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WpmGeoOracle
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);

    /// <summary>{hr, left, top, right, bottom}; hr 0 means usable.</summary>
    public static long[] Dwm(IntPtr h)
    {
        RECT r;
        int hr = DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT)));
        if (hr != 0) return new long[] { hr, 0, 0, 0, 0 };
        return new long[] { 0, r.Left, r.Top, r.Right, r.Bottom };
    }

    /// <summary>{ok, left, top, right, bottom}</summary>
    public static long[] Win32(IntPtr h)
    {
        RECT r;
        if (!GetWindowRect(h, out r)) return new long[] { 0, 0, 0, 0, 0 };
        return new long[] { 1, r.Left, r.Top, r.Right, r.Bottom };
    }

    public static int[] VirtualScreen()
    {
        return new int[] { GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79) };
    }
}
'@
}

function Write-Json($obj) {
  Write-Output ($obj | ConvertTo-Json -Depth 6 -Compress)
}

if ($Mode -eq 'frame') {
  $h = [IntPtr][int64]$Hwnd
  $d = [WpmGeoOracle]::Dwm($h)
  $w = [WpmGeoOracle]::Win32($h)
  $vs = [WpmGeoOracle]::VirtualScreen()
  Write-Json @{
    frame = $(if ($d[0] -eq 0) { 'dwm' } else { 'none' })
    hr = [int]$d[0]
    dwm = @{ left = [int]$d[1]; top = [int]$d[2]; right = [int]$d[3]; bottom = [int]$d[4] }
    win32 = @{ left = [int]$w[1]; top = [int]$w[2]; right = [int]$w[3]; bottom = [int]$w[4]; ok = ($w[0] -eq 1) }
    virtualScreen = @{ x = $vs[0]; y = $vs[1]; width = $vs[2]; height = $vs[3] }
  }
  exit 0
}

if ($Mode -eq 'makeblank') {
  $bmp = New-Object System.Drawing.Bitmap([Math]::Max(1, $Width), [Math]::Max(1, $Height))
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.Clear([System.Drawing.Color]::White) } finally { $g.Dispose() }
  try { $bmp.Save($File, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
  Write-Json @{ ok = $true; file = $File; width = [Math]::Max(1, $Width); height = [Math]::Max(1, $Height) }
  exit 0
}

# ---- image mode: decode the PNG and report what is actually in it ---------------------------------
if (-not (Test-Path -LiteralPath $File)) {
  Write-Json @{ ok = $false; reason = 'file not found: ' + $File; width = 0; height = 0; nonBlank = 0; samples = 0; regionNonBlank = 0 }
  exit 0
}
$bytes = [System.IO.File]::ReadAllBytes($File)
$magic = if ($bytes.Length -ge 8) { ($bytes[0..7] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' } else { '' }
$img = $null
try { $img = [System.Drawing.Image]::FromFile($File) } catch {
  Write-Json @{ ok = $false; reason = 'not a decodable image: ' + $_.Exception.Message; magic = $magic; bytes = $bytes.Length; width = 0; height = 0; nonBlank = 0; samples = 0; regionNonBlank = 0 }
  exit 0
}
try {
  $bmp = New-Object System.Drawing.Bitmap($img)
  try {
    $nonBlank = 0
    $samples = 0
    $step = [Math]::Max(4, [int]([Math]::Floor([Math]::Min($bmp.Width, $bmp.Height) / 96)))
    for ($x = 0; $x -lt $bmp.Width; $x += $step) {
      for ($y = 0; $y -lt $bmp.Height; $y += $step) {
        $samples++
        $px = $bmp.GetPixel($x, $y)
        # "non-blank" = not near-white and not near-transparent-black padding: a captured UI has
        # chrome, text and buttons; an all-white replacement does not.
        if (($px.R + $px.G + $px.B) -lt 720 -and $px.A -gt 0) { $nonBlank++ }
      }
    }
    $regionNonBlank = 0
    if ($Region) {
      $parts = $Region.Split(',')
      if ($parts.Count -eq 4) {
        $l = [Math]::Max(0, [int]$parts[0] - 1); $t = [Math]::Max(0, [int]$parts[1] - 1)
        $r = [Math]::Min($bmp.Width - 1, [int]$parts[2] + 1); $b = [Math]::Min($bmp.Height - 1, [int]$parts[3] + 1)
        for ($x = $l; $x -le $r; $x += 2) {
          for ($y = $t; $y -le $b; $y += 2) {
            $px = $bmp.GetPixel($x, $y)
            if (($px.R + $px.G + $px.B) -lt 720 -and $px.A -gt 0) { $regionNonBlank++ }
          }
        }
      }
    }
    Write-Json @{
      ok = $true; reason = ''; magic = $magic; bytes = $bytes.Length
      width = $bmp.Width; height = $bmp.Height
      nonBlank = $nonBlank; samples = $samples; regionNonBlank = $regionNonBlank
    }
  } finally { $bmp.Dispose() }
} finally { $img.Dispose() }
exit 0
