# engine.ps1 -- the only place where a decision becomes a syscall.
#
# One entry point, Invoke-WpmAction, and it always returns a result object rather than throwing on
# a refusal: 'refused' is a normal outcome of this product, not an error path, and R3.2 requires
# the reason to survive to the caller. Every result carries which channel ran, which tier it cost,
# whether the owner's focus was taken and given back, and how long the whole thing took.
#
# ORDER OF OPERATIONS IS THE SAFETY DESIGN:
#   1. measure the target's doors            (facts; a target with no facts is refused)
#   2. decide                                (pure table; pause/elevation/integrity first)
#   3. if the tier costs a flash: capture the focus table BEFORE touching anything
#   4. act through the cheapest available door
#   5. if a flash was taken: restore, once, through the restore table
# Nothing in step 4 can run for a target whose step 2 said refuse, and nothing in step 5 can pull
# the focus from a window the owner chose.

Set-StrictMode -Version 2.0
$script:WpmEngineRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'decide.ps1')
. (Join-Path $PSScriptRoot 'win.ps1')

# THE PAUSE FLAG LIVES IN [WpmCtl], a static holder -- not in a script variable. The global hotkey
# (Ctrl+Alt+Q, overlay.ps1) flips it from the overlay thread while actions read it on the main
# thread; two copies across threads is the bug pattern this repo keeps meeting, and a script-scope
# variable is exactly that second copy. $script:WpmPauseReason stays here because it is only ever
# set through Set-WpmPaused, which runs on the main thread.
$script:WpmPauseReason = ''

function Set-WpmPaused([bool]$On, [string]$Reason = 'owner') {
  [WpmCtl]::Paused = $On
  $script:WpmPauseReason = if ($On) { $Reason } else { '' }
}

function Get-WpmStatus {
  $entry = Get-WpmFocusEntry
  return @{
    paused = [bool][WpmCtl]::Paused
    pauseReason = $script:WpmPauseReason
    foreground = $entry.fgHwnd
    foregroundPid = $entry.fgPid
    focusControl = $entry.focusHwnd
    lastInputAgeMs = $entry.lastInputAgeMs
    # The control board travels with status: whether the owner's overlay/hotkey surface is up, and
    # whether the hotkey actually registered. A silent 'overlay off' would make the README's
    # Ctrl+Alt+Q promise untrue with no way to notice.
    overlayRunning = [bool][WpmCtl]::OverlayOn
    overlayHwnd = [string][WpmCtl]::OverlayHwnd
    hotkeyRegistered = [bool][WpmCtl]::HotkeyOk
    hotkeyLabel = [string][WpmCtl]::HotkeyLabel
    overlayReason = [string][WpmCtl]::Reason
    dpiAware = [bool]$script:WpmDpiAware
    stance = 'no physical injection; no forged-Alt foreground trick'
  }
}

function Get-WpmWindowList {
  # Read-only enumeration for the model to choose a target by hwnd. Only visible, titled, non-cloaked
  # windows are listed: a list padded with invisible helper windows makes target selection guesswork.
  $acc = @()
  $cb = [WpmWin+EnumProc] {
    param([IntPtr]$h, [IntPtr]$l)
    if (-not [WpmWin]::IsWindowVisible($h)) { return $true }
    $t = [WpmWin]::Txt($h)
    if (-not $t) { return $true }
    if ([WpmWin]::IsIconic($h)) { return $true }
    $r = New-Object 'WpmWin+RECT'
    [void][WpmWin]::GetWindowRect($h, [ref]$r)
    $script:WpmEnumAcc += [pscustomobject]@{
      hwnd = $h.ToInt64().ToString()
      title = $t
      cls = [WpmWin]::Cls($h)
      pid = [WpmWin]::PidOf($h)
      rect = "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
    }
    return $true
  }
  $script:WpmEnumAcc = @()
  [void][WpmWin]::EnumWindows($cb, [IntPtr]::Zero)
  $out = $script:WpmEnumAcc
  $script:WpmEnumAcc = $null
  return $out
}

function Resolve-WpmChildAtPoint([IntPtr]$Hwnd, [int]$X, [int]$Y) {
  # Which child HWND actually sits under a screen point. Uses ChildWindowFromPointEx (the same
  # approach the competitor uses) instead of trusting a fixed child index: index order is not a
  # contract, and clicking the wrong child is indistinguishable from clicking the right one until
  # the app does something else.
  $p = New-Object 'WpmWin+POINT'
  $p.X = $X; $p.Y = $Y
  $hit = [WpmWin]::WindowFromPoint($p)
  if ($hit -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
  $root = [WpmWin]::Root($hit)
  if ($root -ne $Hwnd) {
    # The point belongs to some other top-level window; acting there would be acting on a window
    # the caller did not name.
    return [IntPtr]::Zero
  }
  return $hit
}

function Get-WpmProofWindow {
  <#
    Sample cursor / foreground / focused-control / last-PHYSICAL-input-age for a fixed window.
    Four read-only syscalls per sample, no process, so it costs nothing the engine would not already
    pay while parked in a wait. Attribution is arithmetic and lives in lib/proof-window.mjs; this
    only produces the raw samples. If a read throws (secure desktop, transient) we stop early and
    return what we have -- the caller then reports 'insufficient' rather than inventing a verdict.
    Returns an array; the leading comma keeps it an array even when there is exactly one element.
  #>
  param([int]$Ms, [int]$EveryMs = 15)
  $samples = @()
  $base = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $deadline = $base + $Ms
  $next = $base
  while ($true) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($now -ge $deadline) { break }
    if ($now -lt $next) { Start-Sleep -Milliseconds ([Math]::Max(1, [int]($next - $now))); continue }
    try {
      $s = [WpmWin]::Sample()
      $samples += (@{ ts = $now; cx = [int]$s[0]; cy = [int]$s[1]; fg = [string]$s[2]; focus = [string]$s[3]; inputAgeMs = [long]$s[4] })
    } catch { break }
    $next = $now + $EveryMs
  }
  try {
    $tEnd = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $s2 = [WpmWin]::Sample()
    $samples += (@{ ts = $tEnd; cx = [int]$s2[0]; cy = [int]$s2[1]; fg = [string]$s2[2]; focus = [string]$s2[3]; inputAgeMs = [long]$s2[4] })
  } catch { }
  return ,$samples
}

function Invoke-WpmAction {
  param(
    [Parameter(Mandatory)][string]$Hwnd,
    [Parameter(Mandatory)][ValidateSet('click', 'type', 'focus', 'status')][string]$Action,
    [int]$X = -1,
    [int]$Y = -1,
    [string]$Text = '',
    [string]$ElementName = '',
    [switch]$Replace,
    [int]$SettleMs = 350
  )
  $started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $h = [IntPtr][int64]$Hwnd
  $result = @{
    ok = $false; action = $Action; hwnd = $Hwnd; channel = ''; tier = ''
    refusal = ''; reason = ''; detail = ''; latencyMs = 0
    focusTaken = 'false'; restoreOutcome = ''; restoreSetFg = ''; restoreJoined = ''
    effect = 'unverified'; proofSamples = @()
  }

  # A QUERY IS NOT AN ACTION, and this branch is early on purpose. It used to sit inside the action
  # chain, where 'status' fell through to the UIA branch and INVOKED the pattern it found -- a call
  # whose entire purpose is to report state would click a control. It is also placed before the
  # target check because a query has no target: 'what holds the focus' is answerable whatever the
  # caller passed, and refusing it for an unreachable window would be a query lying about why it
  # is empty. (Found by reading the branch order while writing the refusal cases, not by a failing
  # run -- the assertion in test/refusals-test.ps1 pins the fixed behaviour, it did not catch it.)
  if ($Action -eq 'status') {
    $st = Get-WpmStatus
    $result.ok = $true
    $result.channel = 'none'; $result.tier = 'none'
    $result.detail = 'status: query only, no action taken'
    $result.foreground = $st.foreground
    $result.foregroundPid = $st.foregroundPid
    $result.focusControl = $st.focusControl
    $result.lastInputAgeMs = $st.lastInputAgeMs
    $result.paused = $st.paused
    $result.stance = $st.stance
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
    return $result
  }

  if (-not [WpmWin]::IsWindow($h)) {
    $result.refusal = 'no_hwnd'; $result.reason = 'the hwnd does not identify a live window'
    return $result
  }

  # Coordinates travel into the probe: the UIA tier resolves the element AT THE POINT. Without them
  # an unnamed click had no way to be anything other than "first control in tree order".
  $probe = Get-WpmFacts -Hwnd $h -Action $Action -ElementName $ElementName -X $X -Y $Y
  $facts = $probe.facts
  $facts.paused = [bool][WpmCtl]::Paused
  if ($ElementName) {
    # A named control cannot be addressed through a window message: the message tiers take
    # coordinates or a child HWND, and "the Save button" is neither. Suppressing the door here is
    # what makes 'click the named button' honest -- claiming the quiet tier while actually having
    # to raise the window would report the cheap tier for the expensive action.
    $facts.messageDoor = $false
  }
  $decision = Get-WpmChannelDecision $facts

  $result.channel = $decision.channel; $result.tier = $decision.tier
  $result.family = $probe.family; $result.cls = $probe.cls
  if ($decision.channel -eq 'refuse') {
    $result.refusal = $decision.refusal; $result.reason = $decision.reason
    # A refusal that says only 'unreachable' makes the reader guess which of two very different
    # things happened. When the point probe ran, it knows: the point is outside the target, or the
    # element there has no pattern, or the tree could not be walked at all. Carry that out -- a
    # refusal is a normal product outcome and its reason is the product (R3.2). The split codes
    # (uia_probe_failed / uia_tree_empty, decide.ps1) need the same context, so the point reason
    # rides on all of them; the probe's exception text always follows when it exists, because a
    # uia_probe_failed refusal whose reason hides the exception is a diagnosis with the evidence
    # redacted.
    if ($decision.refusal -in @('unreachable', 'uia_probe_failed', 'uia_tree_empty') -and $probe.uiaReason) {
      $result.reason = "$($decision.reason) -- at that point: $($probe.uiaReason)"
    }
    if ($probe.uiaErr) { $result.reason = "$($result.reason) [uia: $($probe.uiaErr)]" }
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
    return $result
  }

  # Capture the focus table BEFORE the action when the tier may cost a flash. For the quiet tier it
  # is still captured, because 'the quiet channel did not take focus' is a claim that needs a
  # before-value to be falsifiable.
  $entry = Get-WpmFocusEntry
  $raisedHwnd = ''
  # THE PRE-ACTION CONTROL WINDOW. Sampled here, immediately BEFORE the door call, so that during it,
  # by construction, WE have done nothing. WHY A CONTROL IS REQUIRED AND NOT JUST A THRESHOLD:
  # "unexplained motion" from GetLastInputInfo proves no PHYSICAL input happened in the gap -- it
  # cannot tell our action apart from some background app nudging the cursor or stealing focus. A
  # hardcoded threshold is the vacuous-control trap this repo wrote down once (P0 task_5(f): "the
  # reset control passed vacuously"), and three real clicks proved it: a clean click measured isolated
  # 3.16px and 7.07px cursor jumps. So the judgment is STRUCTURAL, decided in lib/proof-window.mjs
  # using BOTH windows: sustained multi-gap cursor motion fails (no ambient correction drags across
  # gaps), an isolated single jump is inconclusive (a position delta cannot name its cause), and a
  # foreground/focus switch is blamed on us (fail) only when the control window shows the desktop was
  # NOT already doing it. Kept short (80ms): a few samples, no perceptible slowdown.
  $controlSamples = Get-WpmProofWindow -Ms 80
  $tAct = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

  try {
    if ($decision.channel -eq 'message') {
      if ($Action -eq 'type') {
        # The door kind is decided ONCE, in the probe (win.ps1), and consumed here by kind.
        # This path used to re-match class names with its own copy of the pattern -- and that copy
        # carried the same 'Edit' vs 'WindowsForms10.EDIT.*' bug, so a fix in one place would have
        # silently left the other broken. One matcher, one truth.
        $target = $null
        foreach ($d in $probe.doorHandles) {
          if ($d.kind -eq 'text') { $target = [IntPtr]$d.hwnd; break }
        }
        if (-not $target) {
          $result.refusal = 'unreachable'; $result.reason = 'no editable child window for the message tier'
          $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
          return $result
        }
        $r = [WpmWin]::MessageText($target, $Text, [bool]$Replace)
        $result.detail = "msg=$r child=$($target.ToInt64())"
        $result.effect = 'reported-by-send'
      } elseif ($Action -eq 'click') {
        if ($X -lt 0 -or $Y -lt 0) {
          $result.refusal = 'unreachable'; $result.reason = 'click needs screen coordinates'
          $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
          return $result
        }
        $child = Resolve-WpmChildAtPoint $h $X $Y
        if ($child -eq [IntPtr]::Zero) {
          $result.refusal = 'unreachable'; $result.reason = 'no child window of the target sits under that point'
          $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
          return $result
        }
        $r = [WpmWin]::MessageClick($child, $X, $Y)
        $result.detail = "msg=$r child=$($child.ToInt64())"
        $result.effect = 'reported-by-send'
      }
    } elseif ($Action -eq 'focus') {
      # Focusing a control is a real operation an agent needs (type into a field, then read it).
      # It is also the one action that MUST change keyboard focus, so it is the honest way to
      # exercise the bounded-flash path: an Invoke can complete without activating anything, but
      # SetFocus cannot -- it transfers focus by definition.
      if ($decision.channel -ne 'uia') {
        $result.refusal = 'unreachable'; $result.reason = 'focus requires a UIA element; the message tier cannot set keyboard focus'
        $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
        return $result
      }
      $el = $probe.uiaElement
      if (-not $el) {
        $result.refusal = 'unreachable'; $result.reason = 'no element to focus'
        $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
        return $result
      }
      $el.SetFocus()
      $result.detail = 'uia=SetFocus'
      $result.effect = 'reported-by-pattern'
    } elseif ($decision.channel -eq 'uia') {
      $el = $probe.uiaElement
      if (-not $el) {
        $result.refusal = 'unreachable'; $result.reason = 'pattern was reported but no element could be re-obtained'
        $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
        return $result
      }
      $pats = Get-WpmUiaCached
      $kind = $facts.patternKind
      if ($kind -eq 'invoke') {
        $pat = $el.GetCurrentPattern($pats.invoke)
        $pat.Invoke()
      } elseif ($kind -eq 'value') {
        $pat = $el.GetCurrentPattern($pats.value)
        $pat.SetValue($(if ($Replace) { $Text } else { [string]$pat.Current.Value + $Text }))
      } elseif ($kind -eq 'toggle') {
        $pat = $el.GetCurrentPattern($pats.toggle); $pat.Toggle()
      } elseif ($kind -eq 'select') {
        $pat = $el.GetCurrentPattern($pats.select); $pat.Select()
      } elseif ($kind -eq 'legacy') {
        $pat = $el.GetCurrentPattern($pats.legacy); $pat.SetValue($Text)
      }
      $result.detail = "uia=$kind"
      $result.effect = 'reported-by-pattern'
    }
  } catch {
    $result.refusal = 'action_failed'
    $result.reason = 'the channel call threw: ' + $_.Exception.Message
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
  }

  # THE ACTION WINDOW. Sampled DURING the settle sleep the engine already performed, so collecting
  # proof costs no extra delay. This is the window the claim is made about; it is judged against the
  # pre-action control captured above (proof-window decides how, from both). Attribution is arithmetic
  # and lives in lib/proof-window.mjs -- the engine only produces samples.
  $result.proofControl = $controlSamples
  $result.proofSamples = Get-WpmProofWindow -Ms $SettleMs

  # Did the action actually take the owner's focus? Measured, not assumed -- the quiet tier is
  # expected to say no and the flash tier yes, and a run where both say the same thing is a broken
  # instrument rather than a good result.
  #
  # WHICH window now holds the foreground matters, and the first version got it wrong: it recorded
  # whatever held the foreground as "the window we raised". When an action causes the TARGET APP to
  # open a dialog, that dialog is what comes forward -- so it looked like our own raised window and
  # was promptly restored away, shutting the dialog's focus the agent had just asked for. Only the
  # target itself counts as ours; anything else is the app's own window or a third party's, and it
  # is classified, never reversed.
  $nowFg = [WpmWin]::Fg()
  $targetStr = $h.ToInt64().ToString()
  $raisedHwnd = ''
  $raisedElsewhere = ''
  if ($nowFg -ne $entry.fgHwnd) {
    $result.focusTaken = 'true'
    if ($nowFg -eq $targetStr) { $raisedHwnd = $nowFg } else { $raisedElsewhere = $nowFg }
  }
  $result.raisedOurs = ($raisedHwnd -ne '').ToString().ToLower()
  if ($raisedElsewhere) { $result.raisedElsewhere = $raisedElsewhere }

  if ($decision.needsRestore) {
    $res = Restore-WpmFocus -Entry $entry -RaisedHwnd $raisedHwnd -RaisedElsewhere $raisedElsewhere `
      -TargetPid ($probe.pid.ToString())
    $result.restoreOutcome = $res.outcome
    $result.restoreReason = $res.reason
    $result.restoreSetFg = $res.setFg
    $result.restoreJoined = $res.joined
    $result.fgAfterRestore = $res.fgAfter
    # A restore the table authorised but the OS refused is a named failure, not a success with a
    # caveat: the owner is left in a window they did not choose, so the caller must surface it.
    # The span the owner actually pays: from the moment the action was issued to the moment the
    # focus was back. Reported separately from end-to-end latency because latency includes the
    # door probe and the settle wait, and a 'budget' quoted from latency would overstate the
    # disturbance by an order of magnitude.
    # Only meaningful when focus was actually taken: reporting a 'flash span' for an action that
    # never disturbed the owner would put a scary number next to a non-event.
    if ($result.focusTaken -eq 'true') {
      $result.flashMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $tAct
    }
    if ($res.outcome -eq 'restore' -and $res.setFg -ne 'true') {
      $result.refusal = 'restore_failed'
      $result.reason = 'the OS refused to return the foreground; the owner is still in the wrong window'
    }
  }

  $result.ok = ($result.refusal -eq '')
  $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
  $result.fgBefore = $entry.fgHwnd
  $result.fgNow = [WpmWin]::Fg()
  return $result
}
