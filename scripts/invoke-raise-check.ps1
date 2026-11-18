# invoke-raise-check.ps1 — does a UIA pattern action RAISE its target window?
#
# WHY THIS INSTRUMENT EXISTS. Three earlier runs each reported a foreground change and each
# time attribution could not convict, because the desktop was busy: a change in a round that
# also contained human input goes in the "human" bucket, and with the owner active most of
# the time nearly every round lands there. A channel can be exonerated that way forever
# without ever being proven clean. Raw counts pointed the other way -- UIA Invoke on
# Calculator moved the foreground 8/8 rounds, UIA SetValue on a Chromium page raised the
# browser on round 1 and left it raised afterwards -- but "8/8 raw, 3/8 convicted" is not a
# number a product decision can be made on.
#
# WHY AN IDLE-DESKTOP GATE CANNOT WORK HERE. The first version waited for >=1200ms of
# physical idle and discarded 12/12 rounds. Not a bug: across 6160 sampler rows the LARGEST
# observed GetLastInputInfo age was 109ms. The owner uses this machine continuously, so "wait
# for a quiet desktop" is unsatisfiable by construction and would print "could not tell"
# forever.
#
# WHY GUARDS ALONE ARE NOT ENOUGH -- AND WHAT DOES THE WORK. Sampling "no mouse button down"
# and "cursor never entered the target rect" looks like it excludes human causation. It does
# not: Alt+Tab changes the foreground with no button and no cursor movement, as do Win+number
# and Alt+Esc. So a raise in an apparently clean round is still possibly human, and the clean
# rounds cannot convict by themselves.
#
# The instrument therefore measures the DESKTOP'S OWN RAISE RATE under identical conditions:
# every round is either an ACTION round (Invoke, effect verified by the app itself) or a
# CONTROL round (the same settle, the same guard sampling, the same duration -- and NO call at
# all), interleaved. A raise observed in control rounds is a raise this desktop produces
# without our channel touching anything, and it sets the floor the action arm must beat.
# Conviction is then a comparison, not an absence proof:
#   action raises > control raises  => the channel raises windows
#   action raises == control raises => nothing in this run distinguishes the channel
# Both arms are additionally restricted to rounds where no mouse button and no Alt/Win key
# was down and the cursor never entered the target rect, so the human mechanisms we CAN
# detect are excluded in both arms equally -- which is what makes the comparison fair rather
# than merely optimistic.
#
# TARGETS ARE OUR OWN WINDOWS. The acting target (WPF) and the foreground holder (WinForms)
# are both windows this script launched, so "some other app did it" cannot be an
# unexamined escape hatch: any residual raise in the control arm is reported as a measured
# base rate, with the forensics to name the window that took the foreground.
param(
  [int]$Rounds = 20,
  [int]$SampleEveryMs = 20,
  [int]$ActionWindowSamples = 40
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $PSScriptRoot 'sampler-hooks.ps1')

function Find-Win([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class IR {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct RC { public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential)] public struct GTI {
    public int cbSize; public int flags; public IntPtr hwndActive; public IntPtr hwndFocus;
    public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret;
    public RC rc;
  }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint id, ref GTI g);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  public static string Cursor() { POINT p; GetCursorPos(out p); return p.x + "," + p.y; }
  public static string Fg() { return GetForegroundWindow().ToInt64().ToString(); }
  public static string Focus() {
    IntPtr fg = GetForegroundWindow();
    uint tid = GetWindowThreadProcessId(fg, IntPtr.Zero);
    GTI g = new GTI(); g.cbSize = Marshal.SizeOf(typeof(GTI));
    if (!GetGUIThreadInfo(tid, ref g)) return fg.ToInt64() + "/ERR";
    return fg.ToInt64() + "/" + g.hwndFocus.ToInt64();
  }
  // Button-DOWN, not "input happened": the down edge is what a click needs.
  public static bool MouseDown() {
    return (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0 ||
           (GetAsyncKeyState(0x04) & 0x8000) != 0 || (GetAsyncKeyState(0x05) & 0x8000) != 0;
  }
  // Alt / Ctrl / the Windows keys. Alt+Tab and Alt+Esc change the FOREGROUND with no mouse
  // at all, so a guard set without these would let a keystroke be mistaken for our channel.
  public static bool ChordKeyDown() {
    return (GetAsyncKeyState(0x11) & 0x8000) != 0 || (GetAsyncKeyState(0x12) & 0x8000) != 0 ||
           (GetAsyncKeyState(0x5B) & 0x8000) != 0 || (GetAsyncKeyState(0x5C) & 0x8000) != 0;
  }
  public static bool CursorInRect(IntPtr h) {
    POINT p; if (!GetCursorPos(out p)) return true;    // unreadable counts as SUSPECT
    RC r; if (!GetWindowRect(h, out r)) return true;   // unknown is never "clean"
    return p.x >= r.l && p.x <= r.r && p.y >= r.t && p.y <= r.b;
  }
  public static string Rect(IntPtr h) {
    RC r; if (!GetWindowRect(h, out r)) return "unreadable";
    return r.l + "," + r.t + "," + r.r + "," + r.b;
  }
}
'@

# ---- the acting target: our own WPF window (UIA-native, no child HWNDs) ----------
$wpfExit = Join-Path $env:TEMP ('wpm-ir-wpf-' + [guid]::NewGuid().ToString('N') + '.stop')
$wpfProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'wpf-target.ps1'), '-HoldMs', '240000', '-ExitFile', "`"$wpfExit`"" -PassThru
$wpf = $null
for ($i = 0; $i -lt 60 -and -not $wpf; $i++) { Start-Sleep -Milliseconds 400; $wpf = Find-Win 'WpmWpfTarget' }
if (-not $wpf) { throw 'WPF target never appeared' }
$wpfH = [IntPtr]$wpf.hwnd
"wpf target: hwnd=$wpfH rect=$([IR]::Rect($wpfH))"

# ---- the foreground holder: our own WinForms window, reclaimable on request ------
$grabExit = Join-Path $env:TEMP ('wpm-ir-grab-' + [guid]::NewGuid().ToString('N') + '.stop')
$grabReGrab = Join-Path $env:TEMP ('wpm-ir-regrab-' + [guid]::NewGuid().ToString('N'))
$grabProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '240000', '-ExitFile', "`"$grabExit`"",
  '-GrabFgAfterMs', '1200', '-ReGrabFile', "`"$grabReGrab`"" -PassThru
$grab = $null
for ($i = 0; $i -lt 60 -and -not $grab; $i++) { Start-Sleep -Milliseconds 400; $grab = Find-Win 'WpmWinFormsTarget' }
if (-not $grab) { throw 'hand-off window never appeared' }
$grabH = [IntPtr]$grab.hwnd
"hand-off window: hwnd=$grabH rect=$([IR]::Rect($grabH))"

function Get-WpfButton([IntPtr]$h) {
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    for ($i = 0; $i -lt [Math]::Min($all.Count, 200); $i++) {
      $ct = ''
      try { $ct = ($all[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
      $nm = ''
      try { $nm = [string]$all[$i].Current.Name } catch { }
      if ($ct -ne 'Button') { continue }
      # The target's own button. It reports its effect in its Name ('Press' -> 'Press(1)'),
      # so the effect oracle is the application, not an inference from the call returning.
      if ($nm -like 'Press*') {
        $bp = $null
        try {
          if ($all[$i].TryGetCurrentPattern([System.Windows.Automation.InvokePatternIdentifiers]::Pattern, [ref]$bp)) {
            return @{ bp = $bp; name = $nm }
          }
        } catch { }
      }
    }
  } catch { }
  return $null
}

$b = Get-WpfButton $wpfH
if (-not $b) { throw 'no Press button resolvable on the WPF target' }
"wpf button: name='$($b.name)'"

$samp = Start-WpmSampler -Hz 20 -Tag 'raise'
if (-not $samp.ok) { throw "sampler failed to record (bootBytes=$($samp.bootBytes)); this instrument cannot work without it" }
"sampler: out=$($samp.out) bootBytes=$($samp.bootBytes)"

function Measure-Round {
  param([string]$Arm)
  # Reclaim the foreground and do NOT proceed unless it is verifiably ours.
  try { Set-Content -LiteralPath $grabReGrab -Value 'x' -Force } catch { }
  $settled = $false
  for ($i = 0; $i -lt 25 -and -not $settled; $i++) {
    if (([IR]::Fg()) -eq $grabH.ToString()) { $settled = $true } else { Start-Sleep -Milliseconds 300 }
  }
  try { Remove-Item -LiteralPath $grabReGrab -Force -ErrorAction SilentlyContinue } catch { }
  if (-not $settled) { return @{ ok = $false; why = 'hand-off never became foreground' } }

  $cur = Get-WpfButton $wpfH
  if (-not $cur) { return @{ ok = $false; why = 'button not re-resolvable' } }

  $mouseDown = $false; $chordDown = $false; $cursorIn = $false
  for ($k = 0; $k -lt 8; $k++) {
    if ([IR]::MouseDown()) { $mouseDown = $true }
    if ([IR]::ChordKeyDown()) { $chordDown = $true }
    if ([IR]::CursorInRect($wpfH)) { $cursorIn = $true }
    Start-Sleep -Milliseconds $SampleEveryMs
  }

  $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $f0 = [IR]::Focus(); $cx0 = [IR]::Cursor()
  $err = ''
  if ($Arm -eq 'action') {
    try { $cur.bp.Invoke() } catch { $err = $_.Exception.Message }
  }
  # BOTH arms spend the same sampling time, so the control arm's window is the same length as
  # the action arm's. Comparing a 30ms control against an 800ms action would manufacture the
  # result, since a raise is more likely to be observed in the longer interval.
  for ($k = 0; $k -lt $ActionWindowSamples; $k++) {
    if ([IR]::MouseDown()) { $mouseDown = $true }
    if ([IR]::ChordKeyDown()) { $chordDown = $true }
    if ([IR]::CursorInRect($wpfH)) { $cursorIn = $true }
    Start-Sleep -Milliseconds $SampleEveryMs
  }
  $f1 = [IR]::Focus(); $cx1 = [IR]::Cursor()
  $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

  $after = Get-WpfButton $wpfH
  $n1 = if ($after) { $after.name } else { 're-read-failed' }
  $eff = ($n1 -ne $cur.name)
  @{ ok = $true; arm = $Arm; effect = $eff; raised = ($f1 -ne $f0)
     tookTarget = (([string]$f1 -split '/')[0] -eq $wpfH.ToString())
     mouseDownSeen = $mouseDown; chordDownSeen = $chordDown; cursorInTargetSeen = $cursorIn
     name0 = $cur.name; name1 = $n1; fg0 = $f0; fg1 = $f1; cursor0 = $cx0; cursor1 = $cx1
     error = $err; t0 = $t0; t1 = $t1; durationMs = $t1 - $t0 }
}

$rows = @()
for ($r = 1; $r -le $Rounds; $r++) {
  # Interleaved, deterministic order: control first, then action. An interleaving driven by
  # a random choice would make it possible (and unfalsifiable) to attribute a bad stretch of
  # desktop activity to whichever arm happened to fall in it.
  foreach ($arm in 'control', 'action') {
    $res = Measure-Round -Arm $arm
    if (-not $res.ok) {
      $rows += [pscustomobject]@{ round = $r; arm = $arm; usable = $false; effect = $false
        raised = $false; tookTarget = $false; mouseDownSeen = $false; chordDownSeen = $false
        cursorInTargetSeen = $false; name0 = ''; name1 = ''; fg0 = ''; fg1 = ''
        cursor0 = ''; cursor1 = ''; error = ''; durationMs = 0; t0 = 0; t1 = 0
        why = $res.why }
      continue
    }
    $clean = (-not $res.mouseDownSeen) -and (-not $res.chordDownSeen) -and (-not $res.cursorInTargetSeen)
    $usable = $clean -and ($arm -eq 'control' -or $res.effect)
    $why = if (-not $clean) {
      $r0 = @(); if ($res.mouseDownSeen) { $r0 += 'mouse' }; if ($res.chordDownSeen) { $r0 += 'chord' }; if ($res.cursorInTargetSeen) { $r0 += 'cursorInRect' }
      'human mechanism observed: ' + ($r0 -join '+')
    } elseif ($arm -eq 'action' -and -not $res.effect) { 'action had no effect' } else { '' }
    $rows += [pscustomobject]@{ round = $r; arm = $arm; usable = $usable; effect = $res.effect
      raised = $res.raised; tookTarget = $res.tookTarget; mouseDownSeen = $res.mouseDownSeen
      chordDownSeen = $res.chordDownSeen; cursorInTargetSeen = $res.cursorInTargetSeen
      name0 = $res.name0; name1 = $res.name1; fg0 = $res.fg0; fg1 = $res.fg1
      cursor0 = $res.cursor0; cursor1 = $res.cursor1; error = $res.error
      durationMs = $res.durationMs; t0 = $res.t0; t1 = $res.t1; why = $why }
  }
  Start-Sleep -Milliseconds 250
}

$stopped = Stop-WpmSampler -S $samp
$samples = $stopped.rows
''
"sample rows=$($samples.Count) stoppedCleanly=$($stopped.graceful)"
''
$rows | ForEach-Object {
  if (-not $_.usable) { "  r$($_.round) $($_.arm) DISCARDED ($($_.why))" }
  elseif ($_.arm -eq 'control') { "  r$($_.round) control  raised=$($_.raised) tookTarget=$($_.tookTarget) fg=$($_.fg0)->$($_.fg1)" }
  else { "  r$($_.round) action   press '$($_.name0)' -> '$($_.name1)' raised=$($_.raised) tookTarget=$($_.tookTarget) fg=$($_.fg0)->$($_.fg1) cursor=$($_.cursor0)->$($_.cursor1)" }
}
''
$ctrl = @($rows | Where-Object { $_.usable -and $_.arm -eq 'control' })
$act = @($rows | Where-Object { $_.usable -and $_.arm -eq 'action' })
$ctrlRaised = @($ctrl | Where-Object { $_.raised }).Count
$ctrlTook = @($ctrl | Where-Object { $_.tookTarget }).Count
$actRaised = @($act | Where-Object { $_.raised }).Count
$actTook = @($act | Where-Object { $_.tookTarget }).Count
$actCursor = @($act | Where-Object { $_.cursor0 -ne $_.cursor1 }).Count
$ctrlCursor = @($ctrl | Where-Object { $_.cursor0 -ne $_.cursor1 }).Count
$disc = @($rows | Where-Object { -not $_.usable })
$byWhy = @{}
foreach ($d in $disc) { $k = if ($d.why) { $d.why } else { 'other' }; if (-not $byWhy.ContainsKey($k)) { $byWhy[$k] = 0 }; $byWhy[$k]++ }

"rounds=$Rounds  usable: control=$($ctrl.Count) action=$($act.Count)  discarded=$($disc.Count)"
foreach ($k in $byWhy.Keys) { "  discarded because $k : $($byWhy[$k])" }
''
"BASE RATE  (no call at all, same duration, human mechanisms excluded): raised=$ctrlRaised/$($ctrl.Count) tookTarget=$ctrlTook cursorMoved=$ctrlCursor"
"ACTION RATE (Invoke, effect verified by the app, same conditions):        raised=$actRaised/$($act.Count) tookTarget=$actTook cursorMoved=$actCursor"
''
# Which window took the foreground in the control arm: named, so the base rate is auditable
# rather than asserted. If the control raises point at windows unrelated to this experiment,
# the desktop is the cause and the action arm's raises of the same size prove nothing.
if ($ctrlRaised -gt 0) {
  'control-arm raises, by destination:'
  foreach ($c in @($ctrl | Where-Object { $_.raised })) {
    $dest = ([string]$c.fg1 -split '/')[0]
    $rev = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
      (Join-Path $PSScriptRoot 'find-window.ps1') -Hwnd $dest 2>$null
    $info = '(unknown)'
    if ($rev) { $j = ($rev | Select-Object -Last 1) | ConvertFrom-Json; $info = "$($j.title) || $($j.cls) || proc=$($j.process)" }
    "  r$($c.round) -> hwnd $dest [$info]"
  }
  ''
}
if ($ctrl.Count -lt 3 -or $act.Count -lt 3) {
  "VERDICT: COULD NOT TELL -- usable rounds control=$($ctrl.Count) action=$($act.Count); at least 3 of each are needed before a comparison means anything. This is the outcome the previous instruments structurally could not print: with a raise observed and no matched base rate, neither conviction nor exoneration is available."
} elseif ($ctrlRaised -gt 0 -and $actRaised -le $ctrlRaised) {
  "VERDICT: NOT ESTABLISHED -- this desktop raised a window on its own in $ctrlRaised/$($ctrl.Count) control rounds where NO call was made, and the action arm raised in $actRaised/$($act.Count). " +
  'The action arm is not distinguishable from the desktop doing it anyway, so the claim "UIA Invoke raises the target" has no support from this run -- and neither does its negation. ' +  'What IS supported: the cursor never moved differently between arms (control ' + $ctrlCursor + ', action ' + $actCursor + ').'
} elseif ($actTook -gt 0 -and $ctrlTook -eq 0) {
  "VERDICT: UIA Invoke RAISED the target window to the foreground in $actTook/$($act.Count) human-mechanism-excluded rounds, while the control arm did it $ctrlTook times in " +
  "$($ctrl.Count) rounds with no call at all. " +
  'With the control arm showing zero, the raise is not the desktop''s own behaviour, so the channel disturbs the desktop by itself. R2.3 (foreground switches = 0) does not hold for ' +
  'the click channel on this toolkit generation, and the go/no-go decision must be made on that sentence.'
} elseif ($actRaised -eq 0 -and $actCursor -eq 0) {
  "VERDICT: UIA Invoke acted with real effect while a DIFFERENT window held the foreground, across $($act.Count) rounds in which no mouse button or Alt/Win key was down and the cursor " +
  "never entered the target: raised 0, tookTarget 0, cursor movement 0 -- against a control base rate of $ctrlRaised/$($ctrl.Count). The click channel is indistinguishable from doing " +
  'nothing to the desktop, which is what R2.3 requires.'
} else {
  "VERDICT: MIXED -- action raised $actRaised/$($act.Count) vs control $ctrlRaised/$($ctrl.Count); tookTarget $actTook vs $ctrlTook; cursor $actCursor vs $ctrlCursor. " +
  'The per-round table is the result; any single rate here would hide which arm broke and why.'
}

foreach ($e in @($wpfExit, $grabExit)) { try { Set-Content -LiteralPath $e -Value 'exit' -Force } catch { } }
Start-Sleep -Milliseconds 900
foreach ($p in @($wpfProc, $grabProc)) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
