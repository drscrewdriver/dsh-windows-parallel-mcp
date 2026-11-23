# hud-test.ps1 -- the HUD's promises, measured: a window that exists with the right ex-style, does not
# take the foreground, reports its phase, carries a stop button wired to the ONE abort flag, and reports
# the chord that actually registered. (spec.md §2, C6/C7/C13)
#
# WHY THE ABORT CHORD IS ASSERTED AGAINST THE CANDIDATE TABLE instead of against "Ctrl+Alt+X": this
# desktop already owns the documented pause chord, so a fixed expectation would either fail on a busy
# machine or pass while showing a chord nobody can press. The assertion is "the label equals one of the
# candidates that RegisterHotKey accepted" -- i.e. it is not inventing a key.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/engine/win.ps1')
. (Join-Path $root 'src/engine/hud.ps1')

# PW_RENDERFULLCONTENT (2): the phase-colour arm below reads the HUD's own pixels, and a layered window
# does not paint through a plain WM_PRINT.
if (-not ('WpmHudPixel' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WpmHudPixel {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
'@
}

$pass = 0
$fail = 0
$skips = 0
function Ok([string]$name, [bool]$cond, [string]$detail = '') {
  if ($cond) { $script:pass++; Write-Output ("  PASS  " + $name) }
  else { $script:fail++; Write-Output ("  FAIL  " + $name + $(if ($detail) { ' :: ' + $detail } else { '' })) }
}
function Skip([string]$name, [string]$why) { $script:skips++; Write-Output ("  SKIP  " + $name + ' :: ' + $why) }
function Close($s) { if ($null -ne $s) { try { $s.Close() } catch { } } }

[WpmCtl]::TakeoverAbort = $false
$fgBefore = [WpmWin]::Fg()
$start = Start-WpmHud -Action 'hud-test' -MaxMs 5000 -ArmMs 0
Ok 'Start-WpmHud reports ready' ([bool]$start.ready) ([string]$start.reason)
$st = Get-WpmHudState -WaitMs 1500
Ok 'HUD is running' ([bool]$st.running) ([string]$st.reason)
Ok 'HUD has a real hwnd' ($st.hwnd -ne '0') $st.hwnd
Ok 'ex-style has WS_EX_TOPMOST' ([bool]$st.topmost) $st.exStyle
Ok 'ex-style has WS_EX_NOACTIVATE (it must never take the keyboard)' ([bool]$st.noActivate) $st.exStyle
Ok 'ex-style has NO WS_EX_TRANSPARENT (the button must stay clickable)' (-not [bool]$st.transparent) $st.exStyle
$fgAfter = [WpmWin]::Fg()
Ok 'C6: the foreground is unchanged across HUD start' ($fgBefore -eq $fgAfter) ("before=" + $fgBefore + ' after=' + $fgAfter)
Ok 'Test-WpmHudReady agrees the HUD is up' ([bool](Test-WpmHudReady))

# C7: the chord shown is the chord that registered.
$labels = @($script:WpmAbortChords | ForEach-Object { [string]$_.label })
if ($st.abortChordRegistered) {
  Ok 'C7: the abort chord label is one of the candidates that can be registered' ($labels -contains [string]$st.abortChordLabel) ([string]$st.abortChordLabel)
  Write-Output ('  INFO  abort chord registered: ' + $st.abortChordLabel)
} else {
  Skip 'C7: no abort chord registered on this desktop' 'the HUD must then show the degraded text instead of a fake key'
  Ok 'C7 degraded: the label is empty rather than invented' ([string]::IsNullOrEmpty([string]$st.abortChordLabel)) ([string]$st.abortChordLabel)
}

# C13: three phases, each readable from the same fields the pump applies.
foreach ($phase in @('arming', 'active', 'done')) {
  Set-WpmHudPhase -Phase $phase -Action 'hud-test' -MaxMs 5000 -ElapsedMs 1200 | Out-Null
  Start-Sleep -Milliseconds 120
  $now = Get-WpmHudState -WaitMs 100
  Ok ("C13: phase '" + $phase + "' is readable back") ([string]$now.phase -eq $phase) ([string]$now.phase)
}

# C18: THE THREE PHASES MUST BE TELLABLE APART BY COLOUR, not only by their words. The owner is looking at
# the target window while an agent borrows their pointer; reading a sentence on a 470x104 window at the
# screen edge is not something to rely on. The assertion reads the real pixels: the accent bar (5px on the
# left edge) must be amber-ish while arming, red-dominant while active, and green-dominant once returned.
$script:PhaseColour = {
  param([string]$phase)
  Set-WpmHudPhase -Phase $phase -Action 'hud-test' -MaxMs 5000 -ElapsedMs 800 | Out-Null
  Start-Sleep -Milliseconds 200
  $h = [IntPtr][int64][WpmCtl]::HudHwnd
  if ($h -eq [IntPtr]::Zero) { return $null }
  $rc = New-Object 'WpmHudPixel+RECT'
  [void][WpmHudPixel]::GetWindowRect($h, [ref]$rc)
  $w = $rc.Right - $rc.Left; $hh = $rc.Bottom - $rc.Top
  if ($w -le 0 -or $hh -le 0) { return $null }
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap($w, $hh)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  try { [void][WpmHudPixel]::PrintWindow($h, $hdc, 2) } catch { }
  $g.ReleaseHdc($hdc); $g.Dispose()
  $bar = $bmp.GetPixel(2, [int]($hh / 2))
  $bg = $bmp.GetPixel([int]($w / 2), [int]($hh / 2) - 20)
  $bmp.Dispose()
  return @{ bar = @([int]$bar.R, [int]$bar.G, [int]$bar.B); bg = @([int]$bg.R, [int]$bg.G, [int]$bg.B) }
}
$cArm = & $script:PhaseColour 'arming'
$cAct = & $script:PhaseColour 'active'
$cDone = & $script:PhaseColour 'done'
if ($cArm -and $cAct -and $cDone) {
  # Amber: red and green both high, blue low -- the one hue that cannot be confused with the other two.
  Ok 'C18: arming is amber (red+green high, blue low)' ($cArm.bar[0] -gt 180 -and $cArm.bar[1] -gt 120 -and $cArm.bar[2] -lt 90) (($cArm.bar) -join ',')
  # Red: red dominant by a clear margin.
  Ok 'C18: active is red-dominant' ($cAct.bar[0] -gt 180 -and $cAct.bar[0] -gt ($cAct.bar[1] + 100) -and $cAct.bar[0] -gt ($cAct.bar[2] + 100)) (($cAct.bar) -join ',')
  # Green: green dominant by a clear margin.
  Ok 'C18: done is green-dominant' ($cDone.bar[1] -gt 150 -and $cDone.bar[1] -gt ($cDone.bar[0] + 80) -and $cDone.bar[1] -gt ($cDone.bar[2] + 60)) (($cDone.bar) -join ',')
  Ok 'C18: the three accent colours are distinct' (($cArm.bar -join ',') -ne ($cAct.bar -join ',') -and ($cAct.bar -join ',') -ne ($cDone.bar -join ','))
  Ok 'C18: the surface tint changes with the phase too (a second channel, not only the bar)' (($cArm.bg -join ',') -ne ($cAct.bg -join ',') -and ($cAct.bg -join ',') -ne ($cDone.bg -join ',')) (('arming=' + ($cArm.bg -join ',')) + ' active=' + ($cAct.bg -join ',') + ' done=' + ($cDone.bg -join ','))
} else {
  $skips++
  '  SKIP  C18: could not read the HUD pixels for the phase-colour arms'
}

# The stop button writes the ONE abort flag. The click handler is asserted structurally here (sending a
# real mouse click from a test would need the pointer, and this file must not move it); the flag itself is
# what the engine reads, and its effect is measured in takeover-test.ps1.
$hudBody = Get-Content -Raw (Join-Path $root 'src/engine/hud.ps1')
Ok 'the stop button is wired to [WpmCtl]::TakeoverAbort' ($hudBody -match '\$btn\.Add_Click\(\{\s*\[WpmCtl\]::TakeoverAbort = \$true\s*\}\)')
Ok 'the abort chord handler writes the same flag' ($hudBody -match 'WM_HOTKEY' -and $hudBody -match '\[WpmCtl\]::TakeoverAbort = \$true')
[WpmCtl]::TakeoverAbort = $true
$armed = Get-WpmHudState -WaitMs 100
Ok 'the abort request is visible to the engine while the HUD runs' ([bool]$armed.abortRequested)
[WpmCtl]::TakeoverAbort = $false

$stop = Stop-WpmHud
Ok 'Stop-WpmHud completes' ([bool]$stop.completed) ([string]$stop.state.reason)
Start-Sleep -Milliseconds 150
$after = Get-WpmHudState -WaitMs 200
Ok 'the HUD is gone after Stop' (-not [bool]$after.running)
Ok 'Test-WpmHudReady is false after Stop' (-not [bool](Test-WpmHudReady))
$fgEnd = [WpmWin]::Fg()
Ok 'C6b: the foreground is unchanged across HUD teardown' ($fgBefore -eq $fgEnd) ("start=" + $fgBefore + ' end=' + $fgEnd)

Write-Output ('hud-test: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:skips + ' skipped')
if ($script:fail -gt 0) { exit 1 }
exit 0
