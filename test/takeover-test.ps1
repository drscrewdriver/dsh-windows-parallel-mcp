# takeover-test.ps1 -- the takeover tier's invariants, measured on a target this file owns. (spec.md §3)
#
# THE INVARIANTS THIS FILE PINS (spec.md §3, "six invariants", the ones reachable without a terminal):
#   I1  the cursor is back where it started before any return, including the refused and interrupted paths
#   I3  an interruption returns to the pre-action cursor AND reports takeover_aborted
#   I4  with takeover off, the cursor never moves (the 0.1.6 promise still holds by default)
#   I5  injection outside the takeover tier is refused, not attempted
# Plus C2/C4 (restore on the normal and the interrupted path) and the decision arms for the two new
# decision-layer codes.
#
# WHY THE TARGET IS CREATED HERE. A test that borrows the owner's windows can pass by acting on the wrong
# one; a form this file creates has a known rect, a known button, and no owner in it. It is a WinForms
# form on purpose: that family has a message door, so the click goes through the cheap channel and the
# test measures the takeover overhead rather than a UIA flash.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/engine/engine.ps1')
# The latch helper lives in takeover.ps1, which the ENGINE only loads inside the takeover branch (G2).
# The test loads it up front so it can write the same latch the host half writes on cancellation.
. (Join-Path $root 'src/engine/takeover.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$pass = 0; $fail = 0; $skips = 0
function Ok([string]$name, [bool]$cond, [string]$detail = '') {
  if ($cond) { $script:pass++; Write-Output ("  PASS  " + $name) }
  else { $script:fail++; Write-Output ("  FAIL  " + $name + $(if ($detail) { ' :: ' + $detail } else { '' })) }
}
function Skip([string]$name, [string]$why) { $script:skips++; Write-Output ("  SKIP  " + $name + ' :: ' + $why) }
# Age of the last PHYSICAL input, in ms (-1 when unreadable). The cursor is shared with the owner, so an
# external read of "is the pointer back" can only be graded while nobody else is touching the mouse;
# measured 2026-11-23 with a human at the desk: the same assertion drifted 11 / 213 / 649 px, i.e. the
# FAIL was the instrument reading someone else's motion, not a failed restore. The engine's own
# read-back (cursorAfterX/Y) is the interference-free half of the pair and stays a hard assertion.
function LastInputAgeMs {
  try { return [long][WpmWin]::LastInputAgeMs() } catch { return -1 }
}
# A drift assertion is only gradeable while the pointer was demonstrably ours between the two reads.
function SkipIfOwnerMoved([string]$name, [long]$ElapsedMs, [long]$AgeAtAfter) {
  if ($AgeAtAfter -lt 0) { Skip $name 'the last-input age could not be read, so external motion cannot be ruled out'; return $true }
  if ($AgeAtAfter -lt ($ElapsedMs + 500)) {
    Skip $name ('a physical input arrived within the measured window (age=' + $AgeAtAfter + 'ms, window=' + $ElapsedMs + 'ms); the drift may be the owner''s own motion, so it is not graded')
    return $true
  }
  return $false
}
function CursorXY { $p = New-Object 'System.Drawing.Point'; $p = [System.Windows.Forms.Cursor]::Position; return @($p.X, $p.Y) }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'wpm-takeover-target'
$form.Width = 420; $form.Height = 220
$form.StartPosition = 'Manual'
$form.Left = 180; $form.Top = 200
# TOPMOST because this test must not depend on what happens to be in front: the first run failed with
# "no child window sits under that point" and the probe showed why -- WindowFromPoint returned the
# BROWSER's renderer, i.e. the form was behind another window. The engine's refusal was correct; the test
# was measuring an occluded target.
$form.TopMost = $true
$btn = New-Object System.Windows.Forms.Button
$btn.Text = 'PUSH'
$btn.Width = 120; $btn.Height = 40
$btn.Left = 40; $btn.Top = 40
[void]$form.Controls.Add($btn)
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 250
$hwnd = [WpmWin]::Txt  # keep strict mode quiet about unused helpers
$hwnd = [string]$form.Handle
$bp = $btn.PointToScreen((New-Object System.Drawing.Point(0, 0)))
$clickX = [int]($bp.X + 30); $clickY = [int]($bp.Y + 15)
Write-Output ('  INFO  target hwnd=' + $hwnd + ' click=' + $clickX + ',' + $clickY)

try {
  # ---- I4: the default tier still moves nothing --------------------------------------------
  $c0 = CursorXY
  $plain = Invoke-WpmAction -Hwnd $hwnd -Action click -X $clickX -Y $clickY -SettleMs 80
  $c1 = CursorXY
  Ok 'I4: a plain click succeeds' ([bool]$plain.ok) ([string]$plain.refusal + ' ' + [string]$plain.reason)
  Ok 'I4: a plain click stays on the quiet/message tier' ([string]$plain.tier -eq 'quiet' -or [string]$plain.tier -eq 'bounded-flash') ([string]$plain.tier)
  Ok 'I4: a plain click leaves the cursor exactly where it was' ($c0[0] -eq $c1[0] -and $c0[1] -eq $c1[1]) ('before=' + ($c0 -join ',') + ' after=' + ($c1 -join ','))
  Ok 'I4: a plain click reports no takeover' ([string]$plain.takeover -ne 'true') ([string]$plain.takeover)

  # ---- I1/C2: a takeover click moves the pointer (by request) and puts it back -------------
  $c2 = CursorXY; $c2At = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $tk = Invoke-WpmAction -Hwnd $hwnd -Action click -X $clickX -Y $clickY -SettleMs 80 -Takeover -TakeoverArmMs 0 -HudDoneMs 0 -TakeoverMaxMs 5000
  $c3 = CursorXY; $c3At = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  # How long the external pair of reads spans: the drift assertion is graded only if no physical input
  # landed inside it (see SkipIfOwnerMoved).
  $c2ElapsedMs = $c3At - $c2At
  Ok 'I1: the takeover click succeeds' ([bool]$tk.ok) ([string]$tk.refusal + ' ' + [string]$tk.reason)
  Ok 'I1: the result declares the takeover tier' ([string]$tk.tier -eq 'takeover' -and [string]$tk.takeover -eq 'true') ([string]$tk.tier + '/' + [string]$tk.takeover)
  Ok 'I1: the cursor was actually moved (the move is visible, not a claim)' ([string]$tk.cursorMoved -eq 'true') ([string]$tk.cursorMoved + ' readBack=' + [string]$tk['cursorX'] + ',' + [string]$tk['cursorY'])
  Ok 'C2/I1: cursorRestored is true' ([string]$tk.cursorRestored -eq 'true') ([string]$tk.cursorRestored + ' ' + [string]$tk['cursorRestoreReason'])
  # Two assertions, deliberately: the ENGINE read-backs must be exactly equal (that is the promise the
  # proof layer judges), and the test independent read must be within a few pixels -- because this pointer
  # is shared with the owner, and this very run measured 2px of ambient drift between two reads a second
  # apart (the C4 arm below). An exact external comparison would be a flake generator, not a stronger test.
  Ok 'C2: the engine restored to the point it saved (exact read-back)' ([int]$tk['cursorAfterX'] -eq [int]$tk['cursorBeforeX'] -and [int]$tk['cursorAfterY'] -eq [int]$tk['cursorBeforeY']) ([string]$tk['cursorBeforeX'] + ',' + [string]$tk['cursorBeforeY'] + ' -> ' + [string]$tk['cursorAfterX'] + ',' + [string]$tk['cursorAfterY'])
  $driftPx = [Math]::Max([Math]::Abs($c3[0] - $c2[0]), [Math]::Abs($c3[1] - $c2[1]))
  if (-not (SkipIfOwnerMoved 'C2: the cursor is back at the pre-action point (within ambient drift <= 4px)' $c2ElapsedMs (LastInputAgeMs))) {
    Ok 'C2: the cursor is back at the pre-action point (within ambient drift <= 4px)' ($driftPx -le 4) ('before=' + ($c2 -join ',') + ' after=' + ($c3 -join ',') + ' drift=' + $driftPx)
  }
  Ok 'I1: the HUD window existed during the action' ([string]$tk['hudHwnd'] -ne '0' -and [string]$tk['hudHwnd'] -ne '') ([string]$tk['hudHwnd'])
  Ok 'I1: a takeover result names the abort chord it actually registered' ([string]::IsNullOrEmpty([string]$tk['abortChord']) -or [string]$tk['abortChord'] -match '^Ctrl\+') ([string]$tk['abortChord'])
  Ok 'C13: the action took at least the arming clock in measured time' ([int]$tk.takeoverMs -ge 0) ([string]$tk.takeoverMs)

  # ---- I3/C4: interruption during arming --------------------------------------------------
  $c4 = CursorXY; $c4At = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $latch = Get-WpmTakeoverLatchPath
  $job = Start-Job -ScriptBlock {
    param($p)
    Start-Sleep -Milliseconds 350
    $d = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    Set-Content -LiteralPath $p -Value 'abort' -Encoding ASCII
  } -ArgumentList $latch
  $ab = Invoke-WpmAction -Hwnd $hwnd -Action click -X $clickX -Y $clickY -SettleMs 80 -Takeover -TakeoverArmMs 2000 -HudDoneMs 0 -TakeoverMaxMs 5000
  $c5 = CursorXY; $c5At = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $c4ElapsedMs = $c5At - $c4At
  [void](Wait-Job $job -Timeout 5); Remove-Job $job -Force -ErrorAction SilentlyContinue
  Ok 'I3: the interrupted takeover reports takeover_aborted' ([string]$ab.refusal -eq 'takeover_aborted') ([string]$ab.refusal + ' ' + [string]$ab.reason)
  Ok 'C4/I3: the interrupted takeover reports cursorRestored=true' ([string]$ab.cursorRestored -eq 'true') ([string]$ab.cursorRestored)
  Ok 'C4: the interrupted takeover reports its own restore read-back as equal' ([int]$ab['cursorAfterX'] -eq [int]$ab['cursorBeforeX'] -and [int]$ab['cursorAfterY'] -eq [int]$ab['cursorBeforeY']) ([string]$ab['cursorBeforeX'] + ',' + [string]$ab['cursorBeforeY'] + ' -> ' + [string]$ab['cursorAfterX'] + ',' + [string]$ab['cursorAfterY'])
  $drift4 = [Math]::Max([Math]::Abs($c5[0] - $c4[0]), [Math]::Abs($c5[1] - $c4[1]))
  if (-not (SkipIfOwnerMoved 'C4: the interrupted takeover left the cursor where it was (within ambient drift <= 4px)' $c4ElapsedMs (LastInputAgeMs))) {
    Ok 'C4: the interrupted takeover left the cursor where it was (within ambient drift <= 4px)' ($drift4 -le 4) ('before=' + ($c4 -join ',') + ' after=' + ($c5 -join ',') + ' drift=' + $drift4)
  }
  Ok 'I3: the interrupted takeover reports how many characters went out (zero for a click)' ([int]$ab.injectedChars -eq 0) ([string]$ab.injectedChars)
  Remove-Item -LiteralPath $latch -Force -ErrorAction SilentlyContinue

  # ---- I5: injection is refused outside the takeover tier ----------------------------------
  $inj = Invoke-WpmAction -Hwnd $hwnd -Action type -Text 'x' -KeyInject -SettleMs 80
  Ok 'I5: keyInput without takeover is refused' ([string]$inj.refusal -eq 'keyinject_unavailable') ([string]$inj.refusal + ' ' + [string]$inj.reason)

  # ---- the decision arms -------------------------------------------------------------------
  $f1 = New-WpmFacts -Hwnd $hwnd -FactsMeasured $true -MessageDoor $true -TakeoverRequested $true -HudReady $false
  $d1 = Get-WpmChannelDecision $f1
  Ok 'decision: takeover without a HUD is takeover_unavailable' ([string]$d1.refusal -eq 'takeover_unavailable') ([string]$d1.refusal)
  $f2 = New-WpmFacts -Hwnd $hwnd -FactsMeasured $true -MessageDoor $true -TakeoverRequested $true -HudReady $true -KeyInjectRequested $true -KeyInjectAllowed $true -ForegroundIsTarget $false
  $d2 = Get-WpmChannelDecision $f2
  Ok 'decision: injection with the target not in the foreground is keyinject_unavailable' ([string]$d2.refusal -eq 'keyinject_unavailable') ([string]$d2.refusal)
  # The terminal path is REFUSED even with a full takeover+inject request, because both injection arms were
  # measured not to reach this host terminal (findings G3). This arm pins the withdrawal: if someone
  # re-enables the path, this test goes red and the decision has to be re-argued with new evidence.
  $f3 = New-WpmFacts -Hwnd $hwnd -FactsMeasured $true -Family 'terminal' -TakeoverRequested $true -HudReady $true -KeyInjectRequested $true -KeyInjectAllowed $true -ForegroundIsTarget $true
  $d3 = Get-WpmChannelDecision $f3
  Ok 'decision: a terminal with takeover+inject STILL refuses (injection measured ineffective there)' ([string]$d3.channel -eq 'refuse' -and [string]$d3.refusal -eq 'terminal_no_door') ([string]$d3.channel + '/' + [string]$d3.tier + ' ' + [string]$d3.refusal)

  # A doorless NON-terminal target is the case injection is still offered for: the foreground assertion
  # passed, the HUD is up, and no cheaper door exists.
  $f3b = New-WpmFacts -Hwnd $hwnd -FactsMeasured $true -Family 'chromium' -TakeoverRequested $true -HudReady $true -KeyInjectRequested $true -KeyInjectAllowed $true -ForegroundIsTarget $true
  $d3b = Get-WpmChannelDecision $f3b
  Ok 'decision: a doorless non-terminal with takeover+inject becomes the input channel' ([string]$d3b.channel -eq 'input' -and [string]$d3b.tier -eq 'takeover') ([string]$d3b.channel + '/' + [string]$d3b.tier + ' ' + [string]$d3b.refusal)
  $f4 = New-WpmFacts -Hwnd $hwnd -FactsMeasured $true -Family 'terminal' -TakeoverRequested $true -HudReady $true
  $d4 = Get-WpmChannelDecision $f4
  Ok 'decision: a terminal without keyInput still returns the diagnostic code' ([string]$d4.refusal -eq 'terminal_no_door') ([string]$d4.refusal)
  $f5 = New-WpmFacts -Hwnd $hwnd -FactsMeasured $true -MessageDoor $true -TakeoverRequested $true -HudReady $true
  $d5 = Get-WpmChannelDecision $f5
  Ok 'decision: takeover over a message door keeps the cheap channel and takes the takeover tier' ([string]$d5.channel -eq 'message' -and [string]$d5.tier -eq 'takeover') ([string]$d5.channel + '/' + [string]$d5.tier)
} finally {
  try { $form.Close() } catch { }
}

Write-Output ('takeover-test: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:skips + ' skipped')
if ($script:fail -gt 0) { exit 1 }
exit 0
