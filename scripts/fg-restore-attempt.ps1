# fg-restore-attempt.ps1 — can the foreground damage a UIA pattern does be UNDONE, quietly?
#
# WHY THIS IS THE RIGHT QUESTION NOW. The G0 verdict killed the general claim because UIA
# Invoke / SetValue raise their own window (6/6 and 12/12 with zero physical input). The one
# remaining way that could still rescue a UIA-channel product is not preventing the raise -- a
# separate-process driver does not decide what an in-process UIA provider does when it sets
# focus -- but REVERSING it fast enough that the user never experiences it. That is measurable,
# so it is measured here instead of argued.
#
# THREE ARMS, and why two controls are both needed:
#   control  -- no call at all. Catches ambient foreground drift on this desktop.
#   persist  -- raise, then DON'T touch. THE decisive control: if WPF's own raise self-reverts,
#               a 'restore worked' reading would be crediting my SetForegroundWindow for a
#               problem the app fixed by itself. Only by seeing the raise STAND through persist
#               does 'restore clears it' become a causal effect rather than an ambient one.
#   restore  -- raise, then reverse immediately. Compared against persist, not against control.
#
# WHY AttachThreadInput IS TRIED. Handing the foreground back with a bare SetForegroundWindow
# was rejected earlier and correctly: the foreground lock lets only the process owning the
# current foreground, or that received the last input event, call it (measured: 30/36 refused).
# But AttachThreadInput -- joining the input queue of the thread owning the CURRENT foreground,
# after which the call is made inside that context -- is the documented unlock and was NEVER
# tested here. Rejecting it on the strength of the bare-call result would repeat this project's
# signature error: declaring a door locked because one key did not fit.
#
# WHAT IS DELIBERATELY NOT TRIED: the keybd_event/SendInput Alt-trick that many automation
# tools use to clear the foreground lock. Not measured because it is not allowed by this
# project's own stance -- it injects a real event into the input stream, which A1 forbids and
# which would drop the user's next keystroke into whatever window the trick just activated.
# Recorded as 'rejected by stance, never tested', not as 'known not to work'.
#
# OWN WINDOWS ONLY. The target is the WPF probe this repo created. Restore is attempted ONLY
# when our OWN target holds the foreground; if a third window (the user's Alt+Tab) took it, the
# round is discarded and NOT touched -- calling SetForegroundWindow(prevFg) there would yank
# the user off whatever they just chose and act on a window this repo never created.
param(
  [int]$Rounds = 6,
  [int]$WaitMs = 20000
)
$ErrorActionPreference = 'Stop'
foreach ($sw in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.2', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.3') {
  try { [AppContext]::SetSwitch($sw, $false) } catch { }
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $PSScriptRoot 'sampler-hooks.ps1')
function Find-Win([string]$m) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $m 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}
# Identify the window that owns the foreground, by title + class, so the persist arm's
# variance can be ATTRIBUTED rather than just observed. The adjacent-run flip (fgr3: raise
# persists 4/4; fgr4: self-reverts 4/6) is very likely not my cleanup but the IDENTITY of
# prevFg: if the previously-foreground window belongs to an app that re-activates itself
# (the DSH host, a browser, anything with its own focus policy), the raise appears to
# 'self-revert' because that app takes the foreground back -- real behaviour, not an
# artifact. Characterizing the confound is the point; another re-roll without it proves
# nothing new.
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Who {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  public static string Title(IntPtr h){var s=new StringBuilder(512);GetWindowTextW(h,s,s.Capacity);return s.ToString();}
  public static string Class(IntPtr h){var s=new StringBuilder(256);GetClassNameW(h,s,s.Capacity);return s.ToString();}
}
'@
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FG {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool join);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  public static string Fg() { return GetForegroundWindow().ToInt64().ToString(); }
  public static IntPtr FgHandle() { return GetForegroundWindow(); }
  public static string Cursor() { POINT p; GetCursorPos(out p); return p.x + "," + p.y; }
  public static uint ThreadOf(IntPtr h) { uint pid; return GetWindowThreadProcessId(h, out pid); }
  public static uint Mine() { return GetCurrentThreadId(); }
  // Release OUR OWN window's foreground claim when it is stuck on top after a round whose
  // restore target had since closed (SetForegroundWindow to a dead handle silently fails, and
  // every following round then sees the target foreground and self-discards -- the cascade that
  // ate half the previous run). Minimizing releases the foreground to whatever window is next,
  // and SW_SHOWNA restores it to VISIBLE-BACKGROUND in the same breath, so the target is in its
  // normal state for the next arm. Both calls act only on the window this process created, and
  // neither is an activation, so neither needs the foreground permission this whole script is
  // otherwise fighting for.
  public static bool ReleaseOurs(IntPtr h) { ShowWindow(h, 6); ShowWindow(h, 8); return true; }
  public static bool Join(uint other) { return AttachThreadInput(Mine(), other, true); }
  public static bool Leave(uint other) { return AttachThreadInput(Mine(), other, false); }
}
'@

$exitF = Join-Path $env:TEMP ('wpm-fgr-wpf-' + [guid]::NewGuid().ToString('N') + '.stop')
$proc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'wpf-target.ps1'), '-HoldMs', '600000', '-ExitFile', "`"$exitF`"" -PassThru
$w = $null
for ($i = 0; $i -lt [int]($WaitMs / 400) -and -not $w; $i++) { Start-Sleep -Milliseconds 400; $w = Find-Win 'WpmWpfTarget' }
if (-not $w) { throw 'WPF target never appeared' }
$actH = [IntPtr]$w.hwnd
$actHs = $actH.ToInt64().ToString()
"target: hwnd=$actHs"

$btn = $null; $edit = $null
try {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($actH)
  $btn = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Button)))
  $edit = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit)))
} catch { "UIA mapping threw: $($_.Exception.Message)" }
$patInvoke = $null; $patValue = $null
try {
  if ($btn) { [void]$btn.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$patInvoke) }
  if (-not $patInvoke -and $edit) { [void]$edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$patValue) }
} catch { "pattern fetch threw: $($_.Exception.Message)" }
if (-not $patInvoke -and -not $patValue) { try { Stop-Process -Id $proc.Id -Force } catch { }; throw 'no pattern object obtained; nothing to act with' }
"pattern: $($(if ($patInvoke) { 'Invoke' } else { 'SetValue' }))"

function Act-Pattern {
  if ($patInvoke) { $patInvoke.Invoke() } else { $patValue.SetValue('fgprobe-' + (Get-Random)) }
}
# Attempt to give the foreground back to $wantH. Joins the input queue of the thread owning
# the CURRENT foreground -- which, because we only ever call this when our own target stole it,
# is our own target's thread. That is the documented unlock. Attach/Leave are reported so a
# 'did not work' reading can be told apart from 'was not even allowed to try'.
function Attempt-Restore([long]$wantH) {
  $tid = [FG]::ThreadOf([FG]::FgHandle())
  $joined = [FG]::Join($tid)
  $ok = [FG]::SetForegroundWindow([IntPtr]$wantH)
  if ($joined) { [void][FG]::Leave($tid) }
  Start-Sleep -Milliseconds 120
  return @{ joined = $joined; setFg = $ok; now = [FG]::Fg() }
}

$samp = Start-WpmSampler -Hz 20 -Tag 'fgrestore'
if (-not $samp.ok) { try { Stop-Process -Id $proc.Id -Force } catch { }; throw "sampler not recording (bootBytes=$($samp.bootBytes))" }

$rows = @()
# Arms INTERLEAVED, control+persist+restore per round in a fixed order. Block-sequential arms
# compare two different desktops (foreground activity is not uniform over time); interleaving
# is invoke-raise-check.ps1's established method.
for ($r = 1; $r -le $Rounds; $r++) {
  foreach ($mode in @('control', 'persist', 'restore')) {
    # Precondition CHECKED first, and a target-owned baseline CLEANED rather than only skipped.
    # A prior draft minimized+reshowed our window every round to 'clean the slate', and that
    # WAS the control instability (minimize perturbs foreground, so the no-call baseline
    # drifted 4/5). But the opposite failure -- skip-and-move-on -- was worse in practice: once
    # one round left the target owning the foreground, EVERY later arm saw it and self-discarded,
    # so a cascade ate half the run and the numbers dropped off a cliff. Because the offending
    # window is OUR OWN target, giving the foreground back is permitted (the join) and is pure
    # housekeeping, so clean it, re-read, and only discard if it STILL refuses.
    $prevFg = [long][FG]::Fg()
    $cleanTries = 0
    while ($prevFg -eq $actH.ToInt64() -and $cleanTries -lt 2) {
      $cleanTries++
      # Releasing OUR OWN target's foreground claim is the housekeeping that lets Windows hand
      # the foreground to whatever window was next. Attempt-Restore is the wrong call here: it
      # targets $prevFg, which when the target owns the foreground IS the target itself -- a
      # circular restore to the very window we are trying to move out of the way. Minimizing
      # our own window needs no permission because it is not an activation.
      [void][FG]::ReleaseOurs($actH)
      Start-Sleep -Milliseconds 600
      $prevFg = [long][FG]::Fg()
    }
    if ($prevFg -eq $actH.ToInt64()) {
      $rows += [pscustomobject]@{ mode = $mode; round = $r; outcome = 'PRECOND-FAIL'; joined = $false
        setFg = $false; at0 = "$prevFg"; at1 = ''; at3 = ''; want = $prevFg; wantCls = ''; wantTitle = ''
        cursorMoved = $false
        t0 = 0; t1 = 0; note = "target owns foreground at rest after $cleanTries release(s); round discarded" }
      continue
    }
    $wantS = "$prevFg"
    $wantCls = [Who]::Class([IntPtr]$prevFg)
    $wantTitle = [Who]::Title([IntPtr]$prevFg)
    $cx0 = [FG]::Cursor()
    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    if ($mode -eq 'control') {
      # No call. Three observation points at the same elapsed offsets as the other arms.
      $c0 = [FG]::Fg(); Start-Sleep -Milliseconds 1150
      $c1 = [FG]::Fg(); Start-Sleep -Milliseconds 2200
      $c3 = [FG]::Fg()
      $drift = ($c1 -ne $wantS -or $c3 -ne $wantS)
      $rows += [pscustomobject]@{ mode = $mode; round = $r; outcome = $(if ($drift) { 'DRIFT' } else { 'STILL' })
        joined = $false; setFg = $false; at0 = $c0; at1 = $c1; at3 = $c3; want = $wantS
        cursorMoved = ($cx0 -ne [FG]::Cursor()); t0 = $t0
        t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); note = 'no call' }
      continue
    }

    # Both action arms invoke the pattern once.
    try { Act-Pattern } catch {
      $rows += [pscustomobject]@{ mode = $mode; round = $r; outcome = 'THREW'; joined = $false
        setFg = $false; at0 = ''; at1 = ''; at3 = ''; want = $wantS; cursorMoved = $false
        t0 = $t0; t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        note = "pattern call threw: $($_.Exception.Message)" }
      continue
    }
    Start-Sleep -Milliseconds 250
    $mid = [FG]::Fg()
    $raised = ($mid -ne $wantS)
    $stolenByUs = ($mid -eq $actHs)

    if ($mode -eq 'persist') {
      if (-not $raised) {
        $rows += [pscustomobject]@{ mode = $mode; round = $r; outcome = 'NO-RAISE'; joined = $false
          setFg = $false; at0 = $mid; at1 = ''; at3 = ''; want = $wantS
          cursorMoved = ($cx0 -ne [FG]::Cursor()); t0 = $t0
          t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); note = 'raise did not take' }
        continue
      }
      if (-not $stolenByUs) {
        $rows += [pscustomobject]@{ mode = $mode; round = $r; outcome = 'THIRD-PARTY'; joined = $false
          setFg = $false; at0 = $mid; at1 = ''; at3 = ''; want = $wantS
          cursorMoved = ($cx0 -ne [FG]::Cursor()); t0 = $t0
          t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); note = 'foreground went elsewhere' }
        continue
      }
      # Raise is standing on our target. Observe WITHOUT touching for the same window the
      # restore arm gets, then clean up afterward so the next round's baseline is valid. The
      # cleanup runs AFTER the three points, so it cannot be mistaken for the measurement.
      $p0 = $mid; Start-Sleep -Milliseconds 900
      $p1 = [FG]::Fg(); Start-Sleep -Milliseconds 2200
      $p3 = [FG]::Fg()
      $stillStole = ($p3 -eq $actHs)
      $reverted = ($p3 -eq $wantS)
      $rows += [pscustomobject]@{ mode = $mode; round = $r
        outcome = $(if ($stillStole) { 'PERSISTS' } elseif ($reverted) { 'SELF-REVERT' } else { 'MOVED-ELSEWHERE' })
        joined = $false; setFg = $false; at0 = $p0; at1 = $p1; at3 = $p3; want = $wantS
        wantCls = $wantCls; wantTitle = $wantTitle
        cursorMoved = ($cx0 -ne [FG]::Cursor()); t0 = $t0
        t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); note = 'raise, no restore' }
      # Cleanup: restore the baseline for the NEXT round, using the same join+SetForegroundWindow
      # that the restore arm uses. A bare SetForegroundWindow here would be refused by the
      # foreground lock (established: 30/36 rounds) and every subsequent round's $prevFg check
      # would then find our target still owning the foreground -- the whole run would collapse
      # into PRECOND-FAIL discards, and the run that LOOKED like the mitigation failing would
      # have failed because the CLEANUP path used a mechanism this script already proved broken.
      [void](Attempt-Restore $prevFg)
      Start-Sleep -Milliseconds 400
      continue
    }

    # restore mode, raised, stolenByUs
    if (-not $raised -or -not $stolenByUs) {
      $rows += [pscustomobject]@{ mode = $mode; round = $r; outcome = $(if (-not $raised) { 'NO-RAISE' } else { 'THIRD-PARTY' })
        joined = $false; setFg = $false; at0 = $mid; at1 = ''; at3 = ''; want = $wantS
        cursorMoved = ($cx0 -ne [FG]::Cursor()); t0 = $t0
        t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        note = 'nothing to restore (channel did not raise, or raised to a third window)' }
      continue
    }
    $att = Attempt-Restore $prevFg
    $a0 = $att.now; Start-Sleep -Milliseconds 900
    $a1 = [FG]::Fg(); Start-Sleep -Milliseconds 2200
    $a3 = [FG]::Fg()
    $held = ($a3 -eq $wantS)
    $rows += [pscustomobject]@{ mode = $mode; round = $r; outcome = $(if ($a1 -eq $wantS -and $held) { 'HELD' } elseif ($a1 -eq $wantS) { 'REVERTED-LATER' } elseif ($a0 -eq $wantS) { 'CAUGHT-THROW' } else { 'FAILED' })
      joined = $att.joined; setFg = $att.setFg; at0 = $a0; at1 = $a1; at3 = $a3; want = $wantS
      wantCls = $wantCls; wantTitle = $wantTitle
      cursorMoved = ($cx0 -ne [FG]::Cursor()); t0 = $t0
      t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      note = "restore: at1=$($a1 -eq $wantS) at3=$held" }
  }
}
$stopped = Stop-WpmSampler -S $samp
$samples = if ($stopped) { $stopped.rows } else { @() }

''
foreach ($rw in $rows) { "  $($rw.mode) r$($rw.round): $($rw.outcome) joined=$($rw.joined) setFg=$($rw.setFg) | $($rw.note)" }
''
$ctl = @($rows | Where-Object { $_.mode -eq 'control' })
$per = @($rows | Where-Object { $_.mode -eq 'persist' })
$res = @($rows | Where-Object { $_.mode -eq 'restore' })
$ctlDrift = @($ctl | Where-Object { $_.outcome -eq 'DRIFT' }).Count
$perValid = @($per | Where-Object { $_.outcome -in @('PERSISTS', 'SELF-REVERT', 'MOVED-ELSEWHERE') })
$persists = @($perValid | Where-Object { $_.outcome -eq 'PERSISTS' }).Count
$selfRevert = @($perValid | Where-Object { $_.outcome -eq 'SELF-REVERT' }).Count
# Attempted = a round where a restore was genuinely TRIED. PRECOND-FAIL rounds discarded the
# round before any action, so counting them as failed attempts (the previous draft) diluted the
# held-ratio: r6 showed '3 held of 6' when only 4 were ever attempted -- exactly the
# 'insufficient data presented as a verdict' failure this repo keeps correcting.
$resAttempted = @($res | Where-Object { $_.outcome -in @('HELD', 'REVERTED-LATER', 'CAUGHT-THROW', 'FAILED') })
$resHeld = @($res | Where-Object { $_.outcome -eq 'HELD' }).Count
$joinOk = @($resAttempted | Where-Object { $_.joined }).Count
$setTrue = @($resAttempted | Where-Object { $_.setFg }).Count
''
# Where the flip lives: the persist outcome grouped by the BASELINE window's class/title. If
# SELF-REVERT concentrates on one owner (an app with its own focus policy, like this session's
# Electron GUI holding the foreground), variance is that app reclaiming focus -- not the
# mitigation failing and not my cleanup: both arms were correct, the desktop differs. This is
# characterization, not a verdict: it tells the next run what to hold fixed.
$perValid | Group-Object wantCls | ForEach-Object {
  "persist grouped by baseline window: [$($_.Name)] n=$($_.Count) -> " +
  (($_.Group | ForEach-Object { $_.outcome }) -join ',')
}
$resAttempted | Group-Object wantCls | ForEach-Object {
  "restore grouped by baseline window: [$($_.Name)] n=$($_.Count) -> " +
  (($_.Group | ForEach-Object { $_.outcome }) -join ',')
}
"control rounds: $($ctl.Count) ambient drift: $ctlDrift"
"persist rounds (raised, untouched): $($perValid.Count)  STILL stolen: $persists  self-reverted: $selfRevert"
"restore rounds attempted: $($resAttempted.Count)  held to +3s: $resHeld"
"AttachThreadInput succeeded: $joinOk/$($resAttempted.Count)  SetForegroundWindow TRUE: $setTrue/$($resAttempted.Count)"
''
if ($perValid.Count -lt 2 -or $resAttempted.Count -lt 2) {
  'NOT ENOUGH DATA: the mitigation cannot be scored. Persist arm ' + "valid=$($perValid.Count), " +
  "restore attempted=$($resAttempted.Count). Re-run with more rounds; no conclusion follows."
} elseif ($selfRevert -gt 0 -and $persists -eq 0) {
  'MITIGATION CANNOT BE ATTRIBUTED: the raise self-reverted in ' + "$selfRevert/$($perValid.Count) " +
  'persist rounds WITHOUT any restore. Then a restore round "succeeding" may be the app ' +
  'returning on its own, not the SetForegroundWindow. The clean reading requires the raise to ' +
  'PERSIST untouched while it HELPS when restored.'
} elseif ($persists -ge 2 -and $resHeld -eq $resAttempted.Count -and $resAttempted.Count -ge 2) {
  'MITIGATION WORKS AS A CAUSAL EFFECT: the raise STOOD through ' + "$persists/$($perValid.Count) " +
  'persist rounds (the app did NOT give the foreground back on its own), yet the foreground was ' +
  'restored and HELD to +3s in ' + "$resHeld/$($resAttempted.Count) restore rounds. " +
  'AttachThreadInput into the current-foreground thread + SetForegroundWindow is therefore an ' +
  'effective quiet reversal of the damage the pattern channel causes. This does NOT restore ' +
  'R2.2 wholesale -- the raise itself is still a real, observable disturbance the user could ' +
  'catch mid-frame -- but it puts a bounded disturbance window (single-digit-to-low-tens of ms ' +
  'between raise and restore) on the table for the first time. It must be re-measured at a ' +
  'higher rate, and the residual flicker must be characterized before any product decision.'
} elseif ($joinOk -eq 0) {
  'MITIGATION BLOCKED AT THE KEY: AttachThreadInput failed in all ' + "$($resAttempted.Count) " +
  'attempted restores, so SetForegroundWindow was never made permitted. The earlier rejection ' +
  'of foreground hand-off extends to the input-queue join, not just the bare call.'
} else {
  'MITIGATION DOES NOT STICK: the key opened (' + "$joinOk joined, $setTrue permitted) but the " +
  'foreground did not hold in ' + "$($resAttempted.Count - $resHeld)/$($resAttempted.Count) " +
  'rounds, and the raise persists untouched when left alone (' + "$persists/$($perValid.Count)). " +
  'Reversal is therefore unreliable and not a basis for a product.'
}

try { Set-Content -LiteralPath $exitF -Value 'exit' -Force } catch { }
Start-Sleep -Milliseconds 1200
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
