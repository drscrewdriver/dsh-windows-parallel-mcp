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
    # The HUD travels with status for the same reason the overlay does: "the takeover surface exists"
    # must be checkable by the owner and by an independent oracle, not inferred from a successful call.
    hudOn = [bool][WpmCtl]::HudOn
    hudHwnd = [string][WpmCtl]::HudHwnd
    hudPhase = [string][WpmCtl]::HudPhase
    abortChord = [string][WpmCtl]::AbortChordLabel
    abortRequested = [bool][WpmCtl]::TakeoverAbort
    hotkeyRegistered = [bool][WpmCtl]::HotkeyOk
    hotkeyLabel = [string][WpmCtl]::HotkeyLabel
    overlayReason = [string][WpmCtl]::Reason
    dpiAware = [bool]$script:WpmDpiAware
    stance = 'quiet tier: no physical input at all; takeover tier (opt-in, HUD mandatory): cursor moves and is always restored, keyboard typed only when asked, three interrupt paths, no mouse injection'
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
  # Which child HWND sits under a screen point, or Zero with the REASON recorded.
  #
  # The hit test refuses two different worlds with the same word, and the refusal text has to keep
  # them apart because their next steps do not overlap: a point outside every child of the named
  # window is a wrong coordinate; a point that IS inside one of our children but has a foreign window
  # on top is COVERAGE.
  #
  # WHY COVERAGE STILL REFUSES, when SendMessageW needs no visibility. Measured 2026-11-24: with the
  # owner's browser covering the target (target visible=true, rect 120,120,540,420; WindowFromPoint
  # over its own button returned Chrome_WidgetWin_1), delivering WM_LBUTTONDOWN/UP to the button
  # returned ok and the application NEVER RAN THE HANDLER -- focusTaken=false, button caption
  # unchanged. A click the app silently ignores is worse than a refusal that says why: the first
  # reports success for something that did not happen. So this refuses, names the blocker class, and
  # points at the only next step that works (bring the target forward).
  #
  # Index order is still not a contract (the original note): when the point is ours, the child is
  # chosen by which RECT holds it, never by its position in the enumeration.
  $p = New-Object 'WpmWin+POINT'
  $p.X = $X; $p.Y = $Y
  $hit = [WpmWin]::WindowFromPoint($p)
  $script:WpmPointCovered = $false
  $script:WpmPointBlocker = ''
  if ($hit -ne [IntPtr]::Zero -and [WpmWin]::Root($hit) -eq $Hwnd) { return $hit }
  foreach ($c in @([WpmWin]::Children($Hwnd))) {
    $child = [IntPtr]$c
    $r = New-Object 'WpmWin+RECT'
    if (-not [WpmWin]::GetWindowRect($child, [ref]$r)) { continue }
    if ($X -ge $r.Left -and $X -lt $r.Right -and $Y -ge $r.Top -and $Y -lt $r.Bottom) {
      $script:WpmPointCovered = $true
      if ($hit -ne [IntPtr]::Zero) { $script:WpmPointBlocker = [WpmWin]::Cls([WpmWin]::Root($hit)) }
      return [IntPtr]::Zero
    }
  }
  return [IntPtr]::Zero
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
    # NOT Mandatory any more: a full-screen screenshot (screenshot + fullScreen:true) legitimately has
    # no target window, and PowerShell REFUSES to bind an empty string to a Mandatory [string]
    # parameter -- which surfaced as "cannot bind argument to parameter 'Hwnd' because it is an empty
    # string" instead of the capture the caller asked for. Every windowed action still checks liveness
    # itself and returns no_hwnd, so nothing was made lenient except the binding.
    [string]$Hwnd = '',
    [Parameter(Mandatory)][ValidateSet('click', 'type', 'focus', 'status', 'snapshot', 'screenshot', 'preview')][string]$Action,
    [int]$X = -1,
    [int]$Y = -1,
    [string]$Text = '',
    [string]$ElementName = '',
    [switch]$Replace,
    [int]$SettleMs = 350,
    # ---- R3 ------------------------------------------------------------------------------------
    # Takeover is a REQUEST with preconditions, never a flag that silently upgrades an action
    # (spec.md §4). TakeoverArmMs is the cancellation window; HudDoneMs is how long the "returned"
    # phase stays on screen before the HUD is torn down.
    [switch]$Takeover,
    [int]$TakeoverMaxMs = 10000,
    [switch]$KeyInject,
    [int]$TakeoverArmMs = 800,
    [int]$HudDoneMs = 1500,
    # ---- 0.5.0 read paths and element addressing ------------------------------------------------
    # `Space` is the coordinate space of X/Y for click. 'image' means the numbers came from a
    # screenshot and the ENGINE converts them: the caller never multiplies a scale factor, which is
    # the failure the upstream library documents against itself ("Click lands in the wrong place").
    [ValidateSet('screen', 'image')][string]$Space = 'screen',
    [string]$ShotId = '',
    # A label is a reference into the LAST frame this worker printed. It is resolved back to the UIA
    # element by RuntimeId, so a labelled action still takes the silent pattern path.
    [int]$Label = 0,
    [string]$SnapId = '',
    [int]$MaxElements = 300,
    [bool]$InteractableOnly = $true,
    [string]$SinceSnapId = '',
    [string]$Intent = '',
    [bool]$FullScreen = $false,
    [int]$MaxWidth = 0,
    [int]$ShotsKeep = 10,
    # ---- 0.6.0: where the caret should be when the message door types (type only) ----------------
    # `idle` is the existing behaviour and stays the default: nothing is touched, so an upgrade cannot
    # start moving carets on its own. `end` is implemented as EM_SETSEL(len,len) with len read from the
    # control, NOT as the documented -1 -- measured on WinForms EDIT, EM_SETSEL(-1,-1) leaves the
    # selection at 0,0 and the character lands at the FRONT (findings 8.2). The UIA `value` channel
    # replaces the whole value and has no caret to place, so it reports caretIgnored rather than
    # pretending the request was honoured.
    [ValidateSet('idle', 'start', 'end')][string]$CaretPosition = 'idle',
    # ---- 0.7.0 authorization, measured here because only this process can see the desktop -------
    # `Policy` and `RequiredTier` come from the host (settings + tools.json). The IDLE CHECK cannot come
    # from the host: last-input age is a GetLastInputInfo reading, and a host that wanted it before the
    # worker call would have to make a worker call. So the ceiling is enforced twice (host pre-worker,
    # engine here) and idle is enforced once, at the only place the number exists.
    [string]$Policy = 'balanced',
    [string]$RequiredTier = 'quiet',
    [int]$PolicyIdleMs = 3000,
    [switch]$ForceUserActive
  )
  $started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $h = [IntPtr][int64]$Hwnd
  $result = @{
    ok = $false; action = $Action; hwnd = $Hwnd; channel = ''; tier = ''
    refusal = ''; reason = ''; detail = ''; latencyMs = 0
    focusTaken = 'false'; restoreOutcome = ''; restoreSetFg = ''; restoreJoined = ''
    effect = 'unverified'; proofSamples = @()
    # R3 fields. Empty strings rather than $null so the host half can test truthiness without
    # distinguishing "not a takeover" from "a takeover that said nothing".
    takeover = 'false'; cursorMoved = ''; cursorRestored = ''; takeoverMs = 0
    abortChord = ''; keysInjected = 0; injectedChars = 0
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
    # The DPI stance travels with status because the read paths (snapshot rects, screenshot pixels)
    # are only in PHYSICAL pixels while this process is per-monitor DPI aware. A future deletion of the
    # setter would otherwise turn the whole coordinate story half-scale with nothing to notice.
    $result.dpiAware = [bool]$st.dpiAware
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
    return $result
  }

  # ---- 0.5.0 READ PATHS: snapshot / screenshot / preview --------------------------------------
  # A READ IS NOT AN ACTION. None of these three writes an input-queue entry, takes the focus, or
  # produces a proof window -- there is no action to prove. They sit before the hwnd check because a
  # full-screen capture has no target window at all; each branch performs its own liveness check, so a
  # dead handle is still `no_hwnd` and a paused engine still says `paused` rather than serving reads.
  if ($Action -eq 'snapshot' -or $Action -eq 'screenshot' -or $Action -eq 'preview') {
    if ([WpmCtl]::Paused) {
      $result.refusal = 'paused'; $result.reason = $script:WpmRefusals.paused
      $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
      return $result
    }
    $needsWindow = -not ($Action -eq 'screenshot' -and $FullScreen)
    if ($needsWindow -and (-not $h -or -not [WpmWin]::IsWindow($h))) {
      $result.refusal = 'no_hwnd'; $result.reason = 'the hwnd does not identify a live window'
      $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
      return $result
    }
    $result.channel = 'none'; $result.tier = 'none'
    if ($Action -eq 'snapshot') {
      try {
        $snap = Get-WpmSnapshotTree -Hwnd $h -MaxElements $MaxElements -InteractableOnly $InteractableOnly `
          -Intent $Intent -SinceSnapId $SinceSnapId
      } catch {
        $result.refusal = 'uia_probe_failed'
        $result.reason = 'the accessibility probe threw while walking the tree: ' + $_.Exception.Message
        $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
        return $result
      }
      $snapFrame = if ($snap.ContainsKey('frame')) { [string]$snap.frame } else { '' }
      $snapCheck = if ($snap.ContainsKey('frameCheck')) { [string]$snap.frameCheck } else { '' }
      if (-not $snap.ok) {
        # THREE FAILURE WORLDS, three codes: a superseded id is stale_ref (re-read the frame); a frame
        # self-check failure is a refusal to point at all (unreachable -- the coordinates cannot be
        # trusted); anything else means the walk itself failed to measure (uia_probe_failed).
        if ($snap.stale) { $result.refusal = 'stale_ref' }
        elseif ($snapCheck -eq 'fail') { $result.refusal = 'unreachable' }
        else { $result.refusal = 'uia_probe_failed' }
        $result.reason = [string]$snap.reason
        $result.frame = $snapFrame
        $result.frameCheck = $snapCheck
        $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
        return $result
      }
      $result.ok = $true
      $result.detail = 'snapshot: read only, no action taken'
      $result.snapId = [string]$snap.snapId
      $result.frame = $snapFrame
      $result.frameCheck = $snapCheck
      $result.frameInset = $snap.frameInset
      $result.outsideFrame = [int]$snap.outsideFrame
      $result.intent = [string]$snap.intent
      $result.total = [int]$snap.total
      $result.count = [int]$snap.count
      $result.truncated = [bool]$snap.truncated
      $result.elements = @($snap.elements)
      $result.delta = $snap.delta
      $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
      return $result
    }
    if ($Action -eq 'screenshot') {
      try {
        $shot = Get-WpmScreenshot -Hwnd $h -FullScreen $FullScreen -MaxWidth $MaxWidth -Keep $ShotsKeep
      } catch {
        $result.refusal = 'action_failed'
        $result.reason = 'the capture threw: ' + $_.Exception.Message
        $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
        return $result
      }
      if (-not $shot.ok) {
        $result.refusal = 'action_failed'; $result.reason = [string]$shot.reason
        $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
        return $result
      }
      $result.ok = $true
      $result.detail = 'screenshot: read only, no action taken'
      $result.shotId = [string]$shot.shotId
      $result.file = [string]$shot.file
      $result.screenRect = $shot.screenRect
      $result.imageSize = $shot.imageSize
      $result.scale = [double]$shot.scale
      $result.identity = [bool]$shot.identity
      $result.frame = [string]$shot.frame
      # WHICH CAPTURE PATH PRODUCED THE PICTURE. Reported on every screenshot, not only when the cheap
      # path failed: a field that appears only in the exceptional case is how a silent substitution looks.
      $result.captureBackend = [string]$shot.captureBackend
      if ($shot.captureNote) { $result.captureNote = [string]$shot.captureNote }
      $result.dpiAware = [bool]$shot.dpiAware
      $result.bytes = [long]$shot.bytes
      $result.shotsKeep = [int]$shot.shotsKeep
      $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
      return $result
    }
    # ---- preview: draw the point, report the element under it as TEXT -------------------------
    $pv = Get-WpmPreviewAt -Hwnd $h -X $X -Y $Y
    if (-not $pv.ok) {
      if ($pv.outside) {
        $result.refusal = 'unreachable'
        $result.reason = 'the preview point does not belong to the target window: ' + [string]$pv.reason
      } else {
        # NOT `unreachable`: the point may be fine. The probe itself failed, so no conclusion about
        # what is under it is licensed -- the same distinction uia_probe_failed already draws.
        $result.refusal = 'uia_probe_failed'
        $result.reason = [string]$pv.reason
      }
      $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
      return $result
    }
    # THE MARKER IS A REQUEST, NOT AN ACTION (overlay.ps1 Set-WpmOverlayMarker writes three fields and
    # returns). A missing overlay downgrades to text only -- it must never fail the preview, because
    # "what is under this point" is answerable without a picture.
    $marker = @{ ok = $false; reason = 'overlay not loaded' }
    try {
      . (Join-Path $PSScriptRoot 'overlay.ps1')
      $marker = Set-WpmOverlayMarker -X $X -Y $Y
    } catch {
      $marker = @{ ok = $false; reason = 'overlay unavailable: ' + $_.Exception.Message }
    }
    $result.ok = $true
    $result.detail = 'preview: would click ' + $X + ',' + $Y
    $result.previewX = [int]$X
    $result.previewY = [int]$Y
    $result.previewAtPoint = [bool]$pv.atPoint
    $result.previewName = [string]$pv.name
    $result.previewControlType = [string]$pv.controlType
    $result.previewAutomationId = [string]$pv.automationId
    $result.previewRect = $pv.rect
    $result.previewReason = [string]$pv.reason
    $result.markerPlaced = [bool]$marker.ok
    $result.markerReason = if ($marker.ContainsKey('reason')) { [string]$marker.reason } else { '' }
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
    return $result
  }

  if (-not [WpmWin]::IsWindow($h)) {
    $result.refusal = 'no_hwnd'; $result.reason = 'the hwnd does not identify a live window'
    return $result
  }

  # ---- 0.6.0: a DISABLED target is a fact about the target, and Windows discards input to it -----
  # Measured (findings 8.1): with EnableWindow(false) every message this engine sends still RETURNS --
  # WM_SETTEXT and WM_CHAR both answer as if they worked, and the control simply does not take the click.
  # This is deliberately not a new refusal code: 'disabled' is a state of the target, not an error in the
  # call, and the caller may well want to know that the window is there but greyed out. What it does cost
  # is the right to claim an effect: `effect` is pinned to 'unverified' for a disabled target, so a
  # green-looking result cannot be produced by a window that was throwing our input away.
  $targetDisabled = -not [WpmWin]::IsWindowEnabled($h)

  # ---- 0.5.0: image coordinates are converted by the ENGINE, before anything is probed ---------
  # Why here: a bogus shotId must cost zero target probing, and the converted point then flows through
  # the EXISTING click path unchanged -- including the point-ownership assertion and the proof window.
  # Nothing about the safety contract is relaxed by accepting image coordinates.
  if ($Action -eq 'click' -and $Space -eq 'image') {
    $conv = Convert-WpmImagePoint -ShotId $ShotId -X $X -Y $Y
    if (-not $conv.ok) {
      $result.refusal = if ($conv.stale) { 'stale_ref' } else { 'unreachable' }
      $result.reason = [string]$conv.reason
      $result.coordSpace = 'image'
      $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
      return $result
    }
    $result.coordSpace = 'image'
    $result.shotId = [string]$ShotId
    $result.scale = [double]$conv.scale
    $result.imagePoint = "$X,$Y"
    $result.screenPoint = "$($conv.x),$($conv.y)"
    $X = [int]$conv.x
    $Y = [int]$conv.y
  }

  # Coordinates travel into the probe: the UIA tier resolves the element AT THE POINT. Without them
  # an unnamed click had no way to be anything other than "first control in tree order".
  $probe = Get-WpmFacts -Hwnd $h -Action $Action -ElementName $ElementName -X $X -Y $Y
  $facts = $probe.facts
  $facts.paused = [bool][WpmCtl]::Paused
  # ---- 0.5.0: a LABEL addresses the element itself -------------------------------------------
  # The label is resolved back to the UIA element by RuntimeId (measured stable across queries, 71/71),
  # so the action keeps the silent pattern path and never degrades into a coordinate click. Two things
  # are then enforced, and they are deliberately redundant:
  #   * the label must still resolve, otherwise this is a reference to a frame that is gone (stale_ref);
  #   * for a click, the caller's point must fall inside the labelled element -- "the point is the
  #     contract" is not weakened by adding a second way to name the target.
  if ($Label -gt 0) {
    $res = Resolve-WpmSnapshotLabel -Hwnd $h -Label $Label -SnapId $SnapId
    if (-not $res.ok) {
      $result.refusal = 'stale_ref'; $result.reason = [string]$res.reason
      $result.label = $Label
      $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
      return $result
    }
    if ($Action -eq 'click' -and $X -ge 0 -and $Y -ge 0) {
      $lr = $res.row.rect
      $eps = 2
      if ($X -lt ([int]$lr.left - $eps) -or $X -gt ([int]$lr.right + $eps) -or
          $Y -lt ([int]$lr.top - $eps) -or $Y -gt ([int]$lr.bottom + $eps)) {
        $result.refusal = 'unreachable'
        $result.reason = "label $Label is at rect=$($lr.left),$($lr.top),$($lr.right),$($lr.bottom) but the click point is $X,$Y -- the label and the point must agree before either is used"
        $result.label = $Label
        $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
        return $result
      }
    }
    $probe.uiaElement = $res.element
    $probe.uiaReason = ''
    $facts.hasPattern = $true
    $facts.patternKind = [string]$res.patternKind
    $facts.uiaTreeEmpty = $false
    $facts.uiaProbeFailed = $false
    $facts.messageDoor = $false   # a window message cannot address "label 3"
    $result.label = $Label
    $result.snapId = [string]$res.snapId
  }
  if ($ElementName) {
    # A named control cannot be addressed through a window message: the message tiers take
    # coordinates or a child HWND, and "the Save button" is neither. Suppressing the door here is
    # what makes 'click the named button' honest -- claiming the quiet tier while actually having
    # to raise the window would report the cheap tier for the expensive action.
    $facts.messageDoor = $false
  }
  # ---- R3: the takeover request, and the HUD that must exist BEFORE the table can approve it ----
  # Order is the safety design: cheap disqualifiers first (a paused or elevated refusal must never spawn
  # a window), then the HUD, then the full decision. $Facts.hudReady is therefore a MEASUREMENT of the
  # HUD that was actually started, not an assumption that "we are about to start one".
  $facts.takeoverRequested = [bool]$Takeover
  $facts.keyInjectRequested = [bool]$KeyInject
  $facts.keyInjectAllowed = [bool]$KeyInject     # the host gate already stripped the field when off
  $facts.hudReady = $false
  $facts.foregroundIsTarget = $false
  # 0.7.0: the rung this call actually needs. An explicit takeover request outranks the action's declared
  # minimum because moving the real cursor IS the higher permission; that escalation has to be visible to
  # the policy and idle checks or `policy:'quiet'` would be bypassed by a single flag.
  $facts.policy = $Policy
  $facts.requiredTier = $(if ($Takeover -or $KeyInject) { 'takeover' } else { $RequiredTier })
  $facts.forceUserActive = [bool]$ForceUserActive
  $facts.policyIdleMs = $PolicyIdleMs
  # Measured NOW, not carried from the earlier probe: an age read before the HUD came up would describe a
  # desktop that no longer exists, and the whole point of this fact is "was the owner busy a moment ago".
  $facts.lastInputAgeMs = [WpmWin]::LastInputAgeMs()
  $preFacts = $facts.Clone()
  $preFacts.takeoverRequested = $false
  $preFacts.keyInjectRequested = $false
  # THE ESCALATION GOES BACK OUT TOO. `requiredTier` was raised to 'takeover' a few lines above because
  # this call asks for the takeover tier; the pre-pass exists precisely to ask "what does the ACTION
  # itself need", so leaving the escalated rung in place made a `keyInput:'inject'`-only call answer
  # `user_active` (an idle refusal) instead of the `keyinject_unavailable` the arm asserts. A clone that
  # clears the request flags must clear what those flags implied, or the pre-pass measures a different
  # call than the one it claims to be checking.
  $preFacts.requiredTier = $RequiredTier
  $pre = Get-WpmChannelDecision $preFacts
  # THE CHEAP DISQUALIFIERS RUN BEFORE ANY WINDOW IS CREATED. 0.7.0 adds policy_denied and user_active to
  # this list rather than letting them be discovered later: a takeover request that the owner's settings
  # exclude must not flash a HUD at them on its way to saying no -- the HUD is itself the disturbance the
  # refusal exists to prevent.
  if ($pre.channel -eq 'refuse' -and (@('paused', 'no_hwnd', 'elevated_target', 'policy_denied', 'user_active') -contains $pre.refusal)) {
    $result.refusal = $pre.refusal; $result.reason = $pre.reason
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
    return $result
  }
  # BEFORE ANY RAISE. If the injection path has to bring the target forward, the focus table must be
  # captured first, or the raise looks like a third party's and would never be reversed.
  $entry = Get-WpmFocusEntry
  $hudStarted = $false
  $raisedByUs = $false
  if ($facts.takeoverRequested) {
    # G2: the two primitive modules are dot-sourced INSIDE this branch and nowhere else. The quiet and
    # bounded-flash tiers never even load SetCursorPos/SendInput into the session.
    . (Join-Path $PSScriptRoot 'takeover.ps1')
    . (Join-Path $PSScriptRoot 'input-inject.ps1')
    . (Join-Path $PSScriptRoot 'hud.ps1')
    # A CANCELLATION THAT ARRIVES DURING SETUP MUST NOT BE THROWN AWAY. The host writes the latch as soon as
    # the signal fires, and setup (module load + HUD start) can take longer than that. Clearing the latch
    # unconditionally at this point would delete a cancellation that was meant for THIS call -- measured
    # with test/signal-test.mjs: the abort landed, the latch was written, and the action ran to completion.
    # So: snapshot, then clear (a stale latch from a crashed action must not poison every later call), then
    # honour what was found.
    $preAborted = Test-WpmTakeoverAbort
    Reset-WpmTakeoverAbort | Out-Null
    $armClamped = [Math]::Max(0, [Math]::Min(5000, $TakeoverArmMs))
    $maxClamped = [Math]::Max(500, [Math]::Min(60000, $TakeoverMaxMs))
    $hud = Start-WpmHud -Action $Action -MaxMs $maxClamped -ArmMs $armClamped
    $hudStarted = [bool]$hud.ready
    $facts.hudReady = $hudStarted
    if ($facts.keyInjectRequested -and $hudStarted -and -not $facts.elevatedTarget) {
      # S1: SendInput writes to the FOREGROUND window. One raise attempt through the same input-queue
      # unlock the focus restore uses, then re-measure -- a decision made now is evidence; a decision
      # made 800ms ago is not.
      $fg0 = Test-WpmTargetForeground -Hwnd $Hwnd
      if (-not $fg0.ok) {
        $raised = [WpmWin]::RestoreForeground([IntPtr]$h)
        if ($raised -like 'true*') { $raisedByUs = $true }
        Start-Sleep -Milliseconds 60
      }
      $fg1 = Test-WpmTargetForeground -Hwnd $Hwnd
      $facts.foregroundIsTarget = [bool]$fg1.ok
    }
  }
  $decision = Get-WpmChannelDecision $facts
  # G3, and not ceremony: the HUD runs on its own thread and can fail between Start-WpmHud and here. The
  # decision approved takeover on a fact measured a moment ago; re-measure before a primitive exists in
  # the call path. scripts/check-takeover-path.mjs asserts this check sits between the branch entry and
  # every call to Set-WpmCursorTakeover / Send-WpmKeyText.
  if ($facts.takeoverRequested -and $decision.tier -eq 'takeover' -and -not (Test-WpmHudReady)) {
    if ($hudStarted) { [void](Stop-WpmHud) }
    $result.refusal = 'takeover_unavailable'
    $result.reason = $script:WpmRefusals.takeover_unavailable + ' [the HUD stopped between start and arming]'
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
    return $result
  }
  if ($raisedByUs -and -not $decision.needsRestore) {
    # We moved the owner's foreground for the injection; the same table that reverses a UIA flash has to
    # reverse this too, or "we only borrow what we give back" would have a hole exactly where the
    # loudest primitive is.
    $decision.needsRestore = $true
  }

  $result.channel = $decision.channel; $result.tier = $decision.tier
  $result.family = $probe.family; $result.cls = $probe.cls
  if ($decision.channel -eq 'refuse') {
    if ($hudStarted) { [void](Stop-WpmHud) }
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

  # The focus table was captured above (before any raise). For the quiet tier it is still needed,
  # because 'the quiet channel did not take focus' is a claim that needs a before-value to be
  # falsifiable.
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
  # 0.6.0 locals. Declared here rather than inside the dispatch branches so that a channel which never
  # armed a readback (invoke/toggle/select, a refusal, an exception) is the ABSENCE of a plan and not a
  # leftover value from the previous call -- this worker is long-lived, and a stale plan would grade
  # today's action against yesterday's field.
  $focusBeforeDoor = $null
  $focusAfterDoor = $null
  $readbackPlan = $null

  # ---- the takeover choreography (spec.md §3) -------------------------------------------------
  # Everything from here to the finally exists because R3 promises three things the quiet tier never
  # did: the pointer move is VISIBLE (so the owner is warned before it costs them anything), the
  # pointer is ALWAYS returned, and the whole thing can be interrupted from three different places.
  $takeover = ($decision.tier -eq 'takeover')
  $cursorEntry = $null
  $abortedBeforeAct = $false
  $abortedByPause = $false
  $abortedDuringSetup = $false
  # $preAborted is NOT re-initialised here: it was snapshotted before Reset-WpmTakeoverAbort cleared the
  # flag, and re-zeroing it at this point silently discarded a cancellation that arrived during setup.
  # (Measured by test/signal-test.mjs -- the abort landed, the latch existed, and the action still ran.)
  $takeoverStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  if ($takeover) {
    $result.takeover = 'true'
    if ($preAborted) { $abortedBeforeAct = $true; $abortedDuringSetup = $true }
    $result.hudHwnd = [string][WpmCtl]::HudHwnd
    # ARMING is a real cancellation window, not a sleep: all three interruption paths are read every
    # 50ms, and the HUD clock is updated so a long arming still shows progress.
    $armMs = [Math]::Max(0, [Math]::Min(5000, $TakeoverArmMs))
    $armDeadline = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $armMs
    Set-WpmHudPhase -Phase 'arming' -Action $Action -MaxMs $TakeoverMaxMs -ElapsedMs 0 | Out-Null
    while ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $armDeadline) {
      # C12: the PAUSE switch is an interruption too, not a flag only read at decision time. The owner can
      # press it while the HUD is counting, and the promise is "stops now", not "stops next time".
      if (Test-WpmTakeoverAbort) { $abortedBeforeAct = $true; break }
      if ([WpmCtl]::Paused) { $abortedBeforeAct = $true; $abortedByPause = $true; break }
      Set-WpmHudPhase -Phase 'arming' -ElapsedMs ([int]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $takeoverStartMs)) | Out-Null
      Start-Sleep -Milliseconds 50
    }
    if (-not $abortedBeforeAct) { Set-WpmHudPhase -Phase 'active' | Out-Null }
  }

  try {
    # THE CURSOR MOVE LIVES INSIDE THE SAME try THAT OWNS THE RESTORE (spec.md §6 G4): an exception in
    # the door call below still reaches the finally that puts the pointer back.
    #
    # 0.6.0: the focus table is re-read HERE, at the moment of sending, not reused from the one captured
    # before the probe. See the focusMoved block after the settle window for why this is a warning and
    # never a refusal.
    $focusBeforeDoor = Get-WpmFocusEntry
    if ($takeover -and -not $abortedBeforeAct -and $Action -eq 'click' -and $X -ge 0 -and $Y -ge 0) {
      $cursorEntry = Set-WpmCursorTakeover -X $X -Y $Y
      $result.cursorMoved = if ($cursorEntry.applied) { 'true' } else { 'false' }
      $result.cursorX = [int]$cursorEntry.x
      $result.cursorY = [int]$cursorEntry.y
      $result.cursorBeforeX = [int]$cursorEntry.beforeX
      $result.cursorBeforeY = [int]$cursorEntry.beforeY
    }
    if ($abortedBeforeAct) {
      $result.refusal = 'takeover_aborted'
      $result.reason = if ($abortedByPause) { 'the owner paused the engine during the arming window; nothing was clicked or typed' } elseif ($abortedDuringSetup) { 'cancelled by the host before the arming window opened; nothing was clicked or typed' } else { 'interrupted during the arming window; nothing was clicked or typed' }
    } elseif ($decision.channel -eq 'message') {
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
        if ([WpmWin]::IsWindowEnabled($target) -eq $false) { $targetDisabled = $true }
        # THE PRE-READ. Taken BEFORE the write, because the expected post-write value is only computable
        # from the value the control held plus the insertion point the CONTROL reports (its own EM_GETSEL
        # answer) -- not from an assumption that a write appends. Measured: an unfocused WinForms TextBox
        # inserts at 0, so 'abc' + 'XYZ' is 'XYZabc'; the model has to know both numbers or the
        # comparison grades its own guess.
        $preRead = Read-WpmControlText -Hwnd $target
        $w = [WpmWin]::MessageTextAt($target, $Text, [bool]$Replace, $CaretPosition)
        $mode = [string]$w[0]
        $sentChars = [int]$w[1]
        $selStart = [int]$w[2]; $selEnd = [int]$w[3]
        $caretAskedAt = if ($w.Count -gt 4) { [int]$w[4] } else { -1 }
        # Readback runs AFTER the settle window (the proof sampling is the settle), so an app that commits
        # its value asynchronously is not judged against a half-written buffer (plan R2).
        $readbackPlan = @{
          kind = 'message'; hwnd = $target; mode = $mode
          pre = $preRead; selStart = $selStart; selEnd = $selEnd; text = $Text; replace = [bool]$Replace
        }
        $caretNote = "caret=$CaretPosition asked=$(if ($caretAskedAt -ge 0) { $caretAskedAt } else { '(untouched)' }) applied=$selStart,$selEnd"
        $result.detail = "msg=$mode|$sentChars child=$($target.ToInt64()) $caretNote" + $(if (-not $preRead.exposesText) { ' readbackPre=unavailable' } else { '' })
        $result.effect = 'reported-by-send'
      } elseif ($Action -eq 'click') {
        if ($X -lt 0 -or $Y -lt 0) {
          $result.refusal = 'unreachable'; $result.reason = 'click needs screen coordinates'
          $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
          return $result
        }
        $child = Resolve-WpmChildAtPoint $h $X $Y
        if ($child -eq [IntPtr]::Zero) {
          $result.refusal = 'unreachable'
          $result.reason = $(if ($script:WpmPointCovered) {
            "the point is inside a child of the target but another window is on top (blocker class=$($script:WpmPointBlocker)); a message press there is accepted and ignored -- the application never runs the handler. Next step: bring the target to the front, or choose a point that is visible"
          } else { 'no child window of the target sits under that point' })
          $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
          return $result
        }
        $r = [WpmWin]::MessageClick($child, $X, $Y)
        $result.detail = "msg=$r child=$($child.ToInt64())"
        $result.effect = 'reported-by-send'
      }
    } elseif ($decision.channel -eq 'input') {
      # THE MEASURED DOORLESS CASE (a terminal, findings §B): typing into the FOREGROUND window. The
      # foreground assertion is repeated here, at the moment of sending, because the desktop can change
      # during the arming window -- the decision's fact is evidence about then, not about now.
      $fgNow = Test-WpmTargetForeground -Hwnd $Hwnd
      if (-not $fgNow.ok) {
        $result.refusal = 'keyinject_unavailable'
        $result.reason = $script:WpmRefusals.keyinject_unavailable + ' [foreground at send time: ' + $fgNow.foreground + ']'
      } else {
        # The pause switch rides the same abort probe: a long injection must stop when the owner says so.
        $inj = Send-WpmKeyText -Text $Text -ShouldAbort { (Test-WpmTakeoverAbort) -or [WpmCtl]::Paused }
        $result.detail = 'inject=unicode chars=' + $inj.chars + ' events=' + $inj.sent
        $result.keysInjected = [int]$inj.sent
        $result.injectedChars = [int]$inj.chars
        $result.effect = if ($inj.chars -gt 0) { 'reported-by-send' } else { 'unverified' }
        if ($inj.aborted) {
          $result.refusal = 'takeover_aborted'
          $result.reason = $inj.reason
        } elseif (-not $inj.ok) {
          $result.refusal = 'keyinject_unavailable'
          $result.reason = $inj.reason
        }
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
        # THE PRE-READ THROUGH THE SAME PATTERN that writes. The UIA `value` channel is a whole-value
        # replace, so the expected after-value is computable exactly -- and the current value is read
        # from the pattern, not from a window message, because this is the channel the write went through.
        $preVal = ''
        $preOk = $false
        try { $preVal = [string]$pat.Current.Value; $preOk = $true } catch { $preOk = $false }
        $pat.SetValue($(if ($Replace) { $Text } else { [string]$pat.Current.Value + $Text }))
        $readbackPlan = @{
          kind = 'uia-value'; pat = $pat; mode = 'value'
          expected = $(if ($Replace) { $Text } else { $preVal + $Text })
          preOk = $preOk; pre = $preVal; text = $Text; replace = [bool]$Replace
        }
      } elseif ($kind -eq 'toggle') {
        $pat = $el.GetCurrentPattern($pats.toggle); $pat.Toggle()
      } elseif ($kind -eq 'select') {
        $pat = $el.GetCurrentPattern($pats.select); $pat.Select()
      } elseif ($kind -eq 'legacy') {
        $pat = $el.GetCurrentPattern($pats.legacy)
        $preVal = ''; $preOk = $false
        try { $preVal = [string]$pat.Current.Value; $preOk = $true } catch { $preOk = $false }
        $pat.SetValue($Text)
        $readbackPlan = @{
          kind = 'uia-legacy'; pat = $pat; mode = 'legacy'
          expected = $Text; preOk = $preOk; pre = $preVal; text = $Text; replace = $true
        }
      }
      $result.detail = "uia=$kind"
      # A caret request on this channel has no meaning -- `value` replaces the whole string, there is no
      # insertion point to move. Saying so is the difference between honouring a parameter and quietly
      # dropping it (the same discipline as `frame` and, in 0.6.0-B, `captureBackend`: a path that did
      # not do what you asked says so in the result).
      if ($CaretPosition -ne 'idle' -and $readbackPlan) {
        $result.detail += " caretIgnored=$kind-pattern"
      }
      $result.effect = 'reported-by-pattern'
    }
    $focusAfterDoor = Get-WpmFocusEntry
  } catch {
    $result.refusal = 'action_failed'
    $result.reason = 'the channel call threw: ' + $_.Exception.Message
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
  } finally {
    # THE BORROWED POINTER IS RETURNED HERE, UNCONDITIONALLY. Success, exception, refusal and
    # interruption all arrive at this block, which is the whole reason the move was placed inside the
    # try above. 'restored' is the READ-BACK, not the intent: a restore the OS refused reports
    # cursorRestored=false and becomes a hard proof failure downstream (spec.md §6, C5).
    if ($takeover) {
      if ($cursorEntry) {
        $cur = Restore-WpmCursorTakeover -Entry $cursorEntry
        $result.cursorRestored = if ($cur.restored) { 'true' } else { 'false' }
        $result.cursorAfterX = [int]$cur.x
        $result.cursorAfterY = [int]$cur.y
        if (-not $cur.restored) { $result.cursorRestoreReason = $cur.reason }
      } else {
        # No click point, so nothing was borrowed: the honest report is restored=true with moved=false.
        $result.cursorRestored = 'true'
      }
      $result.injectedChars = [int][WpmCtl]::InjectedChars
      $result.abortChord = [string][WpmCtl]::AbortChordLabel
      $result.takeoverMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $takeoverStartMs
      if ($TakeoverMaxMs -gt 0 -and $result.takeoverMs -gt $TakeoverMaxMs) {
        $result.takeoverNote = 'the action exceeded takeoverMaxMs=' + $TakeoverMaxMs + '; it was still restored'
      }
      # A LATCH LEFT BEHIND WOULD ABORT THE NEXT CALL. The host clears its own copy on dispose, but the
      # worker pid outlives a single action, so the engine clears it here as well -- after the restore, so
      # an interruption that arrives during cleanup is still visible to this action's own accounting.
      Reset-WpmTakeoverAbort | Out-Null
      Set-WpmHudPhase -Phase 'done' -ElapsedMs ([int]$result.takeoverMs) | Out-Null
      $dwell = if ($result.refusal) { 120 } else { [Math]::Max(0, [Math]::Min(5000, $HudDoneMs)) }
      if ($dwell -gt 0) { Start-Sleep -Milliseconds $dwell }
      [void](Stop-WpmHud)
    }
  }

  # THE ACTION WINDOW. Sampled DURING the settle sleep the engine already performed, so collecting
  # proof costs no extra delay. This is the window the claim is made about; it is judged against the
  # pre-action control captured above (proof-window decides how, from both). Attribution is arithmetic
  # and lives in lib/proof-window.mjs -- the engine only produces samples.
  $result.proofControl = $controlSamples
  $result.proofSamples = Get-WpmProofWindow -Ms $SettleMs

  # ---- 0.6.0 READBACK: the fourth `effect`, earned by reading the value back -------------------
  # This runs AFTER the settle window on purpose (plan R2): an application that commits its text
  # asynchronously must not be judged against a half-written buffer. The rule is narrow and it is the
  # whole feature -- `readback-verified` is used ONLY when the value read back equals the value the
  # model predicted from measurements the CONTROL reported. Anything else keeps the effect the write
  # itself earned, and the reason travels in `detail`.
  #
  # A mismatch is NOT a failure. The app may legitimately reformat what it was given (case folding,
  # trimming, a mask, a numeric parse), and `unreachable`/`action_failed` must not be repurposed to
  # mean "the value is not what I expected" -- so the refusal set is unchanged by this block, by design.
  if ($readbackPlan) {
    $expected = $null
    $expectedHow = ''
    if ($readbackPlan.kind -eq 'message') {
      $post = Read-WpmControlText -Hwnd $readbackPlan.hwnd
      $pre = $readbackPlan.pre
      if ($readbackPlan.mode -eq 'settext') {
        $expected = [string]$readbackPlan.text; $expectedHow = 'settext-equals-text'
      } elseif (-not $pre.exposesText -or $pre.truncated) {
        $expected = $null; $expectedHow = $(if (-not $pre.exposesText) { 'pre-read-unavailable' } else { 'pre-read-truncated' })
      } else {
        $b = [string]$pre.text
        $s = [int]$readbackPlan.selStart; $e = [int]$readbackPlan.selEnd
        if ($s -lt 0) { $s = 0 }
        if ($e -lt $s) { $e = $s }
        if ($s -gt $b.Length) { $s = $b.Length }
        if ($e -gt $b.Length) { $e = $b.Length }
        $expected = $b.Substring(0, $s) + [string]$readbackPlan.text + $b.Substring($e)
        $expectedHow = "insert-at-$s-$e"
      }
      $postRef = $post
    } else {
      $postVal = ''; $postOk = $false
      try { $postVal = [string]$readbackPlan.pat.Current.Value; $postOk = $true } catch { $postOk = $false }
      $expected = [string]$readbackPlan.expected; $expectedHow = 'pattern-current-value'
      $postRef = @{ ok = $postOk; exposesText = $postOk; truncated = $false; text = $postVal; chars = $postVal.Length }
    }

    if (-not $postRef.exposesText) {
      # Not "empty": the read produced nothing usable. Reporting readback=unavailable keeps the two
      # apart, which is the difference between "this field hides its text" and "this field is empty".
      $result.detail += ' readback=unavailable'
    } elseif ($null -eq $expected) {
      $result.detail += " readback=unmodelled($expectedHow)"
    } else {
      $shown = [string]$postRef.text
      if ($shown.Length -gt 120) { $shown = $shown.Substring(0, 119) + [char]0x2026 }
      $result.detail += " readback=$shown readbackLen=$([string]$postRef.text.Length)"
      if ($postRef.text -eq $expected) {
        $result.effect = 'readback-verified'
      } else {
        # The mismatch is carried as data because a caller that only reads `effect` must still be able
        # to tell "nothing reported success" from "it reported success and the value says otherwise".
        $result.detail += ' readbackMismatch=true'
      }
    }
  }

  # ---- 0.6.0 focus re-check at the moment of sending ------------------------------------------
  # A WARNING, never a refusal. The desktop can move between the probe and the send, and on the
  # bounded-flash tier the move is the channel working as documented. Refusing on a mismatch would
  # kill correct writes to be safe about a fact the readback already judges better -- so the field
  # says what was measured and lets the caller weigh it.
  if ($focusBeforeDoor -and $focusAfterDoor) {
    $moved = ($focusBeforeDoor.fgHwnd -ne $focusAfterDoor.fgHwnd) -or
             ($focusBeforeDoor.focusHwnd -ne $focusAfterDoor.focusHwnd)
    $result.detail += " focusMoved=$($moved.ToString().ToLower())"
  }

  # ---- 0.6.0 the disabled target, recorded last so it cannot be overridden ---------------------
  # `effect` is pinned to 'unverified' here even if a readback matched: a write into a greyed-out
  # window is not an effect the owner can rely on, and the one claim this field makes is that the
  # channel's own report is not being dressed up as a verified state change.
  if ($targetDisabled) {
    $result.detail += ' disabled=true'
    $result.effect = 'unverified'
  }

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

# ==================================================================================================
# 0.7.0: the three desktop actions that are NOT door actions.
# ==================================================================================================

function Invoke-WpmDesktopAction {
  <#
    launch / clipboard / window live beside Invoke-WpmAction, not inside it, and that separation is the
    point: a door action chooses a channel, costs a tier, takes and returns a focus, and is judged by a
    proof window. A window move or a clipboard write does none of those things, and routing them through
    the door table would either force them into a refusal code they do not deserve or make the table
    answer for capabilities it never measured.

    WHAT THEY STILL DO: every one of them is verified by reading the STATE back -- `IsIconic`, the rect,
    the ex-style, the clipboard's own content -- because the rule this product has been bitten by is that
    a syscall's return value describes the CALL. So `effect` uses the same four values and the same rule:
    `readback-verified` only when the read agrees, `unverified` otherwise, and the disagreement or the
    reason travels in `detail`. No refusal code was added for this batch either: `launch` with the gate
    off, a window with no hwnd, and a clipboard holding an unexpected format are all answered by the host
    gate or by the existing `no_hwnd` / `action_failed` vocabulary.
  #>
  param(
    [Parameter(Mandatory)][ValidateSet('launch', 'clipboard', 'window')][string]$Action,
    [string]$Hwnd = '',
    [string]$Target = '',
    [object]$Arguments = $null,
    [int]$WaitMs = 3000,
    [string]$Op = '',
    [string]$Format = 'text',
    [string]$Text = '',
    [string]$ShotId = '',
    [int]$X = 0,
    [int]$Y = 0,
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$MaxChars = 65536,
    # ---- 0.7.0 authorization. The host gate runs first and costs zero worker requests; these are the
    # engine's own second line, checked against the same table in decide.ps1 so the two processes cannot
    # disagree about what the owner permitted.
    [string]$Policy = 'balanced',
    [int]$PolicyIdleMs = 3000,
    [switch]$ForceUserActive,
    [bool]$AppLaunchAllowed = $false,
    [string[]]$AppLaunchAllow = @()
  )
  $started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $result = @{ ok = $false; action = $Action; hwnd = $Hwnd; refusal = ''; reason = ''; detail = ''
    effect = 'unverified'; latencyMs = 0 }

  if ($Action -eq 'launch') {
    # The engine re-runs the gate and the whitelist through the SAME table the host used. A permission
    # that lives in only one of the two processes is a permission that can be reached around by calling
    # the other, and `launch` is the one action where that distinction has consequences.
    $launchFacts = New-WpmFacts -Hwnd '' -Action launch -FactsMeasured $true `
      -Policy $Policy -RequiredTier 'takeover' -PolicyIdleMs $PolicyIdleMs `
      -ForceUserActive:([bool]$ForceUserActive) -LastInputAgeMs ([WpmWin]::LastInputAgeMs()) `
      -AppLaunchAllowed:$AppLaunchAllowed -AppLaunchAllow $AppLaunchAllow -LaunchTarget $Target
    $ld = Get-WpmChannelDecision $launchFacts
    if ($ld.channel -eq 'refuse') {
      $result.refusal = [string]$ld.refusal; $result.reason = [string]$ld.reason
      $result.detail = "launch gate: allowed=$AppLaunchAllowed whitelist=$(@($AppLaunchAllow).Count) name(s)"
      $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
      return $result
    }
    $argv = @()
    if ($Arguments -is [array]) { $argv = @($Arguments | ForEach-Object { [string]$_ }) }
    elseif ($Arguments -is [string] -and $Arguments) { $argv = @($Arguments) }
    $s = Start-WpmApp -Target $Target -Arguments $argv
    if (-not $s.ok) {
      $result.refusal = 'action_failed'; $result.reason = [string]$s.reason
      $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
      return $result
    }
    $result.pid = [int]$s.pid
    $result.processName = [string]$s.name
    $result.target = [string]$s.target
    # The window is waited for only when the caller asked to address one. hwnd=0 after a successful
    # launch is a REPORTED state ('window-not-yet'), never a failure -- see Wait-WpmAppWindow.
    if ($WaitMs -gt 0) {
      $w = Wait-WpmAppWindow -ProcessId ([int]$s.pid) -WaitMs $WaitMs
      $result.hwnd = [string]$w.hwnd
      $result.waitedMs = [int]$w.waitedMs
      if ($w.hwnd) {
        $result.ok = $true
        $result.effect = 'readback-verified'
        $result.detail = "launched pid=$($s.pid) hwnd=$($w.hwnd) title=$($w.title)"
      } elseif ($w.ContainsKey('detail')) {
        # ContainsKey on purpose: Wait-WpmAppWindow answers THREE different shapes -- window found, no
        # window yet (carries detail=window-not-yet and a note), and the process is gone (carries a
        # reason and no detail at all). Reading a key that a branch never set is a StrictMode throw, and a
        # throw inside the handler for a started-but-windowless process would report `action_failed` on
        # a program that is running fine -- the exact overstatement this engine exists to avoid.
        $result.ok = $true
        $result.detail = "launched pid=$($s.pid) " + [string]$w.detail + " waitedMs=$($w.waitedMs)"
        if ($w.ContainsKey('note')) { $result.note = [string]$w.note }
      } else {
        $result.refusal = 'action_failed'
        $result.reason = [string]$w.reason
        $result.detail = "launched pid=$($s.pid) but no window could be observed"
      }
    } else {
      $result.ok = $true
      $result.detail = "launched pid=$($s.pid) window=not-asked (waitMs=0)"
    }
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
    return $result
  }

  if ($Action -eq 'clipboard') {
    if ($Op -eq 'read') {
      $c = Get-WpmClipboard -Format $Format -MaxChars $MaxChars
      if (-not $c.ok) {
        $result.refusal = 'action_failed'; $result.reason = [string]$c.reason
        # ContainsKey before reading: these failure paths return DIFFERENT key sets by design (a format
        # miss carries the names it found, an exception does not), and under Set-StrictMode 2.0 reading a
        # key that is simply absent throws -- turning a documented refusal into a crash inside the
        # refusal handler, which is the failure mode the first run of this branch produced.
        if ($c.ContainsKey('formats') -and $c.formats) { $result.detail = 'formats=' + ($c.formats -join ',') }
        $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
        return $result
      }
      $result.ok = $true
      $result.clipFormat = [string]$c.format
      if ($c.format -eq 'text') {
        # The CONTENT is deliberately not put into `detail`: the result text is written into a model's
        # context and an audit line, and the clipboard is exactly the place where that can carry a token
        # (R8). Length and the truncation flag are enough to decide what to do next.
        $result.chars = [int]$c.chars
        $result.truncated = [bool]$c.truncated
        $result.effect = 'readback-verified'
        $result.detail = "clipboard=read format=text chars=$($c.chars)" + $(if ($c.truncated) { " truncated=$($MaxChars)" } else { '' })
      } else {
        $result.file = [string]$c.file
        $result.clipId = [string]$c.clipId
        $result.imageSize = "$($c.width)x$($c.height)"
        $result.effect = 'readback-verified'
        $result.detail = "clipboard=read format=image file=$($c.file) size=$($c.width)x$($c.height)"
      }
    } elseif ($Op -eq 'write') {
      $c = Set-WpmClipboard -Format $Format -Text $Text -ShotId $ShotId
      if (-not $c.ok) {
        $result.refusal = $(if ($c.ContainsKey('stale') -and $c.stale) { 'stale_ref' } else { 'action_failed' })
        $result.reason = [string]$c.reason
        $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
        return $result
      }
      $result.ok = $true
      $result.clipFormat = [string]$c.format
      if ($c.format -eq 'text') {
        $result.chars = [int]$c.chars
        # The read-back is a LENGTH comparison, and the value itself is not echoed: same reason as above.
        $result.readbackChars = [int]$c.readbackChars
        $result.effect = $(if ($c.readbackMatches) { 'readback-verified' } else { 'unverified' })
        $result.detail = "clipboard=write format=text chars=$($c.chars) readbackChars=$($c.readbackChars)" +
          $(if ($c.readbackMatches) { '' } else { ' readbackMismatch=true' })
      } else {
        $result.readbackSize = "$($c.readbackWidth)x$($c.readbackHeight)"
        # The image read-back is a SIZE comparison against the shot that was pushed in: the pixels
        # themselves cannot be hashed (two reads of a live screen differ, findings 5.1) and the shot's own
        # dimensions are the fact the caller can act on.
        $dimsMatch = ($c.readbackWidth -eq $c.width) -and ($c.readbackHeight -eq $c.height)
        $result.effect = $(if ($dimsMatch) { 'readback-verified' } else { 'unverified' })
        $result.detail = "clipboard=write format=image shotId=$($c.shotId) asked=$($c.width)x$($c.height) readback=$($c.readbackWidth)x$($c.readbackHeight)" +
          $(if ($dimsMatch) { '' } else { ' readbackMismatch=true' })
      }
    } else {
      $result.refusal = 'action_failed'; $result.reason = "clipboard needs op='read' or op='write'"
      $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
      return $result
    }
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
    return $result
  }

  # ---- window ------------------------------------------------------------------
  if (-not $Hwnd) {
    $result.refusal = 'no_hwnd'; $result.reason = 'window acts on one named window; there is no "all windows" op'
    $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
    return $result
  }
  $fgBeforeOp = [WpmWin]::Fg()
  $w = Invoke-WpmWindowOp -Hwnd ([IntPtr][int64]$Hwnd) -Op $Op -X $X -Y $Y -Width $Width -Height $Height
  $fgAfterOp = [WpmWin]::Fg()
  # Only the 'hwnd is not a live window' branch carries a refusal code; the others answer ok/false with a
  # reason. Under StrictMode an unguarded read of a key that branch never sets would throw inside the
  # handler, so presence is tested rather than assumed.
  if ($w.ContainsKey('refusal') -and $w.refusal) { $result.refusal = [string]$w.refusal }
  $result.ok = [bool]$w.ok
  $result.reason = [string]$w.reason
  $bits = @("window=$Op")
  foreach ($k in @('iconic', 'called', 'asked', 'size', 'rect', 'before', 'topmost', 'exStyle', 'activated')) {
    if ($w.ContainsKey($k)) {
      # Lower-cased deliberately: every other boolean this engine puts into `detail` reads
      # disabled=true / focusMoved=false / verified=true, and a PowerShell `True` in the same sentence is
      # how a field ends up being parsed two ways by two consumers.
      $val = $w[$k]
      if ($val -is [bool]) { $val = $val.ToString().ToLower() }
      $bits += "$k=$val"
    }
  }
  $bits += $(if ($w.ok) { 'verified=true' } else { 'verified=false' })
  # DID THE OWNER LOSE THE FOREGROUND TO THIS CALL -- measured on both sides of it, because
  # `restore` activates by definition and a window op that quietly took the focus while reporting only a
  # size change is the failure shape this product keeps meeting. Saying it is not the same as refusing
  # it: the caller asked for the window to come back, and coming back is what restoring means.
  $fgTaken = ($fgBeforeOp -ne $fgAfterOp) -and ($fgAfterOp -eq $Hwnd)
  $bits += "foregroundTaken=$($fgTaken.ToString().ToLower())"
  if ($fgTaken) {
    $bits += "foregroundBefore=$fgBeforeOp foregroundAfter=$fgAfterOp"
  }
  $result.detail = ($bits -join ' ')
  $result.foregroundTaken = $fgTaken
  # The window's own answer is the read-back, so the effect follows it directly.
  $result.effect = $(if ($w.ok) { 'readback-verified' } else { 'unverified' })
  $result.latencyMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $started
  return $result
}
