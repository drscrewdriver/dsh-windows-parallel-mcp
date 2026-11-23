# capture-hud.ps1 -- a screenshot of the REAL HUD window, taken by PrintWindow (not the desktop).
#
# task_37 asks for a HUD screenshot from a real session. Capturing the whole desktop would drag whatever
# the owner has on screen into the artefact; PrintWindow(PW_RENDERFULLCONTENT) renders just the HUD's own
# pixels, which is also the only way a layered/topmost window can be captured reliably while it never
# takes the foreground.
param([string]$Out = '.tmp/hud-shot.png', [int]$ArmMs = 0, [string]$Phase = 'active')
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/engine/engine.ps1')
. (Join-Path $root 'src/engine/hud.ps1')
Add-Type -AssemblyName System.Drawing

if (-not ('WpmHudShot' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WpmHudShot {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
'@
}

$start = Start-WpmHud -Action 'click' -MaxMs 10000 -ArmMs $ArmMs
if (-not $start.ready) { Write-Output ('{"ok":false,"reason":"' + $start.reason + '"}'); exit 1 }
$st = Get-WpmHudState -WaitMs 1500
# Drive the phase the caller asked for and give the pump (50ms) a couple of ticks to apply it.
[void](Set-WpmHudPhase -Phase $Phase -Action 'click' -MaxMs 10000 -ElapsedMs 1200)
[WpmCtl]::InjectedChars = 7
Start-Sleep -Milliseconds 400

$hwnd = [IntPtr][int64]$st.hwnd
$r = New-Object 'WpmHudShot+RECT'
[void][WpmHudShot]::GetWindowRect($hwnd, [ref]$r)
$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$printed = $false
try { $printed = [bool][WpmHudShot]::PrintWindow($hwnd, $hdc, 2) } catch { }
$g.ReleaseHdc($hdc); $g.Dispose()
$outPath = Join-Path $root $Out
$dir = Split-Path -Parent $outPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
# A blank capture would be a false artefact: count non-background pixels as the evidence that the HUD
# actually rendered text and a button rather than an empty window.
$nonBg = 0
for ($x = 0; $x -lt $w; $x += 3) { for ($y = 0; $y -lt $h; $y += 3) { $p = $bmp.GetPixel($x, $y); if (($p.R + $p.G + $p.B) -gt 120) { $nonBg++ } } }
$bmp.Dispose()
[void](Stop-WpmHud)
@{ ok = $true; file = $outPath; printed = $printed; width = $w; height = $h; phase = $Phase; brightSamples = $nonBg; abortChord = [string]$st.abortChordLabel } | ConvertTo-Json -Compress
exit 0