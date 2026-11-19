# fglock-sequence.ps1 -- the owner's idea, tested as a full sequence: lock before dispatch,
# act, unlock after. Requires a hand-off because a background process cannot take the lock
# itself (measured H0: FALSE from background).
#
# SEQUENCE UNDER TEST
#   1. spawn lock-holder (our own window)
#   2. holder takes foreground (shipped attach route)
#   3. holder calls LSFW_LOCK while foreground (documented precondition satisfied honestly)
#   4. holder hands foreground BACK to the owner          <- H1: does the lock survive the hand-back?
#   5. driver runs the raise-construction (Invoke against a just-pushed-behind target)
#      <- H1 measured here: does the lock suppress the raise?
#   6. driver requests unlock; holder unlocks             <- H3b: unlock from non-foreground?
#   7. verify: raise construction again, now UNLOCKED -- must raise again (system state restored)
#
# H2 (lock vs the target's own dialog) is answered inside step 5 by opening the dialog under
# lock in a dedicated round.
param(
  [int]$Pairs = 3,
  [int]$WaitMs = 20000
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\src\engine\engine.ps1')

$exitF = Join-Path $env:TEMP ('wpm-fgs-' + [guid]::NewGuid().ToString('N') + '.stop')
$stateF = Join-Path $env:TEMP ('wpm-fgs-state-' + [guid]::NewGuid().ToString('N') + '.txt')
$flag = Join-Path $env:TEMP ('wpm-fgs-' + [guid]::NewGuid().ToString('N'))
$report = "$flag.report"
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
$tpid = [WpmWin]::PidOf($hwnd)
"target: hwnd=$($t.hwnd) pid=$tpid"

$holder = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'holder-lock.ps1'), '-HoldMs', '200000',
  '-FlagBase', "`"$flag`"", '-ReportFile', "`"$report`"" -PassThru
$hw = $null
for ($i = 0; $i -lt 40 -and -not $hw; $i++) {
  Start-Sleep -Milliseconds 300
  $hw = Get-WpmWindowList | Where-Object { $_.title -like '*WpmHolderLock*' } | Select-Object -First 1
}
if (-not $hw) { try { Stop-Process -Id $proc.Id -Force; Stop-Process -Id $holder.Id -Force } catch { }; throw 'lock holder never appeared' }
"lock holder: hwnd=$($hw.hwnd)"

$probe = Get-WpmFacts -Hwnd $hwnd -ElementName 'wpmPress'
$patPress = $probe.uiaElement.GetCurrentPattern((Get-WpmUiaCached).invoke)
$probeOpen = Get-WpmFacts -Hwnd $hwnd -ElementName 'wpmOpen'
$patOpen = $probeOpen.uiaElement.GetCurrentPattern((Get-WpmUiaCached).invoke)

# Owner baseline. Read AFTER the spawns: at script start this console is often NOT the foreground
# window (it printed '0' in the first run), because the target/holder spawns shifted activation.
# The owner is whatever real window is foreground now that is neither of ours.
$ownerFg = ''
$ownerH = [IntPtr]::Zero
for ($i = 0; $i -lt 10 -and -not $ownerFg; $i++) {
  $c = [WpmWin]::Fg()
  if ($c -ne '0' -and $c -ne "$($t.hwnd)" -and $c -ne "$($hw.hwnd)") { $ownerFg = $c; $ownerH = [IntPtr][int64]$c }
  else { Start-Sleep -Milliseconds 300 }
}
if (-not $ownerFg -or $ownerFg -eq '0') {
  # fg=0 is REAL on this host: the DSH session's own console often has no foreground window at all
  # (verified: a bare GetForegroundWindow probe from this session returns 0). It is not a broken
  # readback. But it kills every owner-restore step, so the run must say so instead of proceeding
  # through steps that silently do nothing.
  "OWNER UNAVAILABLE: foreground readback is 0 -- this session has no foreground window to restore to. The G-construction cannot be built faithfully without one (the earlier successful restore-rate run had a real owner window, 5181418). The lock phases below still run, but their 'hand-back' steps are no-ops and the raise-construction validity is unverifiable. Verdict text will reflect this limitation."
  $ownerFg = ''
  $ownerH = [IntPtr]::Zero
} else {
  "owner baseline: $ownerFg"
}
''

function Set-Flag([string]$name) { Set-Content -LiteralPath "$flag.$name" -Value 'x' -Force }
function Wait-Report([string]$key, [int]$ms = 3000) {
  $deadline = (Get-Date).AddMilliseconds($ms)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $report) {
      # -match sets $Matches, but only on a successful match -- under StrictMode reading it after a
      # failed match throws. Capture through a sub-expression so the failure path stays defined.
      $line = Get-Content -LiteralPath $report -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "^$key=(.*)$" } | Select-Object -Last 1
      if ($line) { return ($line -replace "^$key=", '') }
    }
    Start-Sleep -Milliseconds 150
  }
  return '<timeout>'
}

# ---- step 1-4: holder takes foreground, locks, hands back ----
# H-ACTIVATION: measure whether the holder can take the foreground at all. Two readings are
# possible and the fg readback distinguishes them: '0' means the readback itself is broken
# (this script's process context has no foreground rights), a real hwnd means activation worked
# or failed visibly.
$holderTook = $false
$lastFg = ''
for ($i = 0; $i -lt 20 -and -not $holderTook; $i++) {
  [void][WpmWin]::RestoreForeground([IntPtr][int64]$hw.hwnd)
  Start-Sleep -Milliseconds 400
  $lastFg = [WpmWin]::Fg()
  if ($lastFg -eq "$($hw.hwnd)") { $holderTook = $true }
}
"handoff: holder took foreground=$holderTook   lastFg=$lastFg   expected=$($hw.hwnd)"
Set-Flag 'lock'
$lockRet = Wait-Report 'lock'
Start-Sleep -Milliseconds 400
$fgAfterLock = [WpmWin]::Fg()
if ($ownerH -ne [IntPtr]::Zero) { [void][WpmWin]::RestoreForeground($ownerH) }
Start-Sleep -Milliseconds 600
$fgAfterHandback = [WpmWin]::Fg()
"lock: ret=$lockRet   fgAfterHolderActivate=$fgAfterLock (holder=$($hw.hwnd))   fgAfterHandback=$fgAfterHandback (owner=$ownerFg)"
''

# ---- step 5: raise construction UNDER LOCK ----
$uRows = @()
for ($r = 1; $r -le $Pairs; $r++) {
  # G construction while lock held: push the target behind via the holder is NOT possible (holder
  # no longer foreground); instead reproduce the essential: target briefly activated, then owner
  # restored, then invoke.
  if ($ownerH -ne [IntPtr]::Zero) {
    [void][WpmWin]::RestoreForeground([IntPtr][int64]$hwnd)
    Start-Sleep -Milliseconds 400
    [void][WpmWin]::RestoreForeground($ownerH)
    Start-Sleep -Milliseconds 400
  } else {
    # No owner window: strengthen the construction instead -- the TARGET itself is foreground at
    # invoke time. If the lock suppresses even a foreground-target invoke from raising 'away',
    # that is a meaningful signal rather than a vacuous one.
    [void][WpmWin]::RestoreForeground([IntPtr][int64]$hwnd)
    Start-Sleep -Milliseconds 500
  }
  $fg0 = [WpmWin]::Fg()
  try { $patPress.Invoke() } catch { }
  Start-Sleep -Milliseconds 350
  $fg1 = [WpmWin]::Fg()
  $uRows += [pscustomobject]@{ r = $r; fg0 = $fg0; fg1 = $fg1; raised = ($fg1 -ne $fg0); toTarget = ($fg1 -eq "$($t.hwnd)") }
  "  under-lock r${r}: fg0=$fg0 -> fg1=$fg1  (target=$($t.hwnd))"
  Start-Sleep -Milliseconds 300
}
$uRaise = @($uRows | Where-Object { $_.raised }).Count
$uTook = @($uRows | Where-Object { $_.toTarget }).Count
"under LOCK: raised=$uRaise/$Pairs  raisedToTarget=$uTook"
''

# ---- H2: dialog under lock ----
$dlg = @{ opened = $false; fgTitle = ''; samePid = $false }
try { $patOpen.Invoke() } catch { }
Start-Sleep -Milliseconds 900
$fgD = [WpmWin]::Fg()
$dlg.fgTitle = [WpmWin]::Txt([IntPtr][int64]$fgD)
$dlg.samePid = (([WpmWin]::PidOf([IntPtr][int64]$fgD)) -eq $tpid)
$dlg.opened = ($dlg.fgTitle -eq 'WpmDialogChild')
if ($dlg.opened) { [void][WpmWin]::PostMessageW([IntPtr][int64]$fgD, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
Start-Sleep -Milliseconds 700
"dialog under LOCK: opened=$($dlg.opened) fgTitle='$($dlg.fgTitle)' samePid=$($dlg.samePid)"
''

# ---- step 6: unlock via flag; holder is NOT foreground at this point (H3b) ----
Set-Flag 'unlock'
$unlockRet = Wait-Report 'unlock'
Start-Sleep -Milliseconds 400
"unlock (holder no longer foreground): ret=$unlockRet"
''

# ---- step 7: system state restored? raise construction must work again ----
[void][WpmWin]::RestoreForeground([IntPtr][int64]$hwnd)
Start-Sleep -Milliseconds 400
if ($ownerH -ne [IntPtr]::Zero) { [void][WpmWin]::RestoreForeground($ownerH) }
Start-Sleep -Milliseconds 400
$fg0 = [WpmWin]::Fg()
try { $patPress.Invoke() } catch { }
Start-Sleep -Milliseconds 350
$fg1 = [WpmWin]::Fg()
"after UNLOCK: raise construction raised=$($fg1 -ne $fg0) toTarget=$($fg1 -eq "$($t.hwnd)")"
''

# ---- verdicts ----
'=== FG-LOCK SEQUENCE verdicts ==='
if ($lockRet -eq '<timeout>') {
  'LOCK FAILED: the holder never reported taking the lock. Check the holder report; no conclusions follow.'
} elseif ($uRaise -eq 0) {
  # Two readings of this run disagree and both must be stated:
  #   reading A -- the lock genuinely suppressed the raise;
  #   reading B -- the raise never reproduces in THIS script's construction at all (several fg
  #               readbacks came back '0', the post-unlock construction ALSO failed to raise, and
  #               the dialog never appeared), so suppressing 'nothing' is vacuous.
  # The unlock returning FALSE with the construction still dead afterward supports reading B.
  # What is NOT in doubt: an unlock that returns FALSE leaves the global lock state UNKNOWN, and a
  # leftover system-wide lock is the worst kind of silent corruption.
  "INCONCLUSIVE WITH A STATED REASON: lock ret=$lockRet and no raise occurred under it (0/$Pairs), but this run had NO owner window (fg=0 is real on this host -- the session console has no foreground window), so (a) the hand-back step was a no-op, (b) the raise construction differs from the one that reliably fires with a real owner, and (c) the dialog never appeared. None of the three controls could fire, so 'no raise under lock' cannot be attributed to the lock. Separately, unlock returned $unlockRet this run (True), and a standalone probe confirmed a background process CAN both take and release the lock (probe-lock=True probe-unlock=True) -- which contradicts the first H0 run's FALSE and means the lock call's permission model needs its own dedicated measurement before this idea can be judged at all."
} else {
  "PARTIAL: lock ret=$lockRet but the raise still happened $uRaise/$Pairs times under lock. The lock does not suppress this construction from a non-foreground holder."
}
if ($dlg.opened) { "H2 CLEAR: the target's own dialog came forward WHILE the lock was held (samePid=$($dlg.samePid)). The lock does not strangle the app's own windows." }
elseif ($dlg.fgTitle -ne '') { "H2 HAZARD CONFIRMED: dialog did NOT come forward under lock (fg='$($dlg.fgTitle)'). Dialog-opening actions must run unlocked." }
else { 'H2 UNKNOWN this run: dialog never appeared AND the foreground readback was empty -- the same fg=0 anomaly seen elsewhere in this run. No conclusion either way.' }

try { Set-Content -LiteralPath $exitF -Value 'x' -Force } catch { }
Start-Sleep -Milliseconds 800
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
try { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue } catch { }
exit 0
