# g0prime.ps1 -- measure the four R2' gates THROUGH the engine, on a target that costs a flash.
#
# WHAT MAKES THIS A GATE AND NOT A DEMO. Every number printed here is compared against a control
# arm taken in the same run, and the verdict text is generated from the measured counts rather
# than written in advance. The failure mode this protocol exists to prevent has already happened
# twice in this repo: a verdict that says 'works' while the arm that would falsify it was empty.
# So an empty or unstable control arm withholds the verdict instead of passing it.
#
# GATES (spec.md §G0'):
#   G0'-2 restore rate      -- after a flash, is the owner's window actually foreground again
#   G0'-4 internal focus    -- does the CONTROL that held focus come back, or only the window
#   G0'-5 batch flash       -- 5 consecutive actions: five flashes or one
#   G0'-3 dialog exemption  -- a dialog the TARGET opened must not be pulled away
#
# Runs in about a minute. Exits 0 regardless of the verdict (a failing gate is a finding, not a
# crash); the verdict lines carry the result.
param(
  [int]$Rounds = 5,
  [int]$BatchCount = 5,
  [int]$WaitMs = 20000
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\src\engine\engine.ps1')
# find-window.ps1 is a SCRIPT, not a library: dot-sourcing it runs its body and throws for a
# missing parameter. It is invoked as a child process inside Find-TargetHwnd instead.

function Find-TargetHwnd([string]$titlePart) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot '..\scripts\find-window.ps1') -TitlePart $titlePart 2>$null
  $ErrorActionPreference = $prev
  if (-not $out) { return $null }
  try { return (($out | Select-Object -Last 1) | ConvertFrom-Json) } catch { return $null }
}

$exitF = Join-Path $env:TEMP ('wpm-g0p-' + [guid]::NewGuid().ToString('N') + '.stop')
$stateF = Join-Path $env:TEMP ('wpm-g0p-state-' + [guid]::NewGuid().ToString('N') + '.txt')
$proc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'uia-target.ps1'), '-HoldMs', '400000',
  '-ExitFile', "`"$exitF`"", '-StateFile', "`"$stateF`"", '-Title', 'WpmUiaTarget' -PassThru

$t = $null
for ($i = 0; $i -lt [int]($WaitMs / 400) -and -not $t; $i++) { Start-Sleep -Milliseconds 400; $t = Find-TargetHwnd 'WpmUiaTarget' }
if (-not $t) { throw 'uia-target never appeared' }
$hwnd = [string]$t.hwnd
$tpid = [WpmWin]::PidOf([IntPtr][int64]$hwnd)
"target: hwnd=$hwnd pid=$tpid (find-window reported process=$($t.process))"

function Get-AppState {
  for ($i = 0; $i -lt 40; $i++) {
    if (Test-Path -LiteralPath $stateF) {
      $l = Get-Content -LiteralPath $stateF -Tail 1 -ErrorAction SilentlyContinue
      if ($l) {
        $d = @{}
        foreach ($p in ([string]$l -split "`t")) { $kv = $p -split '=', 2; if ($kv.Count -eq 2) { $d[$kv[0]] = $kv[1] } }
        if ($d.Count) { return $d }
      }
    }
    Start-Sleep -Milliseconds 300
  }
  throw 'app-side state file never appeared: no effect can be verified'
}
$s0 = Get-AppState
"app truth at start: press=$($s0.press) open=$($s0.open) edit=$($s0.edit)"

# ---- probe: which tier does this target cost? ----
$probe = Get-WpmFacts -Hwnd ([IntPtr][int64]$hwnd) -ElementName 'wpmPress'
$dec = Get-WpmChannelDecision $probe.facts
"probe: family=$($probe.family) cls=$($probe.cls) door=$($probe.facts.messageDoor) pattern=$($probe.facts.patternKind) => channel=$($dec.channel) tier=$($dec.tier)"
''

# ---- priming: give the target an activation history, then hand focus back ----
# WHY. The first runs measured zero flashes although UIA Invoke is the channel measured at 6/6
# raise earlier. The difference is state, not channel: a window that has NEVER been activated was
# not raised by Invoke, while the earlier 6/6 came from a window that had been. So a target that
# has never been focused is driven for free -- a real finding, but it means the restore path goes
# untested unless the test reproduces the activated case first. Priming does that: activate the
# target once, then use the very mechanism we ship to put the owner's window back, and verify it.
$ownerFg = [WpmWin]::Fg()
$ownerH = [IntPtr][int64]$ownerFg
$primed = 'not-attempted'
$rt = [WpmWin]::RestoreForeground([IntPtr][int64]$hwnd)
$step1 = ([WpmWin]::Fg() -eq $hwnd)
if ($step1) {
  $rb = [WpmWin]::RestoreForeground($ownerH)
  $back = ([WpmWin]::Fg() -eq $ownerFg)
  $primed = if ($back) { 'primed' } else { 'target-activated-but-owner-restore-failed' }
} else {
  $primed = 'target-would-not-activate'
}
"priming: $primed (target took focus=$step1; owner window restored=$($primed -eq 'primed'))"
Start-Sleep -Milliseconds 500
''

# ---- control arm: does the desktop hold still on its own? ----
$ctl = 0
for ($r = 1; $r -le $Rounds; $r++) {
  $fg0 = [WpmWin]::Fg()
  $fi0 = [WpmWin]::GuiFocusOfForeground()
  Start-Sleep -Milliseconds 1200
  $fg1 = [WpmWin]::Fg()
  if ($fg1 -eq $fg0) { $ctl++ }
}
"control arm: foreground unchanged in $ctl/$Rounds rounds with no engine call"
''

# ---- G0'-2 + G0'-4: restore rate and internal focus ----
$rows = @()
for ($r = 1; $r -le $Rounds; $r++) {
  $st = Get-AppState
  $pressBefore = [int]$st.press
  $fgBefore = [WpmWin]::Fg()
  $fiBefore = [WpmWin]::GuiFocusOfForeground()
  $res = Invoke-WpmAction -Hwnd $hwnd -Action 'click' -ElementName 'wpmPress' -SettleMs 300
  $st2 = Get-AppState
  $pressAfter = [int]$st2.press
  $fgAfter = [WpmWin]::Fg()
  $fiAfter = [WpmWin]::GuiFocusOfForeground()

  $rows += [pscustomobject]@{
    round = $r
    effect = ($pressAfter -gt $pressBefore)          # app-side truth, never the engine's return
    channel = $res.channel
    latency = $res.latencyMs
    focusTaken = $res.focusTaken
    restore = $res.restoreOutcome
    setFg = $res.restoreSetFg
    backHome = ($fgAfter -eq $fgBefore)
    # Hashtable access, guarded: under StrictMode a missing key throws, and 'this action raised a
    # third-party window' is a key that only exists when it happened.
    raisedOurs = $(if ($res.ContainsKey('raisedOurs')) { $res.raisedOurs } else { 'false' })
    raisedElsewhere = $(if ($res.ContainsKey('raisedElsewhere')) { $res.raisedElsewhere } else { '' })
    flashMs = $(if ($res.ContainsKey('flashMs')) { $res.flashMs } else { 0 })
    ctrlBack = if ($fiBefore[1] -and $fiAfter[1]) { ($fiBefore[1] -eq $fiAfter[1]) } else { $null }
    refusal = $res.refusal
  }
  Start-Sleep -Milliseconds 400
}
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
$acted = @($rows | Where-Object { $_.refusal -eq '' })
$effected = @($rows | Where-Object { $_.effect }).Count
$rose = @($rows | Where-Object { $_.focusTaken -eq 'true' }).Count
$roseOurs = @($rows | Where-Object { $_.raisedOurs -eq 'true' }).Count
$roseOther = @($rows | Where-Object { $_.raisedElsewhere }).Count
$flashSpans = @($rows | Where-Object { $_.focusTaken -eq 'true' -and $_.flashMs } | ForEach-Object { [int]$_.flashMs })
$flashMax = if ($flashSpans.Count) { ($flashSpans | Measure-Object -Maximum).Maximum } else { 0 }
$flashMin = if ($flashSpans.Count) { ($flashSpans | Measure-Object -Minimum).Minimum } else { 0 }
$restored = @($rows | Where-Object { $_.backHome }).Count
$restoredByCall = @($rows | Where-Object { $_.restore -eq 'restore' -and $_.setFg -eq 'true' }).Count
$latMax = (@($rows | ForEach-Object { $_.latency }) | Measure-Object -Maximum).Maximum
$ctrlKnown = @($rows | Where-Object { $null -ne $_.ctrlBack })
$ctrlBack = @($ctrlKnown | Where-Object { $_.ctrlBack }).Count
"actions attempted=$($rows.Count) app-side-verified effect=$effected flash-taken=$rose (ours=$roseOurs other=$roseOther) back-home=$restored restore-call-succeeded=$restoredByCall maxLatencyMs=$latMax flashSpanMs=$flashMin..$flashMax"
"internal control focus returned: $ctrlBack/$($ctrlKnown.Count) (unknown when the focus control could not be read)"

# ---- G0'-2 (flash path): force a real raise with SetFocus, then measure the restore ----
# Invoke completed without touching the foreground in the rounds above, so the restore path was
# never exercised. SetFocus transfers keyboard focus by definition, so it is the action that
# guarantees the condition this gate is about -- and an agent needs it anyway.
$flashRows = @()
for ($r = 1; $r -le $Rounds; $r++) {
  $fgBefore = [WpmWin]::Fg()
  $fiBefore = [WpmWin]::GuiFocusOfForeground()
  $res = Invoke-WpmAction -Hwnd $hwnd -Action 'focus' -ElementName 'wpmEdit' -SettleMs 250
  $fgAfter = [WpmWin]::Fg()
  $fiAfter = [WpmWin]::GuiFocusOfForeground()
  $flashRows += [pscustomobject]@{
    round = $r
    channel = $res.channel
    focusTaken = $(if ($res.ContainsKey('focusTaken')) { $res.focusTaken } else { 'false' })
    raisedOurs = $(if ($res.ContainsKey('raisedOurs')) { $res.raisedOurs } else { 'false' })
    raisedElsewhere = $(if ($res.ContainsKey('raisedElsewhere')) { $res.raisedElsewhere } else { '' })
    restore = $(if ($res.ContainsKey('restoreOutcome')) { $res.restoreOutcome } else { '' })
    setFg = $(if ($res.ContainsKey('restoreSetFg')) { $res.restoreSetFg } else { '' })
    flashMs = $(if ($res.ContainsKey('flashMs')) { $res.flashMs } else { 0 })
    backHome = ($fgAfter -eq $fgBefore)
    ctrlBack = if ($fiBefore[1] -and $fiAfter[1]) { ($fiBefore[1] -eq $fiAfter[1]) } else { $null }
    refusal = $res.refusal
  }
  Start-Sleep -Milliseconds 350
}
'--- flash path (SetFocus) ---'
$flashRows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
$fTaken = @($flashRows | Where-Object { $_.focusTaken -eq 'true' }).Count
$fOurs = @($flashRows | Where-Object { $_.raisedOurs -eq 'true' }).Count
$fBack = @($flashRows | Where-Object { $_.backHome }).Count
$fRestored = @($flashRows | Where-Object { $_.restore -eq 'restore' -and $_.setFg -eq 'true' }).Count
$fSpans = @($flashRows | Where-Object { $_.focusTaken -eq 'true' -and $_.flashMs } | ForEach-Object { [int]$_.flashMs })
$fMin = if ($fSpans.Count) { ($fSpans | Measure-Object -Minimum).Minimum } else { 0 }
$fMax = if ($fSpans.Count) { ($fSpans | Measure-Object -Maximum).Maximum } else { 0 }
"flash path: attempted=$($flashRows.Count) focus-taken=$fTaken raised-ours=$fOurs back-home=$fBack restore-call-succeeded=$fRestored spanMs=$fMin..$fMax"
''

# ---- G0'-5: batch flash ----
$fc0 = [WpmWin]::Fg()
$prev = $fc0
$transitions = 0
$stB = Get-AppState
$pressB = [int]$stB.press
for ($i = 1; $i -le $BatchCount; $i++) {
  [void](Invoke-WpmAction -Hwnd $hwnd -Action 'click' -ElementName 'wpmPress' -SettleMs 180)
  $now = [WpmWin]::Fg()
  if ($now -ne $prev) { $transitions++ }
  $prev = $now
}
$stB2 = Get-AppState
$pressA = [int]$stB2.press
"batch: $BatchCount consecutive actions, app-side effect=$($pressA - $pressB), foreground transitions=$transitions"
''

# ---- G0'-3: dialog exemption (LAST: it is modal and blocks the main window) ----
$dlgRow = $null
$resDlg = Invoke-WpmAction -Hwnd $hwnd -Action 'click' -ElementName 'wpmOpen' -SettleMs 700
$stD = Get-AppState
$fgD = [WpmWin]::Fg()
$fgDpid = [WpmWin]::PidOf([IntPtr][int64]$fgD)
$dlgTitle = [WpmWin]::Txt([IntPtr][int64]$fgD)
$dlgRow = [pscustomobject]@{
  opened = ([int]$stD.open -ge 1)
  restoreOutcome = $resDlg.restoreOutcome
  samePid = ($fgDpid -eq $tpid)
  fgTitle = $dlgTitle
}
$dlgRow | Format-List | Out-String | Write-Output

# Close the dialog through the engine so the target is left as we found it. The Close button lives
# inside the dialog window, so it is addressed by naming that hwnd -- acting on the main window
# here would fail because a modal dialog has it disabled.
$closed = $false
if ($dlgTitle -eq 'WpmDialogChild') { $closed = $true; [void][WpmWin]::PostMessageW([IntPtr][int64]$fgD, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
Start-Sleep -Milliseconds 800
"dialog cleanup: posted WM_CLOSE=$(if ($closed) { 'yes' } else { 'n/a' })"

# ---- verdicts, generated from the counts above ----
''
'=== G0'' verdicts ==='
$ctlOk = ($ctl -ge [Math]::Max(1, $Rounds - 1))
if (-not $ctlOk) {
  "G0'-2 withholds: control arm unstable ($ctl/$Rounds quiet), so a 'back home' reading cannot be told from the desktop settling."
} elseif ($acted.Count -lt 2) {
  "G0'-2 withholds: only $($acted.Count) actions ran."
} elseif ($fTaken -ge 2) {
  if ($fBack -eq $flashRows.Count -and $fRestored -ge 1) {
    "G0'-2 PASS (flash path): a deliberate SetFocus took the owner's focus in $fTaken/$($flashRows.Count) rounds and the foreground was back home in $fBack/$($flashRows.Count), with the restore call succeeding $fRestored times; raise->restore span ${fMin}..${fMax}ms."
  } else {
    "G0'-2 FAIL (flash path): focus taken $fTaken/$($flashRows.Count) but back home only $fBack/$($flashRows.Count) (restore call succeeded $fRestored). Not shippable until this is clean."
  }
} elseif ($rose -eq 0) {
  "G0'-2 WITHHELD: no flash occurred to restore. Across $($rows.Count) Invoke + $($flashRows.Count) " +
  'SetFocus + batch actions every effect was verified app-side and the foreground never moved, so ' +
  'this gate had nothing to score -- and it must not be reported as a pass. It ALSO conflicts with ' +
  'the earlier 6/6 and 12/12 raise measurements on UIA channels. The leading difference is how the ' +
  'target was launched (created never-activated here, versus created visible-and-activated then ' +
  'pushed to the background there), so one of the two setups is measuring something other than the ' +
  'channel. Until that is reconciled, neither number may be quoted as the flash cost.'
} elseif ($restored -eq $rows.Count -and $rose -ge 1) {
  "G0'-2 PASS: $restored/$($rows.Count) rounds returned the owner to their window after a measured flash ($rose took focus, $roseOurs of them the target itself); restore call succeeded $restoredByCall/$($rows.Count); raise->restore span ${flashMin}..${flashMax}ms; end-to-end ${latMax}ms including probe and settle."
} else {
  "G0'-2 FAIL: back home $restored/$($rows.Count) with $rose flashes taken. Not shippable until this is clean."
}
if ($ctrlKnown.Count -lt 2) {
  "G0'-4 withholds: focus control unreadable in $($rows.Count - $ctrlKnown.Count)/$($rows.Count) rounds."
} elseif ($ctrlBack -eq $ctrlKnown.Count) {
  "G0'-4 PASS: the exact control that held focus came back in $ctrlBack/$($ctrlKnown.Count) rounds -- the window returns AND the caret returns."
} else {
  "G0'-4 PARTIAL: control back $ctrlBack/$($ctrlKnown.Count). The window returns but the caret may not; document it rather than promise it."
}
"G0'-5 measured: $transitions foreground transitions across $BatchCount actions (1 means the window stayed up and only the first action paid)."
if ($dlgRow.opened -and $dlgRow.samePid -and $dlgRow.restoreOutcome -eq 'skip-dialog') {
  "G0'-3 PASS: the dialog the target opened ($($dlgRow.fgTitle)) was left in the foreground (skip-dialog), so the agent's own Save/Open box is not yanked away."
} elseif (-not $dlgRow.opened) {
  "G0'-3 withholds: the dialog never appeared, so the exemption was not exercised."
} else {
  "G0'-3 FAIL: outcome=$($dlgRow.restoreOutcome) samePid=$($dlgRow.samePid) fg='$($dlgRow.fgTitle)'."
}

try { Set-Content -LiteralPath $exitF -Value 'exit' -Force } catch { }
Start-Sleep -Milliseconds 1000
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
exit 0
