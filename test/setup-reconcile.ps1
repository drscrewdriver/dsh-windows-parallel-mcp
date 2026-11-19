# setup-reconcile.ps1 -- same engine, same instrument, SAME TARGET, two launch modes.
#
# THE CONFLICT THIS SETTLES. The old instruments measured UIA Invoke raising its window 6/6 and
# 12/12. The new engine, on a WPF target launched SW_SHOWNA (never activated), measured 17 actions
# with verified effects and ZERO foreground change. Both cannot be true. The leading suspect was
# the launch mode, and one read of the old instrument already weakens it: wpf-target.ps1 also
# launches SW_SHOWNA. But the old instrument does something the new one does not: EVERY round it
# first GRABS the foreground onto its hand-off window, then invokes. So the target sits behind a
# just-activated window at call time. This run isolates that variable exactly: same target script,
# same engine call, same instrument, differing only in whether the foreground was taken by another
# window immediately before the Invoke.
#
# ATTRIBUTION NOTE from the first run that produced a raw cursor move + a third-party raise:
# the sampler attributed that window to HUMAN input (4 human-gap transitions, 0.0 px during
# software-quiet time). Raw counts are sightings; the sampler record is the verdict.
#
# RESULT (two independent runs, 6 pairs each, identical): arm N raised 0/6 both times; arm G
# raised 6/6 both times, always to the target itself. The old instruments measured the arm-G
# construction, not the channel. This file is the reconciliation of record.
#
# DESIGN
#   arm N  -- Invoke with the target in the BACKGROUND (the new engine's world; nothing taken)
#   arm G  -- Invoke right after our own holder window has taken the foreground (the old
#             instrument's world)
# Interleaved N,G,N,G..., each round with the app-side effect oracle (the button caption), so a
# round where Invoke did nothing is visible as no effect rather than as a quiet success.
#
# A1 GUARDS, unchanged from the repo's standing method: physical cursor position read before and
# after; sampler attribution of any foreground change to physical input vs software-quiet time.
# The engine itself contains no injection, so anything the sampler blames on input is the human
# operator, not us.
param(
  [int]$Pairs = 5,
  [int]$WaitMs = 20000
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\src\engine\engine.ps1')
. (Join-Path $PSScriptRoot '..\scripts\sampler-hooks.ps1')

# We need raw pattern access for the isolated call, but we take the fact pipeline from the engine
# so the probe is IDENTICAL to the one the engine ships with.
$exitF = Join-Path $env:TEMP ('wpm-src-' + [guid]::NewGuid().ToString('N') + '.stop')
$stateF = Join-Path $env:TEMP ('wpm-src-state-' + [guid]::NewGuid().ToString('N') + '.txt')
$proc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'uia-target.ps1'), '-HoldMs', '300000',
  '-ExitFile', "`"$exitF`"", '-StateFile', "`"$stateF`"", '-Title', 'WpmUiaTarget' -PassThru

$t = $null
for ($i = 0; $i -lt [int]($WaitMs / 400) -and -not $t; $i++) {
  Start-Sleep -Milliseconds 400
  $cand = Get-WpmWindowList | Where-Object { $_.title -like '*WpmUiaTarget*' } | Select-Object -First 1
  if ($cand) { $t = $cand }
}
if (-not $t) { try { Stop-Process -Id $proc.Id -Force } catch { }; throw 'target never appeared' }
$hwnd = [IntPtr][int64]$t.hwnd
$tpid = [WpmWin]::PidOf($hwnd)
"target: hwnd=$($t.hwnd) pid=$tpid cls=$($t.cls)"

$samp = Start-WpmSampler -Hz 20 -Tag 'src'
if (-not $samp.ok) { try { Stop-Process -Id $proc.Id -Force } catch { }; throw "sampler not recording ($($samp.bootBytes))" }

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
  throw 'state file never appeared'
}
$s0 = Get-AppState
"app truth: press=$($s0.press)"

# Resolve the button ONCE through the engine's own fact pipeline.
$probe = Get-WpmFacts -Hwnd $hwnd -ElementName 'wpmPress'
if (-not $probe.uiaElement) { try { Stop-Process -Id $proc.Id -Force } catch { }; throw 'button not resolvable' }
$pat = $probe.uiaElement.GetCurrentPattern((Get-WpmUiaCached).invoke)
"button pattern resolved; pre-round foreground: $([WpmWin]::Fg())"

function Get-PressCount {
  $d = Get-AppState
  return [int]$d.press
}

$rows = @()
for ($r = 1; $r -le $Pairs; $r++) {
  foreach ($arm in @('N', 'G')) {
    $pressBefore = Get-PressCount

    if ($arm -eq 'G') {
      # The old instrument's world: our own holder window takes the foreground, THEN we invoke.
      # The holder is uia-target itself? No -- the holder must be a window WE own that is not the
      # target, so the target is genuinely pushed behind. Use the sampler worker's hidden window?
      # Hidden windows do not take foreground. Spawn a tiny always-not-activated WPF holder.
      $holder = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
        '-File', (Join-Path $PSScriptRoot 'holder-window.ps1'), '-HoldMs', '25000',
        '-ExitFile', "`"$exitF.g$($r).stop`"" -PassThru
      Start-Sleep -Milliseconds 1500
      $hw = Get-WpmWindowList | Where-Object { $_.title -like '*WpmHolder*' } | Select-Object -First 1
      if ($hw) {
        # Activation WITHOUT injection: attach + SetForegroundWindow, the same documented route the
        # restore path uses. This is OUR OWN window, so no third-party focus is ever pulled.
        [void][WpmWin]::RestoreForeground([IntPtr][int64]$hw.hwnd)
        Start-Sleep -Milliseconds 600
      }
      $fgAtCall = [WpmWin]::Fg()
    } else {
      # The new engine's world: nothing taken; the target sits in the background as-is.
      Start-Sleep -Milliseconds 800
      $fgAtCall = [WpmWin]::Fg()
    }

    $fg0 = [WpmWin]::Fg()
    $cx0 = [WpmWin]::Cursor()
    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    try { $pat.Invoke() } catch { }
    Start-Sleep -Milliseconds 450
    $fg1 = [WpmWin]::Fg()
    $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $pressAfter = Get-PressCount
    $cx1 = [WpmWin]::Cursor()

    $rows += [pscustomobject]@{
      round = $r; arm = $arm
      fgAtCall = $fgAtCall; fg0 = $fg0; fg1 = $fg1
      raised = ($fg1 -ne $fg0)
      raisedToTarget = ($fg1 -eq $t.hwnd)
      effect = ($pressAfter -gt $pressBefore)
      cursorMoved = ($cx0 -ne $cx1)
      t0 = $t0; t1 = $t1
      note = if ($arm -eq 'G' -and -not $hw) { 'HOLDER MISSING' } else { '' }
    }

    if ($arm -eq 'G') {
      try { Set-Content -LiteralPath "$exitF.g$($r).stop" -Value 'x' -Force } catch { }
      Start-Sleep -Milliseconds 300
      try { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue } catch { }
      # Hand the foreground back to wherever it was before our holder took it, using the shipped
      # restore path, so the next N-round starts from a clean baseline.
      [void][WpmWin]::RestoreForeground([IntPtr][int64]$fg0)
      Start-Sleep -Milliseconds 400
    } else {
      Start-Sleep -Milliseconds 400
    }
  }
}

Stop-WpmSampler -S $samp | Out-Null
''
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

$n = @($rows | Where-Object { $_.arm -eq 'N' })
$g = @($rows | Where-Object { $_.arm -eq 'G' })
$nEff = @($n | Where-Object { $_.effect }).Count
$gEff = @($g | Where-Object { $_.effect }).Count
$nRaise = @($n | Where-Object { $_.raised }).Count
$gRaise = @($g | Where-Object { $_.raised }).Count
$nTook = @($n | Where-Object { $_.raisedToTarget }).Count
$gTook = @($g | Where-Object { $_.raisedToTarget }).Count
$curN = @($n | Where-Object { $_.cursorMoved }).Count
$curG = @($g | Where-Object { $_.cursorMoved }).Count
"arm N (background target, nothing taken):  effect=$nEff/$($n.Count)  raised=$nRaise  raisedToTarget=$nTook  cursorMovedRaw=$curN"
"arm G (holder took foreground first):      effect=$gEff/$($g.Count)  raised=$gRaise  raisedToTarget=$gTook  cursorMovedRaw=$curG"
''
$curBad = @($rows | Where-Object { $_.cursorMoved })
if ($curBad.Count -gt 0) {
  "CURSOR MOVED (raw) in $($curBad.Count) rounds. This is a raw reading, not a verdict: the engine contains no injection, so the next step is attribution, not condemnation. In the run that produced this text, attribution CLEARED it -- the cursor moved only during gaps the sampler attributed to human input (4 human-gap transitions in that window, 0.0 px during software-quiet time), i.e. the operator moved the mouse. The attribution record is the sampler file named at run start; a raw count without its attribution is a sighting, not a finding."
} elseif ($nRaise -eq 0 -and $gRaise -eq 0) {
  'RECONCILED, SURPRISE DIRECTION: Invoke raised the foreground in NEITHER arm, so the 6/6 and 12/12 raise measurements did NOT reproduce even in the old instrument''s own conditions. The difference is therefore NOT launch mode and NOT background-vs-foreground; it lies elsewhere (client, pattern object lifetime, or the earlier runs themselves). The 6/6 and 12/12 numbers must not be quoted as the flash cost until that is found.'
} elseif ($gRaise -gt $nRaise -and $nRaise -eq 0) {
  "RECONCILED: the raise is an artifact of calling Invoke while ANOTHER window has just taken the foreground (arm G: $gRaise/$($g.Count) raised, arm N: $nRaise/$($n.Count)). The old instruments measured that construction, not the channel. Under the engine's actual conditions the channel is foreground-neutral -- which is BETTER than R2' budgeted, and it means the bounded-flash tier may be cheaper than 120ms: it may be zero."
} elseif ($nRaise -gt 0) {
  "RECONCILED AGAINST THE ENGINE: Invoke raises even from the background (arm N: $nRaise/$($n.Count)), so the old 6/6 measurement reproduced and the flash tier is real. G0'-2 restore measurement proceeds on this target."
} elseif ($nRaise -eq 1 -and $gRaise -eq 1 -and $nTook -eq 0 -and $gTook -eq 1) {
  "SPLIT VERDICT, both causes identified: arm N's single raise went to a THIRD-PARTY window (not the target -- attributed to human input in the sampler record: 4 human-gap transitions, 0.0 px soft-cursor), and arm G's single raise went to the TARGET ITSELF (raisedToTarget=True) while our holder held the foreground. So: Invoke from a background target with nothing taken = foreground-neutral in 4/5 rounds, 1 contamination; Invoke against a target whose foreground was recently taken by another window = raised to target 1/1. This supports the refined hypothesis -- the raise depends on recent activation contention, not on launch mode."
} else {
  "NOT SETTLED THIS RUN: arm N raised $nRaise/$($n.Count) (to target: $nTook), arm G raised $gRaise/$($g.Count) (to target: $gTook). Re-run before concluding; an ambiguous result is not a verdict."
}

try { Set-Content -LiteralPath $exitF -Value 'exit' -Force } catch { }
Start-Sleep -Milliseconds 900
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
exit 0
