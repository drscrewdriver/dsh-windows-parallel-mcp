# decide.ps1 -- the channel decision, as a PURE function.
#
# WHY PURE AND FIRST. The product turns on one table: which door a target has, and therefore what the
# action costs the owner. Everything that can go wrong in that table goes wrong identically whether it is
# buried in a P/Invoke loop or written as a 60-line function, but only the function can be tested in
# milliseconds against every branch. The measured instruments in scripts/ proved the facts; this file is
# the part that consumes them, and it is kept free of IO so a wrong verdict cannot hide behind a passing
# desktop.
#
# THE FACTS IT CONSUMES, and where each came from:
#   messageDoor   -- 17/57 live windows expose a classic child door (neutral-coverage-census)
#   hasPattern    -- WPF/UWP/Chromium expose UIA patterns; WinForms exposes none (probe-winform)
#   uiaTreeEmpty  -- an a11y-off Chromium window walks to ZERO content elements and never grows
#                    one under re-query (uTools 1/1/1 raw, 0/0/0 content, 2026-11-21; census read
#                    0/0/0 the same day) -- scripts/uia-tree-content.ps1 re-measures it
#   uiaProbeFailed-- the probe's own exception, carried out of win.ps1 as a boolean so the code
#                    selection never parses message text
#   cursor cost   -- zero in the quiet/bounded-flash tiers (channel-raise-matrix, 0 px across 24 rounds);
#                    the takeover tier moves it BY REQUEST and must put it back (spec.md §2)
#   focus cost    -- message door 0/6 raise; UIA pattern 6/6 and 12/12 raise
#   hudReady      -- the HUD is up RIGHT NOW (hud.ps1 Test-WpmHudReady); never assumed
#   foregroundIsTarget -- the target (or its child) is the foreground window, which is the only window
#                    SendInput writes into (measured: scripts/probe-sendinput-unicode.ps1)
# Each fact is a measurement, not a guess. A fact that was never measured is NOT allowed to default to
# the flattering branch: missing facts refuse, they do not assume quiet.
#
# FOUR TIERS, and the order the checks run in IS the safety design (spec.md §4):
#   quiet           window messages only; cursor 0px, focus untouched, no injection
#   bounded-flash   a UIA pattern; one foreground flash, reversed once
#   takeover        by explicit request: cursor moves to the point and is restored, focus held until the
#                   action ends, keyboard injection only if asked, HUD mandatory
#   refuse          a code and an executable next step
# The takeover tier never ADDS a click channel: a click still goes through message/UIA, SetCursorPos
# only makes the point visible, and SendInput is the last resort for targets that have no door at all.

Set-StrictMode -Version 2.0

# Refusal codes are a closed set on purpose. A generic 'failed' would make the product unable to
# tell the model why, which is the one thing R3.2 forbids: 'bottoms out to a canned message'.
$script:WpmRefusals = @{
  no_hwnd              = 'no target hwnd supplied; refuse rather than guess from screen coordinates'
  paused               = 'owner paused input; server-side refusal, not a prompt-level hint'
  elevated_target      = 'target runs at a higher integrity level; a non-elevated process cannot write to it, and UIPI refuses synthetic input to it as well'
  unreachable          = 'no message door and no usable UIA pattern; this target cannot be driven without physical input'
  uia_tree_empty       = 'the accessibility tree holds no content element at all: no pattern can ever appear here, and re-querying has nothing to wait for'
  uia_probe_failed     = 'the accessibility probe itself threw before it could measure this target; whether a usable pattern exists was never learned'
  terminal_no_door     = 'terminal text surface has child windows but none of them is writable: no WM_CHAR/WM_SETTEXT door and no UIA pattern. Keyboard injection into this host''s terminal was MEASURED not to work (findings §G3: Unicode and scan-code arms both accepted by SendInput, neither executed), so it is not offered as a next step. Next step: pick a target with a real door (an address bar, a text field, a WinForms edit) -- the terminal family remains read-blocked and, on this desktop, write-blocked too'
  needs_facts          = 'the caller supplied no measured facts for this target; refusing instead of assuming quiet'
  takeover_unavailable = 'takeover was requested but cannot run safely right now: the HUD is not up, or the takeover gate is off. Next step: enable takeoverAllowed in settings (the HUD is a hard precondition, not a decoration) or call without takeover:true'
  keyinject_unavailable= 'keyboard injection was requested but cannot run: this target is not the foreground window and could not be raised (or it is elevated). Next step: bring the target to the front yourself, or call without keyInput:''inject'''
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
    [bool]$FactsMeasured = $false,
    [bool]$UiaTreeEmpty = $false,       # the walked tree contained zero content elements (win.ps1 Test-WpmUiaTreeHasContent)
    [bool]$UiaProbeFailed = $false,     # the UIA probe threw; uiaErr carries the exception text (win.ps1)
    [bool]$TakeoverRequested = $false,  # caller asked for the takeover tier (takeover:true)
    [bool]$KeyInjectRequested = $false, # caller asked for keyboard injection (keyInput:'inject')
    [bool]$KeyInjectAllowed = $false,   # the host gate (keyInjectAllowed) let the request through
    [bool]$HudReady = $false,           # hud.ps1 says a HUD window is up RIGHT NOW
    [bool]$ForegroundIsTarget = $false  # GetForegroundWindow() (or its root) IS this target
  )
  return @{
    hwnd = $Hwnd; paused = $Paused; elevatedTarget = $ElevatedTarget; family = $Family
    messageDoor = $MessageDoor; hasPattern = $HasPattern; patternKind = $PatternKind
    action = $Action; factsMeasured = $FactsMeasured
    uiaTreeEmpty = $UiaTreeEmpty; uiaProbeFailed = $UiaProbeFailed
    takeoverRequested = $TakeoverRequested; keyInjectRequested = $KeyInjectRequested
    keyInjectAllowed = $KeyInjectAllowed; hudReady = $HudReady; foregroundIsTarget = $ForegroundIsTarget
  }
}

function Get-WpmChannelDecision {
  <#
    Returns @{ channel; tier; needsRestore; refusal; reason }
      channel      'message' | 'uia' | 'input' | 'refuse'
      tier         'quiet' | 'bounded-flash' | 'takeover' | 'none'
      needsRestore true only for the tiers that may take the foreground (uia / takeover-through-uia)
  ORDER OF CHECKS IS THE DESIGN. Pause, elevation and the takeover preconditions are checked before any
  capability, because a capability check that runs first can return a working channel for an action that
  must be refused outright. The cheapest disqualifiers come first; the capability table only decides
  between tiers that are both permitted.
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

  # ---- R3 preconditions. These are refusals about the REQUEST, not about the target, and they come
  # before the door table because a takeover that cannot show its HUD must not reach any primitive.
  if ($Facts.takeoverRequested -and -not $Facts.hudReady) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'takeover_unavailable'; reason = $script:WpmRefusals.takeover_unavailable }
  }
  if ($Facts.keyInjectRequested -and (-not $Facts.takeoverRequested -or -not $Facts.keyInjectAllowed)) {
    # Injection is allowed ONLY inside the takeover tier (spec.md §1: SendInput writes to the foreground,
    # so without the HUD and the cursor contract it would be a blind keystroke into whatever is in front).
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'keyinject_unavailable'; reason = $script:WpmRefusals.keyinject_unavailable }
  }
  if ($Facts.keyInjectRequested -and -not $Facts.foregroundIsTarget) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'keyinject_unavailable'; reason = $script:WpmRefusals.keyinject_unavailable }
  }

  $tier = if ($Facts.takeoverRequested) { 'takeover' } else { 'quiet' }

  # TIER 1: message door. Measured free -- 0/6 raises, effect verified app-side in 6/6, cursor 0 px.
  # Preferred whenever it exists, which INVERTS the original R2.2 priority (UIA first). The original
  # order preferred the channel that steals focus; this one prefers the channel that does not.
  if ($Facts.messageDoor) {
    return @{ channel = 'message'; tier = $tier; needsRestore = $false; refusal = ''
      reason = 'classic child window accepts target-window messages' }
  }

  # TIER 2: UIA pattern. Measured to raise 6/6 and 12/12, therefore it always needs restoration.
  if ($Facts.hasPattern -and $Facts.patternKind -ne 'none') {
    return @{ channel = 'uia'; tier = $tier; needsRestore = $true; refusal = ''
      reason = "UIA $($Facts.patternKind) pattern available" + $(if ($Facts.takeoverRequested) { '; takeover keeps the focus until the action ends, then restores it' } else { '; costs one bounded foreground flash' }) }
  }

  # TIER 3: no door at all. A terminal is the measured case (findings §B): three child HWNDs, none
  # writable.
  #
  # THE TERMINAL INJECTION PATH WAS WITHDRAWN ON MEASURED EVIDENCE, and this branch is where that decision
  # lives. R3's plan was to drive a terminal by typing into it once the owner asked for takeover+inject.
  # Two independent probes say it does not work on this host (findings §G3, 2026-11-23):
  #   * scripts/probe-console-inject.ps1 -- KEYEVENTF_UNICODE: 242 events accepted by SendInput, the
  #     foreground WAS the terminal, Enter was pressed, and the shell never executed the typed command;
  #   * scripts/probe-console-scan.ps1    -- KEYEVENTF_SCANCODE with the layout's own VK mapping: 262
  #     events, same setup, still nothing executed.
  # So "the only door left is the keyboard" was wrong for the terminal family on this desktop, and making
  # the code path look like a capability would be a promise the product cannot keep. The refusal keeps its
  # diagnostic value and points at what DOES work (a target with a real door).
  if ($Facts.family -eq 'terminal' -and -not $Facts.messageDoor -and -not $Facts.hasPattern) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'terminal_no_door'; reason = $script:WpmRefusals.terminal_no_door }
  }

  # A doorless, patternless NON-terminal target can also be driven by injection when explicitly asked:
  # the measured UWP/Chromium families sometimes expose neither door, and the keyboard is real input.
  if ($Facts.takeoverRequested -and $Facts.keyInjectRequested -and $Facts.factsMeasured) {
    return @{ channel = 'input'; tier = 'takeover'; needsRestore = $false; refusal = ''
      reason = 'no message door and no usable pattern; typing into the foreground target at the owner''s explicit request' }
  }

  # Neither door. Refuse, and say which one was missing -- an unmeasured target must not be
  # guessed into the quiet branch, which is the failure this whole plan exists to avoid.
  if (-not $Facts.factsMeasured) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'needs_facts'; reason = $script:WpmRefusals.needs_facts }
  }

  # THREE WORLDS USED TO SHARE ONE CODE ('unreachable'), and they have different fixes, which is why they
  # stopped sharing it (2026-11-21: 0.1.5's point-probe fix exposed uiaErr arriving here as dead data; the
  # census the same day exposed the tree split). A tree with NO content element needs the APPLICATION to
  # enable accessibility -- launch-time for Chromium (--force-renderer-accessibility); re-querying cannot
  # help, which is exactly why no retry or polling exists anywhere in this engine. A probe that THREW
  # means the measurement itself failed, so no conclusion about the target is licensed -- the exception
  # text rides the reason (engine.ps1 appends it). Probe failure outranks tree-empty: a measurement that
  # threw cannot also certify emptiness. And a usable door still outranks every diagnosis.
  if ($Facts.uiaProbeFailed) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'uia_probe_failed'; reason = $script:WpmRefusals.uia_probe_failed }
  }
  if ($Facts.uiaTreeEmpty) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'uia_tree_empty'; reason = $script:WpmRefusals.uia_tree_empty }
  }
  return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
    refusal = 'unreachable'; reason = $script:WpmRefusals.unreachable }
}

function Get-WpmRestoreDecision {
  <#
    Whether to put the focus back after an action that may have taken it, and why.
    This is the safety property of R2'.4-R2'.7 expressed as a table, because these are the branches
    that, if wrong, act on a window the product does not own.

      currentFg == raisedHwnd            -> restore        (we caused it, we undo it)
      currentFg pid == target pid        -> skip: dialog   (the app deliberately focused its own dialog)
      currentFg is a third window        -> skip: taken    (the user or another app chose it; never fight)
      nothing was raised                 -> skip: nothing  (restoring here would fight the user)
      restore already attempted once     -> skip: done     (one-shot; a watchdog would fight the owner)

    The dialog branch is not a nicety: without it, restoring after an action that opened a Save dialog
    pulls the focus out of the dialog the action just created, so the box is visible and unresponsive.
    Same-pid is the discriminator because the dialog belongs to the target process.
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
