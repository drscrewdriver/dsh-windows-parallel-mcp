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
  # ---- 0.7.0 authorization model. Three codes, each naming the NEXT STEP rather than describing the
  # symptom, because all three are settings decisions and a caller that cannot tell which setting to
  # raise will retry the same call forever.
  policy_denied        = 'the action''s declared tier is above what the policy setting allows. Next step: raise policy in settings (readonly < quiet < balanced < full) -- NOT retrying this call'
  user_active          = 'the owner was at the keyboard when this was asked for (last physical input younger than policyIdleMs) and the action needs the takeover tier. This product does not open a dialog at someone who is typing -- a popup is a second disturbance dressed as consent. Next step: wait for idle, or pass forceUserActive:true explicitly (it is recorded in the audit log as forced)'
  app_launch_denied    = 'launch is not authorised: appLaunchAllowed is off, or the program is not on the appLaunchAllow whitelist (an empty whitelist means nothing may launch). Next step: the OWNER adds the exact name to the whitelist; a wildcard does not exist and this refusal is not a transient failure to retry through'
}

# THE LADDER, mirrored from lib/policy.js. Two copies of an ordering is normally the bug pattern this
# repo refuses, and it is allowed here for exactly one reason: the engine and the host each need the
# comparison in their own process, and scripts/check-policy-table.mjs asserts the two copies agree
# (rung set, order, and every action's declared tier in tools.json). A drift between them is red at build
# time instead of being a permission the owner believes they revoked.
$script:WpmTierOrder = @('readonly', 'quiet', 'flash', 'takeover')
$script:WpmPolicyCeiling = @{
  readonly = 'readonly'; quiet = 'quiet'; balanced = 'flash'; full = 'takeover'
}

function Test-WpmTierAllowed {
  # Pure, and it fails CLOSED in both directions: an unknown policy or an unknown rung answers false.
  # "Unparseable setting" and "everything allowed" must never read the same way.
  param([string]$Policy, [string]$Required)
  if (-not $script:WpmPolicyCeiling.ContainsKey($Policy)) { return $false }
  $need = [Array]::IndexOf($script:WpmTierOrder, $Required)
  if ($need -lt 0) { return $false }
  return $need -le [Array]::IndexOf($script:WpmTierOrder, $script:WpmPolicyCeiling[$Policy])
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
    [bool]$ForegroundIsTarget = $false,  # GetForegroundWindow() (or its root) IS this target
    # ---- 0.7.0 authorization facts, supplied by the caller because decide.ps1 does no IO: it cannot
    # read settings, and a table that read its own permissions could not be unit-tested.
    [string]$Policy = 'balanced',         # the ceiling the owner set (readonly|quiet|balanced|full)
    [string]$RequiredTier = 'quiet',      # what THIS action needs at minimum (tools.json#requiresTier)
    [long]$LastInputAgeMs = -1,           # -1 = UNKNOWN; unknown refuses, it does not mean "idle"
    [int]$PolicyIdleMs = 3000,
    [bool]$ForceUserActive = $false,      # the caller's explicit override, recorded in the audit
    [bool]$AppLaunchAllowed = $false,
    [string[]]$AppLaunchAllow = @(),
    [string]$LaunchTarget = ''
  )
  return @{
    hwnd = $Hwnd; paused = $Paused; elevatedTarget = $ElevatedTarget; family = $Family
    messageDoor = $MessageDoor; hasPattern = $HasPattern; patternKind = $PatternKind
    action = $Action; factsMeasured = $FactsMeasured
    uiaTreeEmpty = $UiaTreeEmpty; uiaProbeFailed = $UiaProbeFailed
    takeoverRequested = $TakeoverRequested; keyInjectRequested = $KeyInjectRequested
    keyInjectAllowed = $KeyInjectAllowed; hudReady = $HudReady; foregroundIsTarget = $ForegroundIsTarget
    policy = $Policy; requiredTier = $RequiredTier
    lastInputAgeMs = $LastInputAgeMs; policyIdleMs = $PolicyIdleMs; forceUserActive = $ForceUserActive
    appLaunchAllowed = $AppLaunchAllowed; appLaunchAllow = $AppLaunchAllow; launchTarget = $LaunchTarget
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
  # ---- 0.7.0 launch is not a windowed action, so the target checks do not apply to it ----------
  # `no_hwnd` and `elevated_target` are statements ABOUT A TARGET WINDOW. `launch` has no target window at
  # the moment it is decided -- that is precisely the point of the action -- and letting a hwnd check run
  # first would turn every launch refusal into a wrong one (`no_hwnd` tells the caller to go find a
  # handle, which is not what an unauthorised program name means). Guarded by the action rather than by
  # handing the table a fake hwnd, because a fabricated fact in a decision table is how tables lie.
  $isWindowedAction = $Facts.action -ne 'launch'
  if ($isWindowedAction -and (-not $Facts.hwnd)) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'no_hwnd'; reason = $script:WpmRefusals.no_hwnd }
  }
  if ($isWindowedAction -and $Facts.elevatedTarget) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'elevated_target'; reason = $script:WpmRefusals.elevated_target }
  }

  # ---- 0.7.0-A the policy ceiling, BEFORE any capability is consulted --------------------------
  # Why here and not at the takeover branch: `policy` answers "may this rung be used at all", and a
  # capability check that runs first can produce a working channel for an action the owner excluded --
  # the same ordering mistake the pause check documents above. The refusal names the setting to raise,
  # because the correct response to this code is a settings change, never a retry.
  if (-not (Test-WpmTierAllowed $Facts.policy $Facts.requiredTier)) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'policy_denied'
      reason = $script:WpmRefusals.policy_denied + " [action needs $($Facts.requiredTier); policy '$($Facts.policy)' allows at most $($script:WpmPolicyCeiling[$Facts.policy])]" }
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

  # ---- 0.7.0 the launch gate and its whitelist, double-checked here -----------------------------
  # The host applies this BEFORE any worker request; this is the second line, because a permission that
  # exists only in one process is a permission that can be reached around by calling the other one (the
  # same argument that puts the HUD re-check in engine.ps1 rather than trusting the gate). ORDER MATTERS:
  # this runs after the per-tier preconditions and BEFORE the idle check, which is the sequence the plan
  # specifies -- an unauthorised program must be reported as unauthorised, not as "the owner is busy",
  # because the two refusals tell the caller to change two different things.
  if ($Facts.action -eq 'launch') {
    if (-not $Facts.appLaunchAllowed) {
      return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
        refusal = 'app_launch_denied'; reason = $script:WpmRefusals.app_launch_denied + ' [appLaunchAllowed is off]' }
    }
    $t = if ($Facts.launchTarget) { $Facts.launchTarget.ToLower() } else { '' }
    $hit = $false
    foreach ($w in @($Facts.appLaunchAllow)) {
      # EXACT match, case-folded. No wildcard, no prefix, no substring: `notepad` must not authorise
      # `notepad-helper.exe`, and a prefix rule is the shape of a whitelist that expands by accident.
      if ($w -and ([string]$w).Trim().ToLower() -ceq $t) { $hit = $true; break }
    }
    if (-not $hit) {
      return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
        refusal = 'app_launch_denied'
        reason = $script:WpmRefusals.app_launch_denied + " [no exact entry for '$t'; whitelist holds $(@($Facts.appLaunchAllow).Count) name(s)]" }
    }
    # Fall through to the idle check below: an authorised name is still not permission to start a program
    # while someone is typing at this keyboard.
  }

  # ---- 0.7.0-B idle sensing: the owner is at the keyboard, so do not interrupt them -------------
  # Only a takeover-tier action is refused here. The quiet and flash tiers do not touch the owner's
  # cursor or hold their focus, so "you are busy" does not apply to them -- refusing those would refuse
  # the reason this product exists. `launch` reaches here with requiredTier 'takeover', so starting a
  # program while the owner is typing is refused too: that is the plan's order, and it is the correct
  # one, because a program started at the wrong moment is the least interruptible action in this product.
  #
  # AN UNKNOWN AGE ALLOWS, and that is a decision rather than an oversight. `LastInputAgeMs` answers -1
  # when GetLastInputInfo fails; refusing on -1 would block every takeover on a machine where that one
  # API does not answer, and the owner who opted into takeoverAllowed has already accepted the tier. This
  # is the OPPOSITE of how the proof path treats -1 (there, unknown must never be read as "the desktop
  # was still", because that would launder a disturbance into innocence) -- the two directions differ
  # because the costs differ: here unknown costs an agent a convenience, there it costs the owner the
  # truth. Both choices are stated where the comparison is made rather than inherited from a convention.
  #
  # Written as one-line conditions: a multi-line `if (A -and -not B` newline `-and C)` expression reads
  # fine to a human and fails the PowerShell parser at the `-and` that opens the continuation line -- a
  # runtime-only parse failure in a dot-sourced file, which surfaces as `action_failed` from the worker.
  $needsTakeover = ($Facts.requiredTier -eq 'takeover')
  $ageKnown = ([long]$Facts.lastInputAgeMs -ge 0)
  $ownerPresent = ($ageKnown -and ([long]$Facts.lastInputAgeMs -lt [int]$Facts.policyIdleMs))
  if ($needsTakeover -and $ownerPresent -and (-not $Facts.forceUserActive)) {
    return @{ channel = 'refuse'; tier = 'none'; needsRestore = $false
      refusal = 'user_active'
      reason = $script:WpmRefusals.user_active + " [last physical input $($Facts.lastInputAgeMs)ms ago; policyIdleMs=$($Facts.policyIdleMs)]" }
  }

  if ($Facts.action -eq 'launch') {
    return @{ channel = 'launch'; tier = 'takeover'; needsRestore = $false; refusal = ''
      reason = 'launch is authorised by both switches and the owner is not at the keyboard' }
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
