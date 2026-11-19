# fglock-reconcile.ps1 -- can a background script LOCK the foreground for the duration of a
# dispatch, and unlock after? The owner asked exactly this for windows that have no native lock
# (DeepSeek Harness itself, ordinary apps -- unlike fullscreen players that hold it themselves).
#
# THE MECHANISM UNDER TEST: LockSetForegroundWindow(LSFW_LOCK / LSFW_UNLOCK). Documented purpose:
# suppress the automatic granting of foreground rights to other processes. It is SYSTEM-GLOBAL,
# not per-window -- that is both its power and its hazard, and the hazards are what this run
# measures rather than argues:
#   H1  does the lock actually stop the raise we can reliably trigger (the G construction)?
#   H2  does it also block the TARGET APP's own dialog from coming forward? (R2'.6 would then be
#       defeated BY the lock: the agent opens a Save box and the lock keeps it behind)
#   H3  does it block OUR OWN restore path (attach + SetForegroundWindow)? If yes, the unlock
#       must be sequenced before the restore, and the measurement says which.
#   H0  does the call even succeed from a non-foreground background process?
#
# STANCE NOTES, unchanged: the lock must never block the OWNER's own input -- LSFW_LOCK by design
# does not (user activation overrides it), and we do not test blocking the user because we never
# block the user. The lock is a global system state, so it is always released in a FINALLY, and
# the release is itself verified: a script that dies holding a system-wide lock is exactly the
# kind of silent corruption this repo exists to prevent.
param(
  [int]$Pairs = 3,
  [int]$WaitMs = 20000
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\src\engine\engine.ps1')

if (-not ('WpmLock' -as [type])) {
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class WpmLock {
    // LSFW_LOCK = 1, LSFW_UNLOCK = 2. Return value recorded everywhere: a lock call that fails
    // silently would make the whole experiment measure nothing while believing it locked.
    [DllImport("user32.dll")] public static extern bool LockSetForegroundWindow(uint uLockCode);
}
'@
}

$exitF = Join-Path $env:TEMP ('wpm-fgl-' + [guid]::NewGuid().ToString('N') + '.stop')
$stateF = Join-Path $env:TEMP ('wpm-fgl-state-' + [guid]::NewGuid().ToString('N') + '.txt')
$proc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'uia-target.ps1'), '-HoldMs', '240000',
  '-ExitFile', "`"$exitF`"", '-StateFile', "`"$stateF`"", '-Title', 'WpmUiaTarget' -PassThru
$t = $null
for ($i = 0; $i -lt [int]($WaitMs / 400) -and -not $t; $i++) {
  Start-Sleep -Milliseconds 400
  $t = Get-WpmWindowList | Where-Object { $_.title -like '*WpmUiaTarget*' } | Select-Object -First 1
}
if (-not $t) { try { Stop-Process -Id $proc.Id -Force } catch { }; throw 'target never appeared' }
$hwnd = [IntPtr][int64]$t.hwnd
"target: hwnd=$($t.hwnd)"

# holder: our own window, for reproducing the G construction (foreground recently taken).
$holderExit = Join-Path $env:TEMP ('wpm-fgl-h-' + [guid]::NewGuid().ToString('N') + '.stop')
$holder = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'holder-window.ps1'), '-HoldMs', '180000',
  '-ExitFile', "`"$holderExit`"" -PassThru
Start-Sleep -Milliseconds 1500
$hw = Get-WpmWindowList | Where-Object { $_.title -like '*WpmHolder*' } | Select-Object -First 1
if (-not $hw) { try { Stop-Process -Id $proc.Id -Force; Stop-Process -Id $holder.Id -Force } catch { }; throw 'holder never appeared' }
"holder: hwnd=$($hw.hwnd)"

$probe = Get-WpmFacts -Hwnd $hwnd -ElementName 'wpmPress'
if (-not $probe.uiaElement) { throw 'button not resolvable' }
$patPress = $probe.uiaElement.GetCurrentPattern((Get-WpmUiaCached).invoke)
$probeOpen = Get-WpmFacts -Hwnd $hwnd -ElementName 'wpmOpen'
$patOpen = $probeOpen.uiaElement.GetCurrentPattern((Get-WpmUiaCached).invoke)

$ownerFg = [WpmWin]::Fg()
$ownerH = [IntPtr][int64]$ownerFg
"owner baseline: $ownerFg"
''

# ---- H0: does the lock call even work from here? ----
$lockRet = [WpmLock]::LockSetForegroundWindow(1)
$unlockRet = [WpmLock]::LockSetForegroundWindow(2)
"H0 lock call from background process: lock=$lockRet unlock=$unlockRet"
if (-not $lockRet) {
  'H0 FAILS: LockSetForegroundWindow returned FALSE from a non-foreground process. The mechanism is unavailable without being foreground, so this idea is dead as designed. No further phases run.'
  try { Set-Content -LiteralPath $exitF -Value 'x' -Force } catch { }
  try { Set-Content -LiteralPath $holderExit -Value 'x' -Force } catch { }
  Start-Sleep -Milliseconds 800
  try { Stop-Process -Id $proc.Id -Force } catch { }
  try { Stop-Process -Id $holder.Id -Force } catch { }
  exit 0
}
''

function Invoke-Press { try { $patPress.Invoke() } catch { } }
function Start-GConstruction {
  [void][WpmWin]::RestoreForeground([IntPtr][int64]$hw.hwnd)
  Start-Sleep -Milliseconds 500
}

# ---- Phase 1: baseline, NO lock, G construction (must raise, else this run is invalid) ----
$p1 = @()
for ($r = 1; $r -le $Pairs; $r++) {
  Start-GConstruction
  $fg0 = [WpmWin]::Fg()
  Invoke-Press
  Start-Sleep -Milliseconds 350
  $fg1 = [WpmWin]::Fg()
  $p1 += [pscustomobject]@{ r = $r; fg0 = $fg0; fg1 = $fg1; raised = ($fg1 -ne $fg0); toTarget = ($fg1 -eq "$($t.hwnd)") }
  [void][WpmWin]::RestoreForeground($ownerH)
  Start-Sleep -Milliseconds 400
}
$p1Raise = @($p1 | Where-Object { $_.raised }).Count
$p1Took = @($p1 | Where-Object { $_.toTarget }).Count
"Phase1 (no lock, G construction): raised=$p1Raise/$Pairs  raisedToTarget=$p1Took"
''

# ---- Phase 2: LOCK held through holder-activation + invoke ----
$p2 = @()
try {
  [void][WpmLock]::LockSetForegroundWindow(1)
  for ($r = 1; $r -le $Pairs + 1; $r++) {
    # holder activation ATTEMPT under lock: does the lock block even our own attach route? (H3, part 1)
    Start-GConstruction
    $fgAfterHolder = [WpmWin]::Fg()
    $holderTook = ($fgAfterHolder -eq "$($hw.hwnd)")
    $fg0 = [WpmWin]::Fg()
    Invoke-Press
    Start-Sleep -Milliseconds 350
    $fg1 = [WpmWin]::Fg()
    $p2 += [pscustomobject]@{ r = $r; holderTook = $holderTook; fg0 = $fg0; fg1 = $fg1
      raised = ($fg1 -ne $fg0); toTarget = ($fg1 -eq "$($t.hwnd)") }
    # restore owner WHILE STILL LOCKED: does our attach route pierce the lock? (H3, part 2)
    $res = Restore-WpmFocus -Entry @{ fgHwnd = $ownerFg; fgPid = [WpmWin]::PidOf($ownerH).ToString(); focusHwnd = ''; activeHwnd = ''; threadId = 0; lastInputAgeMs = 0 } `
      -RaisedHwnd $(if ($fg1 -eq "$($t.hwnd)") { $fg1 } else { '' }) -TargetPid ([WpmWin]::PidOf($hwnd)).ToString()
    $p2[-1] | Add-Member -NotePropertyName restoreOutcome -NotePropertyValue $res.outcome -Force
    $p2[-1] | Add-Member -NotePropertyName setFg -NotePropertyValue $res.setFg -Force
    $back = (([WpmWin]::Fg()) -eq $ownerFg)
    $p2[-1] | Add-Member -NotePropertyName backHomeLocked -NotePropertyValue $back -Force
    if (-not $back) { [void][WpmWin]::RestoreForeground($ownerH) }
    Start-Sleep -Milliseconds 400
  }
} finally {
  $unlockOk = [WpmLock]::LockSetForegroundWindow(2)
  # THE verification that matters for a global lock: prove the unlock landed rather than assume it.
  $proof = Start-GConstruction
  Start-Sleep -Milliseconds 300
  $proofTook = (([WpmWin]::Fg()) -eq "$($hw.hwnd)")
  $p2UnlockProof = @{ unlockRet = $unlockOk; holderTookAfterUnlock = $proofTook }
  [void][WpmWin]::RestoreForeground($ownerH)
}
$p2Holder = @($p2 | Where-Object { $_.holderTook }).Count
$p2Raise = @($p2 | Where-Object { $_.raised }).Count
$p2Took = @($p2 | Where-Object { $_.toTarget }).Count
$p2Back = @($p2 | Where-Object { $_.backHomeLocked }).Count
$p2Rest = @($p2 | Where-Object { $_.restoreOutcome -eq 'restore' -and $_.setFg -eq 'true' }).Count
"Phase2 (LOCK held): holderTook=$p2Holder/$($Pairs+1)  raised=$p2Raise  raisedToTarget=$p2Took  backHomeWhileLocked=$p2Back  restoreCallOk=$p2Rest"
"unlock proof: unlockRet=$($p2UnlockProof.unlockRet) holderTookAfterUnlock=$($p2UnlockProof.holderTookAfterUnlock)"
''

# ---- Phase 3: does the lock block the TARGET'S OWN dialog? (H2) ----
$dlg = @{ opened = $false; underLock = $false; fgTitle = ''; samePid = $false }
try {
  [void][WpmLock]::LockSetForegroundWindow(1)
  try { $patOpen.Invoke() } catch { }
  Start-Sleep -Milliseconds 900
  $fg = [WpmWin]::Fg()
  $dlg.underLock = $true
  $dlg.fgTitle = [WpmWin]::Txt([IntPtr][int64]$fg)
  $dlg.samePid = (([WpmWin]::PidOf([IntPtr][int64]$fg)) -eq ([WpmWin]::PidOf($hwnd)))
  $dlg.opened = ($dlg.fgTitle -eq 'WpmDialogChild')
  # cleanup the dialog (it is modal and blocks the main window)
  [void][WpmWin]::PostMessageW([IntPtr][int64]$fg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 700
} finally {
  [void][WpmLock]::LockSetForegroundWindow(2)
  [void][WpmWin]::RestoreForeground($ownerH)
}
"Phase3 (dialog under lock): opened=$($dlg.opened) fgTitle='$($dlg.fgTitle)' samePid=$($dlg.samePid)"
''

# ---- verdicts from the counts, not from hope ----
'=== FG-LOCK verdicts ==='
if ($p1Raise -eq 0) {
  'INVALID RUN: the no-lock baseline did not reproduce the raise, so the lock phases measured nothing. Re-run.'
} elseif ($p2Raise -eq 0 -and $p2Holder -eq 0) {
  'LOCK WORKS, WITH TWO NAMES ATTACHED: with the lock held, the holder could not take the foreground AND the invoke raised nothing (raised 0 in ' + ($Pairs + 1) + ' rounds vs ' + $p1Raise + '/' + $Pairs + ' without). As a batch guard it is real. But H3 says the lock also blocks OUR OWN activation/restore while held (restore-under-lock succeeded ' + $p2Rest + ' times -- see the table), so the shipped sequence must be: act under lock, UNLOCK, then restore. And H2 decides whether dialog-opening actions may run under the lock at all.'
} elseif ($p2Raise -eq 0 -and $p2Holder -gt 0) {
  'LOCK WORKS SELECTIVELY: the holder still activated under the lock, but the invoke raised nothing. Cheaper than expected: the raise (not activation) is what the lock suppresses. Check H2 below before shipping.'
} else {
  "LOCK DOES NOT STOP THE RAISE: raised $p2Raise/$(($Pairs+1)) under lock vs $p1Raise/$Pairs without. This mechanism does not deliver what the owner asked for."
}
if ($dlg.opened) {
  'H2 CLEAR: the target app opened its own dialog WHILE the lock was held (samePid=' + $dlg.samePid + '). The lock does not defeat the dialog exemption -- R2''.6 and the lock can coexist.'
} elseif ($dlg.underLock) {
  'H2 CONFIRMED HAZARD: with the lock held, the target''s own dialog could NOT come forward (fg was ''' + $dlg.fgTitle + '''). A lock around a dialog-opening action would strangle the very window the action exists to open. Decision-table consequence: actions that may open dialogs must run UNLOCKED, or the lock must be released around them.'
} else {
  'H2 UNKNOWN: the dialog never appeared this run, so the lock-vs-dialog question is unanswered here.'
}

try { Set-Content -LiteralPath $exitF -Value 'x' -Force } catch { }
try { Set-Content -LiteralPath $holderExit -Value 'x' -Force } catch { }
Start-Sleep -Milliseconds 900
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
try { Stop-Process -Id $holder.Id -Force } catch { }
exit 0
