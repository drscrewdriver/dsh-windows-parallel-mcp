# overlay-test.ps1 -- measure the task_54 promises, not eyeball them.
#
# THE PROMISES, each one a syscall answer rather than a screenshot:
#   1. the trio is ON the window (ex-style read-back: TOPMOST|NOACTIVATE|TRANSPARENT)
#   2. showing the overlay does not take the foreground (GetForegroundWindow identical before/after)
#   3. the marker is click-THROUGH: WindowFromPoint at the marker's own centre returns a DIFFERENT
#      window -- the one underneath. This is the promise "AI cursor never intercepts your click".
#   4. the hotkey flips the ONE pause flag and the decision table refuses while it is set.
#      (The keypress itself is a physical event; this run posts WM_HOTKEY to the overlay window,
#      which is the same message the OS posts -- the hook cannot tell them apart, and the test
#      does not need the owner's keyboard.)
#   5. the marker auto-hides (timer) and Stop leaves nothing behind.
#
# Arm 3 needs a window UNDER the marker at a known point: a real topmost band member (uTools/
# taskbar) is not guaranteed present, so the test creates its own WinForms base window, parks the
# marker over it, and checks the hit still lands on the base.
param([int]$WaitMs = 4000)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\src\engine\engine.ps1')
. (Join-Path $PSScriptRoot '..\src\engine\overlay.ps1')

function Find-WpmWindow([string]$titlePart) {
  # NO GetNewClosure here, deliberately: measured in .tmp/ovdbg2.ps1, a closure snapshot rebinds
  # $script: to the snapshot's own scope, so the accumulator wrote into a copy the caller could
  # never read -- hits stayed 0 while the plain script-scope pattern (the one Get-WpmWindowList
  # uses, and which found the window in the same run) returned it. The needle travels through a
  # script-scope variable instead of a captured parameter, which keeps the callback and the
  # accumulator in the same, real scope.
  $script:WpmOvNeedle = $titlePart
  $script:WpmOvHit = @()
  $cb = [WpmWin+EnumProc] {
    param([IntPtr]$h, [IntPtr]$l)
    $t = [WpmWin]::Txt($h)
    if ($t -and $t.StartsWith($script:WpmOvNeedle)) { $script:WpmOvHit += [int64]$h }
    return $true
  }
  [void][WpmWin]::EnumWindows($cb, [IntPtr]::Zero)
  if ($script:WpmOvHit.Count) { return [IntPtr]$script:WpmOvHit[0] }
  return [IntPtr]::Zero
}

$pass = 0; $fail = 0; $skip = 0
function Assert-Ov([string]$name, [bool]$cond, [string]$detail = '') {
  if ($cond) { $script:pass++; "  PASS  $name" }
  else { $script:fail++; "  FAIL  $name$(if($detail){" :: $detail"})" }
}

'--- overlay promises (task_54) ---'

# base window to sit under the marker
$exitF = Join-Path $env:TEMP ('wpm-ov-base-' + [guid]::NewGuid().ToString('N') + '.stop')
$baseProc = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA',
  '-File', (Join-Path $PSScriptRoot '..\scripts\winforms-target.ps1'), '-HoldMs', '60000',
  '-ExitFile', "`"$exitF`"", '-Title', 'WpmOvBase', '-X', '300', '-Y', '300' -PassThru
$base = [IntPtr]::Zero
for ($i = 0; $i -lt 40 -and $base -eq [IntPtr]::Zero; $i++) {
  Start-Sleep -Milliseconds 300
  $base = Find-WpmWindow 'WpmOvBase'
}
if ($base -eq [IntPtr]::Zero) { throw 'base window never appeared' }

# 1+2: start, read back styles, foreground unchanged.
# A HUMAN USING THE MACHINE IS A SKIP, NOT A FAILURE. This arm asks "did Show() steal focus", and
# the owner pressing Alt+Tab in the same second is indistinguishable from the overlay doing it.
# GetLastInputInfo tells the two apart -- if real input happened inside the window, the arm cannot
# answer its question and says so instead of blaming the product (or, worse, passing by luck).
$ageBefore = [WpmWin]::LastInputAgeMs()
$fgBefore = [WpmWin]::Fg()
[void](Start-WpmOverlay)
$st = Get-WpmOverlayState -WaitMs $WaitMs
Assert-Ov 'overlay running' $st.running $st.reason
Assert-Ov 'ex-style TOPMOST set' $st.topmost $st.exStyle
Assert-Ov 'ex-style NOACTIVATE set' $st.noActivate $st.exStyle
Assert-Ov 'ex-style TRANSPARENT set' $st.transparent $st.exStyle
$fgAfter = [WpmWin]::Fg()
$ageAfter = [WpmWin]::LastInputAgeMs()
$humanInWindow = ($ageAfter -ge 0 -and $ageAfter -lt 1200)
if ($fgBefore -eq $fgAfter) {
  Assert-Ov 'Show() did not take the foreground' $true ''
} elseif ($humanInWindow) {
  $skip++
  "  SKIP  Show() did not take the foreground: foreground changed while real input was $ageAfter ms old -- cannot attribute it to Show()"
} else {
  Assert-Ov 'Show() did not take the foreground' $false "before=$fgBefore after=$fgAfter lastInputAgeMs=$ageAfter"
}

# 3: click-through. Park the marker over the base window's centre and hit-test that point.
# GUARD AGAINST A FALSE GREEN: WindowFromPoint over a point where the marker is NOT is trivially
# the window underneath, so this arm first proves the marker is actually parked on that point
# (position read on the UI thread -- a cross-thread read of WPF Left is not a measurement).
$rb = New-Object 'WpmWin+RECT'
[void][WpmWin]::GetWindowRect($base, [ref]$rb)
$px = [int](($rb.Left + $rb.Right) / 2)
$py = [int](($rb.Top + $rb.Bottom) / 2) - 20
[void](Set-WpmOverlayMarker -X $px -Y $py)
Start-Sleep -Milliseconds 250
# The promise is "the marker covers the point the action touched", in PHYSICAL pixels -- the unit
# the engine gets from Win32 and the unit GetWindowRect reports. Comparing against px-11 assumed a
# 100% display and was wrong at 150% (measured: marker at 1131,966 for a target of 765,655), which
# is the DPI bug this arm found. Coverage is the honest assertion: it holds at any scale.
$mk = Get-WpmOverlayMarker
$covers = $mk.ok -and -not $mk.offscreen -and
          ($px -ge $mk.left) -and ($px -le ($mk.left + $mk.width)) -and
          ($py -ge $mk.top) -and ($py -le ($mk.top + $mk.height))
Assert-Ov 'marker is actually parked on the hit-test point' $covers `
  ("marker rect=({0},{1} {2}x{3}) point=({4},{5}) err='{6}'" -f $mk.left, $mk.top, $mk.width, $mk.height, $px, $py, $mk.reason)
$hit = [WpmWin]::WindowFromPoint((New-Object 'WpmWin+POINT' -Property @{ X = $px; Y = $py }))
$hitRoot = if ($hit -ne [IntPtr]::Zero) { [WpmWin]::Root($hit) } else { [IntPtr]::Zero }
Assert-Ov 'click at the marker lands on the window UNDERNEATH' ($hitRoot -eq $base) `
  ("hit={0} root={1} base={2}" -f [int64]$hit, [int64]$hitRoot, [int64]$base)

# 4: WM_HOTKEY -> pause flip -> decision table refuses.
$st2 = Get-WpmOverlayState -WaitMs 200
if ($st2.hotkeyRegistered) {
  $ovh = [IntPtr][int64]$st2.hwnd
  "  INFO  registered hotkey: $($st2.hotkeyLabel)"
  $pausedBefore = [WpmCtl]::Paused
  [void][WpmWin]::PostMessageW($ovh, [WpmWin]::WM_HOTKEY, [IntPtr]$script:WpmHotkeyId, [IntPtr]0)
  Start-Sleep -Milliseconds 400
  $pausedAfter = [WpmCtl]::Paused
  Assert-Ov 'WM_HOTKEY flips the pause flag' ($pausedBefore -ne $pausedAfter) "before=$pausedBefore after=$pausedAfter"
  if ($pausedAfter) {
    $r = Invoke-WpmAction -Hwnd ([string][int64]$base) -Action click -X $px -Y $py
    Assert-Ov 'paused engine refuses with code' ($r.refusal -eq 'paused') "refusal='$($r.refusal)'"
    [void][WpmWin]::PostMessageW($ovh, [WpmWin]::WM_HOTKEY, [IntPtr]$script:WpmHotkeyId, [IntPtr]0)
    Start-Sleep -Milliseconds 400
    Assert-Ov 'second press unpauses' (-not [WpmCtl]::Paused) ''
  }
} else {
  $skip++
  "  SKIP  hotkey arms: RegisterHotKey failed (Ctrl+Alt+Q held elsewhere) -- $($st2.reason)"
}

# 5: auto-hide and clean stop. Re-place the marker FIRST so the countdown starts from a known
# instant (the hotkey arms above take a variable amount of time). The promise is "1.5s from the
# last placement", so: visible right after placement, gone after 1.5s+. Both reads are marshalled
# to the UI thread.
[void](Set-WpmOverlayMarker -X $px -Y $py)
Start-Sleep -Milliseconds 250
$mkEarly = Get-WpmOverlayMarker
Assert-Ov 'marker still visible right after being placed (countdown is not free-running)' (-not $mkEarly.offscreen) `
  ("left={0} top={1} err='{2}'" -f $mkEarly.left, $mkEarly.top, $mkEarly.reason)
# Poll rather than sleep-then-look: the marker is hidden by a 16ms dispatcher timer, and a busy
# desktop can delay that tick. A single 1900ms sample made this arm flaky (one gate run failed with
# the marker still at 749,639 while two consecutive standalone runs passed). The assertion is still
# "it goes away on its own", just with a bounded wait instead of one lucky instant.
$deadline = [DateTime]::UtcNow.AddMilliseconds(3500)
$mkLate = Get-WpmOverlayMarker
while (-not $mkLate.offscreen -and [DateTime]::UtcNow -lt $deadline) {
  Start-Sleep -Milliseconds 200
  $mkLate = Get-WpmOverlayMarker
}
Assert-Ov 'marker auto-hides after the timer' $mkLate.offscreen ("left={0} top={1}" -f $mkLate.left, $mkLate.top)
[void](Stop-WpmOverlay)
Start-Sleep -Milliseconds 400
$st4 = Get-WpmOverlayState -WaitMs 200
Assert-Ov 'stop leaves nothing running' (-not $st4.running -and $st4.hwnd -eq '0') "state=$($st4 | ConvertTo-Json -Compress)"

# cleanup base
Set-Content -LiteralPath $exitF -Value 'stop' -Encoding ascii
for ($i = 0; $i -lt 20 -and -not $baseProc.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
if (-not $baseProc.HasExited) { try { $baseProc.Kill() } catch { } }
Remove-Item -LiteralPath $exitF -ErrorAction SilentlyContinue

''
"overlay-test: $pass passed, $fail failed, $skip skipped"
if ($fail -gt 0) { exit 1 }
exit 0
