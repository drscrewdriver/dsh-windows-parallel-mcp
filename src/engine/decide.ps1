# decide.ps1 -- the R2' channel decision, as a PURE function.
#
# WHY PURE AND FIRST. R2' turns on one table: which door a target has, and therefore whether an
# action costs the user nothing or costs them a bounded flash. Everything that can go wrong in
# that table goes wrong identically whether it is buried in a P/Invoke loop or written as a
# 30-line function, but only the function can be tested in milliseconds against every branch.
# The measured instruments in scripts/ proved the facts; this file is the part that consumes
# them, and it is kept free of IO so a wrong verdict cannot hide behind a passing desktop.
#
# THE FACTS IT CONSUMES, and where each came from:
#   messageDoor  -- 17/57 live windows expose a classic child door (neutral-coverage-census)
#   hasPattern   -- WPF/UWP/Chromium expose UIA patterns; WinForms exposes none (probe-winform)
#   cursor cost  -- zero in every channel (channel-raise-matrix, 0 px across 24 rounds)
#   focus cost   -- message door 0/6 raise; UIA pattern 6/6 and 12/12 raise
# Each fact is a measurement, not a guess. A fact that was never measured is NOT allowed to
# default to the flattering branch: missing facts refuse, they do not assume quiet.

Set-StrictMode -Version 2.0

# Refusal codes are a closed set on purpose. A generic 'failed' would make the product unable to
# tell the model why, which is the one thing R3.2 forbids: 'bottoms out to a canned message'.
$script:WpmRefusals = @{
  no_hwnd            = 'no target hwnd supplied; refuse rather than guess from screen coordinates'
  paused             = 'owner paused input; server-side refusal, not a prompt-level hint'
  elevated_target    = 'target runs at a higher integrity level; a non-elevated process cannot write to it'
  unreachable        = 'no message door and no usable UIA pattern; this target cannot be driven without physical input'
  terminal_no_door   = 'terminal text surface exposes no child HWND and no Document element'
  needs_facts        = 'the caller supplied no measured facts for this target; refusing instead of assuming quiet'
}

function New-WpmFacts {
  # Explicit constructor so a missing field is a compile-time-shaped mistake in review rather
  # than a silent $null that compares false and lands in the quiet branch.
  param(
    [string]$Hwnd = '',
    [bool]$Paused = $false,
    [bool]$ElevatedTarget = $false,
    [string]$Family = 'unknown',        # win32-classic | winforms | wpf | uwp | chromium | terminal | unknown
    [bool]$MessageDoor = $false,
    [bool]$HasPattern = $false,
    [string]$PatternKind = 'none',      # invoke | value | toggle | selectionitem | legacy | none
    [string]$Action = 'click',          # click | type | key | scroll
    [bool]$FactsMeasured = $false
  )
  return @{
    hwnd = $Hwnd; paused = $Paused; elevatedTarget = $ElevatedTarget; family = $Family
    messageDoor = $MessageDoor; hasPattern = $HasPattern; patternKind = $PatternKind
    action = $Action; factsMeasured = $FactsMeasured
  }
}

function Get-WpmChannelDecision {
  <#
    Returns @{ channel; tier; needsRestore; refusal; reason }
      channel      'message' | 'uia' | 'refuse'
      tier         'quiet' | 'bounded-flash' | 'none'
      needsRestore true only for the bounded-flash tier
  ORDER OF CHECKS IS THE DESIGN. Pause and elevation are checked before any capability, because a
  capability check that runs first can return a working channel for an action that must be
  refused outright -- and the caller would then act while paused. The cheapest disqualifiers
  come first; the capability table only decides between tiers that are both permitted.
  #>
  param([hashtable]$Facts)

  if (-not $Facts) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'needs_facts'; reason = $script:WpmRefusals.needs_facts }
  }
  if ($Facts.paused) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'paused'; reason = $script:WpmRefusals.paused }
  }
  if (-not $Facts.hwnd) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'no_hwnd'; reason = $script:WpmRefusals.no_hwnd }
  }
  if ($Facts.elevatedTarget) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'elevated_target'; reason = $script:WpmRefusals.elevated_target }
  }
  # Terminal is its own code, not folded into 'unreachable': the two have different fixes (one is
  # "pick another target", the other is "this class will never work"), and a product that reports
  # one generic failure cannot be diagnosed by the person reading the output.
  if ($Facts.family -eq 'terminal' -and -not $Facts.messageDoor -and -not $Facts.hasPattern) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'terminal_no_door'; reason = $script:WpmRefusals.terminal_no_door }
  }

  # TIER 1: message door. Measured free -- 0/6 raises, effect verified app-side in 6/6, cursor 0 px.
  # Preferred whenever it exists, which INVERTS the original R2.2 priority (UIA first). The
  # original order preferred the channel that steals focus; this one prefers the channel that
  # does not. That inversion is the whole point of R2'.
  if ($Facts.messageDoor) {
    return @{ channel = 'message'; tier = 'quiet'; needsRestore = $false; refusal = ''; reason = 'classic child window accepts target-window messages' }
  }

  # TIER 2: UIA pattern. Measured to raise 6/6 and 12/12, therefore it always needs restoration.
  # A pattern with no path to restoration would be a permanent focus theft, so the caller is told
  # needsRestore=true and must honour it; the decision itself does not attempt the restore because
  # a pure function cannot.
  if ($Facts.hasPattern -and $Facts.patternKind -ne 'none') {
    return @{ channel = 'uia'; tier = 'bounded-flash'; needsRestore = $true; refusal = ''; reason = "UIA $($Facts.patternKind) pattern available; costs one bounded foreground flash" }
  }

  # Neither door. Refuse, and say which one was missing -- an unmeasured target must not be
  # guessed into the quiet branch, which is the failure this whole plan exists to avoid.
  if (-not $Facts.factsMeasured) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'needs_facts'; reason = $script:WpmRefusals.needs_facts }
  }
  return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
    refusal = 'unreachable'; reason = $script:WpmRefusals.unreachable }
}

function Get-WpmRestoreDecision {
  <#
    Whether to put the focus back after a bounded-flash action, and why.
    This is the safety property of R2'.4-R2'.7 expressed as a table, because these are the
    branches that, if wrong, act on a window the product does not own.

      currentFg == raisedHwnd            -> restore        (we caused it, we undo it)
      currentFg pid == target pid        -> skip: dialog   (the app deliberately focused its own dialog)
      currentFg is a third window        -> skip: taken    (the user or another app chose it; never fight)
      nothing was raised                 -> skip: nothing  (restoring here would fight the user)
      restore already attempted once     -> skip: done     (one-shot; a watchdog would fight the owner)

    The dialog branch is not a nicety: without it, restoring after an action that opened a Save
    dialog pulls the focus out of the dialog the action just created, so the box is visible and
    unresponsive. Same-pid is the discriminator because the dialog belongs to the target process.
  #>
  param(
    [string]$CurrentFg = '',
    [string]$RaisedHwnd = '',
    [string]$TargetPid = '',
    [string]$CurrentFgPid = '',
    [bool]$RaisedHappened = $false,
    [bool]$AlreadyRestored = $false
  )
  if ($AlreadyRestored) {
    return @{ restore = $false; outcome = 'skip'; reason = 'one-shot: a restore was already attempted for this action' }
  }
  if (-not $RaisedHappened) {
    return @{ restore = $false; outcome = 'skip'; reason = 'no raise occurred; restoring would fight the owner' }
  }
  if (-not $CurrentFg -or -not $RaisedHwnd) {
    return @{ restore = $false; outcome = 'skip'; reason = 'foreground or raised hwnd unknown' }
  }
  if ($CurrentFg -eq $RaisedHwnd) {
    return @{ restore = $true; outcome = 'restore'; reason = 'our own raised window owns the foreground; safe to reverse' }
  }
  if ($TargetPid -and $CurrentFgPid -and ($CurrentFgPid -eq $TargetPid)) {
    return @{ restore = $false; outcome = 'skip-dialog'; reason = 'same pid as the target: this is the app''s own dialog, not our theft' }
  }
  return @{ restore = $false; outcome = 'skip-taken'; reason = 'a third window holds the foreground; never pull it from the user' }
}
