# calc-display-oracle.ps1 — does UIA Invoke reach the desktop's largest family?
#
# WHY THIS EXISTS. The toolkit census put uap-framed at 27 of 46 visible windows: the
# XAML/UWP family is not an edge case on this machine, it IS the machine. The neutrality
# run recorded winui-calc uia-invoke as ok 1/8, verified by diffing the CLICKED BUTTON's own
# Name. Pressing the digit '7' does not rename the '7' button -- the thing that changes is
# the result display. So seven of those rounds were 'no-effect' because the effect was
# looked for on the wrong object, not because the click missed. That is the same failure
# shape as the Chromium omnibox measurement: an instrument that verifies the action by
# asking the actor instead of asking the world.
#
# Here the oracle is the app's own state readout (ControlType.Text named 'Display is N'),
# which no invoke call can fake: it changes only if the button actually fired.
#
# SAFETY: Calculator's state is a number. Nothing here can destroy user data, every
# button pressed is a digit or an operator, and the destructive-name filter from the
# neutrality experiment is applied again. The window is put in the BACKGROUND first, so a
# foreground change would be attributable to the click rather than to it already being on
# top.
param(
  [int]$Rounds = 6,
  [string]$TitlePart = 'Calculator',
  [switch]$LaunchIfMissing
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CA {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct GTI {
    public int cbSize; public int flags; public IntPtr hwndActive; public IntPtr hwndFocus;
    public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret;
    public RC rc;
  }
  [StructLayout(LayoutKind.Sequential)] public struct RC { public int l, t, r, b; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint id, ref GTI g);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  public static string Cursor() { POINT p; GetCursorPos(out p); return p.x + "," + p.y; }
  public static string Fg() { return GetForegroundWindow().ToInt64().ToString(); }
  public static string Focus() {
    IntPtr fg = GetForegroundWindow();
    uint tid = GetWindowThreadProcessId(fg, IntPtr.Zero);
    GTI g = new GTI(); g.cbSize = Marshal.SizeOf(typeof(GTI));
    if (!GetGUIThreadInfo(tid, ref g)) return fg.ToInt64() + "/ERR";
    return fg.ToInt64() + "/" + g.hwndFocus.ToInt64();
  }
}
'@

function Find-Win([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

$w = Find-Win $TitlePart
if (-not $w -and $LaunchIfMissing) { Start-Process 'calculator:' | Out-Null }
if (-not $w) {
  $d = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $d -and -not $w) { Start-Sleep -Milliseconds 500; $w = Find-Win $TitlePart }
}
if (-not $w) { throw 'no Calculator window found' }
$hwnd = [IntPtr]$w.hwnd
"target: hwnd=$hwnd class='$($w.cls)' pid=$($w.procId)"

function Get-CalNodes([IntPtr]$h, [int]$ms) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) {
    try {
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
      $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      $n = [Math]::Min($all.Count, 600)
      $display = ''; $digits = @(); $buttons = 0; $clears = @()
      for ($i = 0; $i -lt $n; $i++) {
        $ct = ''
        try { $ct = ($all[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
        $nm = ''
        try { $nm = [string]$all[$i].Current.Name } catch { }
        # AutomationId, not Name, is the identity used here -- and that is not a style
        # choice. The first draft matched digit buttons by Name against /^\d$/ and found
        # NONE, because Calculator names them 'One' / '七' depending on UI language, so the
        # run exited with "no digit buttons" and would have declared the desktop's largest
        # family unreachable on the strength of a string comparison. Names are localized;
        # num0Button..num9Button and CalculatorResults are not.
        $au = ''
        try { $au = [string]$all[$i].Current.AutomationId } catch { }
        if ($au -eq 'CalculatorResults') { $display = $nm }
        if ($ct -eq 'Button') {
          $buttons++
          # Window chrome is excluded, and the reason is not cosmetic: on an
          # ApplicationFrame window the FIRST Invoke elements in tree order are the caption
          # buttons, so an unscoped pick clicks minimize and each round then minimizes its
          # own target -- which an earlier run mistook for an empty UIA tree.
          # With AutomationId in hand, chrome is excluded by ID rather than by name.
          if ($au -match '(?i)TitleBar|Caption|Navigation|BackButton|Minimize|Maximize|Restore|CloseButton|WindowCommand') { continue }
          if ($au -match '^num([0-9])Button$') {
            $digits += @{ name = $Matches[1]; autoId = $au; el = $all[$i]; label = $nm }
          }
          # The clear key, so the run can START from a known state rather than inherit a
          # number left by the previous experiment.
          # Only the all-clear key. clearEntryButton wipes just the current entry, which
          # would leave a long accumulated number in place and make the reset a no-op that
          # still LOOKS executed -- the exact shape of a silent instrument failure.
          if ($au -eq 'clearButton') { $clears += @{ autoId = $au; el = $all[$i]; label = $nm } }
        }
      }
      if ($display -and $digits.Count -ge 2) {
        return @{ display = $display; digits = $digits; clears = $clears; buttons = $buttons; ms = $sw.ElapsedMilliseconds }
      }
    } catch { }
    Start-Sleep -Milliseconds 400
  }
  return $null
}

$cn = Get-CalNodes $hwnd 25000
if (-not $cn) {
  'VERDICT: INSTRUMENT INVALID -- no readable Display element (and <2 digit buttons) within 25s. ' +
  'Nothing may be concluded about this family from a run that cannot observe its own effect.'
  exit 2
}
"resolved after $($cn.ms)ms: display='$($cn.display)' digitButtons=$($cn.digits.Count) allButtons=$($cn.buttons)"

# Reset the display to a known state before measuring, so a digit press can actually change
# it. Calculator caps at 16 digits, and a previous run left it full: pressing a digit on a
# full display is a NO-OP the app itself refuses, so those rounds would count as channel
# failures when they are neither success nor failure. 'C' (clearButton) zeroes it. If clear
# cannot be resolved or does not take effect, the run says so instead of quietly measuring
# against an unusable precondition.
if ($cn.clears.Count) {
  $cp = $null
  try { $cn.clears[0].el.TryGetCurrentPattern([System.Windows.Automation.InvokePatternIdentifiers]::Pattern, [ref]$cp) | Out-Null } catch { }
  if ($cp) {
    try { $cp.Invoke() } catch { "clear press threw: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 600
    $check = Get-CalNodes $hwnd 4000
    if ($check) {
      $cn = $check
      "after clear: display='$($cn.display)' (clearButton=$($cn.clears.Count) available)"
    }
  } else { "no InvokePattern on clearButton; display stays as found: '$($cn.display)'" }
} else {
  "clearButton not resolved; display stays as found: '$($cn.display)' -- rounds where the display is full will be skipped as unverifiable"
}

# Hand the foreground to a window we own, then measure with Calculator in the background.
$grabExit = Join-Path $env:TEMP ('wpm-calc-' + [guid]::NewGuid().ToString('N') + '.stop')
$grabReGrab = Join-Path $env:TEMP ('wpm-calc-regrab-' + [guid]::NewGuid().ToString('N'))
$grabProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '90000', '-ExitFile', "`"$grabExit`"",
  '-GrabFgAfterMs', '1200', '-ReGrabFile', "`"$grabReGrab`"" -PassThru
$g = $null
for ($i = 0; $i -lt 50 -and -not $g; $i++) { Start-Sleep -Milliseconds 400; $g = Find-Win 'WpmWinFormsTarget' }
if (-not $g) { throw 'hand-off window never appeared' }
$grabH = [IntPtr]$g.hwnd
$ok = $false
for ($i = 0; $i -lt 30 -and -not $ok; $i++) { $ok = ([CA]::Fg() -eq $grabH.ToString()); if (-not $ok) { Start-Sleep -Milliseconds 400 } }
if (-not $ok) { throw 'hand-off never took the foreground; a neutral result would be unmeasurable' }
"hand-off ok: foreground=$grabH, Calculator in BACKGROUND (iconic=$([CA]::IsIconic($hwnd)))"

# The sampler runs across the measured window only. A raw foreground-move count is not
# evidence of anything: this desktop is busy, so a move inside a round may well be the
# human's own click. Attribution is per 20Hz sample gap, and a change on a physically quiet
# gap is the only kind R2 forbids. See sampler-hooks.ps1 for why the shared helpers are
# shared rather than re-typed per driver.
. (Join-Path $PSScriptRoot 'sampler-hooks.ps1')
$samp = Start-WpmSampler -Hz 20 -Tag 'calc'
if (-not $samp.ok) {
  "!! sampler failed to record (bootBytes=$($samp.bootBytes)); foreground counts below will be UNATTRIBUTED and the verdict will refuse to call them clean"
} else {
  "sampler: out=$($samp.out) bootBytes=$($samp.bootBytes)"
}

$rows = @()
$precondFail = 0
$precondReclaims = 0
for ($r = 1; $r -le $Rounds; $r++) {
  # ASSERT THE PRECONDITION EVERY ROUND, not once before the loop. The first attributed run
  # hand-off-verified before round 1, then round 1's own invoke took the foreground to the
  # Calculator and never gave it back -- so rounds 2-8 measured "act on a FOREGROUND app"
  # while the header claimed background. A precondition checked once is a screenshot of a
  # condition, not a guarantee of one, and the difference shows up as numbers that look
  # comparable across rounds but are not.
  $guard = ''
  if (([CA]::Fg()) -ne $grabH.ToString()) {
    # Ask the hand-off window's OWN process to reclaim the foreground, then re-check. The
    # flag stays in place while we wait -- the form re-tries every tick until it works, and
    # WE remove it. Removing after a single attempt (as the first version did) turned this
    # into a race that lost requests.
    try { Set-Content -LiteralPath $grabReGrab -Value 'x' -Force } catch { }
    $recovered = $false
    for ($i = 0; $i -lt 20 -and -not $recovered; $i++) {
      if (([CA]::Fg()) -eq $grabH.ToString()) { $recovered = $true } else { Start-Sleep -Milliseconds 300 }
    }
    try { Remove-Item -LiteralPath $grabReGrab -Force -ErrorAction SilentlyContinue } catch { }
    if ($recovered) { $precondReclaims++; $guard = ' (reclaimed)' } else {
      $precondFail++
      $rows += [pscustomobject]@{ round = $r; kind = 'invoke'; pressed = ''; autoId = ''
        d0 = 'precondition-failed'; d1 = 'precondition-failed'; expected = ''
        effect = $null; changedDisplay = $false
        fg0 = [CA]::Focus(); fg1 = [CA]::Focus(); changed = $false
        cursor0 = [CA]::Cursor(); cursor1 = [CA]::Cursor(); error = 'no background precondition' }
      continue
    }
  }
  $cur = Get-CalNodes $hwnd 6000
  if (-not $cur) {
    $rows += [pscustomobject]@{ round = $r; kind = 'invoke'; pressed = ''; d0 = 'unresolved'; d1 = 'unresolved'
        expected = ''; effect = $null; fg0 = [CA]::Focus(); fg1 = [CA]::Focus(); changed = $false
        cursor0 = [CA]::Cursor(); cursor1 = [CA]::Cursor(); error = 'tree not resolvable this round' }
    continue
  }
  # The expected display text is predicted with Calculator's OWN arithmetic, not string
  # concatenation: from 0, pressing 7 shows '7' (not '07'); from 7, pressing 8 shows '78'.
  # Concatenating would expect 'Display is 07' on round 1 and call a working click a failure
  # -- the mirror image of the mistake this whole script exists to correct.
  $pick = $cur.digits[$r % $cur.digits.Count]
  # The trailing number is what changes; everything before it is a LOCALIZED prefix
  # ('Display is ' / '显示为 ') that must be preserved rather than assumed English. A
  # prefix-keyed regex is how a Chinese Calculator would silently report 'unparsable'.
  $m = [regex]::Match([string]$cur.display, '^(.*?)([0-9][0-9,.]*)$')
  if (-not $m.Success) {
    $rows += [pscustomobject]@{ round = $r; kind = 'invoke'; pressed = ''
      d0 = $cur.display; d1 = 'unparsable'; expected = ''
      effect = $null; fg0 = [CA]::Focus(); fg1 = [CA]::Focus(); changed = $false
      cursor0 = [CA]::Cursor(); cursor1 = [CA]::Cursor()
      error = 'display text not parsable into a number' }
    Start-Sleep -Milliseconds 400
    continue
  }
  $prev = $m.Groups[2].Value.Trim()
  $prefix = $m.Groups[1].Value
  # The predictable form is the DIGITS of the display, separators included: '1,234' with a
  # '5' pressed becomes '12,345' -- which digit-wise is '12345', exactly '1234'+'5'.
  # Requiring a separator-free digit run here would skip every round from 1000 upward, and
  # since appending digits reaches 4 digits by round 4, that guard would silently reduce the
  # sample to the first three rounds while still printing a rate. The effect test below
  # already compares digits-only, so the two must agree on what is predictable.
  $prevDigits = ($prev -replace '[^0-9]', '')
  # Calculator only holds 16 significant digits. Past that, a digit press is IGNORED -- the
  # display stays put. Rounds 5-8 of the first fully attributed run were exactly this: four
  # 'failures' caused by an app input limit, not by the channel, all after the state had
  # accumulated past 16 digits from previous runs. A round whose app cannot possibly reflect
  # the press is unverifiable and must be skipped, never charged to the channel -- that is
  # the difference between understating coverage and lying about it.
  if ($prevDigits.Length -ge 16) {
    $rows += [pscustomobject]@{ round = $r; kind = 'invoke'; pressed = ''
      d0 = $cur.display; d1 = 'skipped-full'; expected = ''
      effect = $null; fg0 = [CA]::Focus(); fg1 = [CA]::Focus(); changed = $false
      cursor0 = [CA]::Cursor(); cursor1 = [CA]::Cursor()
      error = "display already holds $($prevDigits.Length) digits (Calculator caps at 16): a press cannot change it" }
    Start-Sleep -Milliseconds 400
    continue
  }
  # Skipped only when the digits themselves are unusable: an error string ('Display is
  # Invalid input'), a fraction ('1.5'), or no digits at all. An unverifiable round is
  # skipped rather than guessed, so it lands in neither the numerator nor the denominator.
  if ($prevDigits -notmatch '^[0-9]+$' -or $prevDigits -eq '') {
    $rows += [pscustomobject]@{ round = $r; kind = 'invoke'; pressed = ''
      d0 = $cur.display; d1 = 'skipped'; expected = ''
      effect = $null; fg0 = [CA]::Focus(); fg1 = [CA]::Focus(); changed = $false
      cursor0 = [CA]::Cursor(); cursor1 = [CA]::Cursor()
      error = "display value '$prev' has no usable digits (an error or fraction readout); the press cannot be predicted" }
    Start-Sleep -Milliseconds 400
    continue
  }
  $newNum = if ($prev -eq '0') { $pick.name } else { [string]$prev + [string]$pick.name }
  $expected = [string]$prefix + $newNum
  # The effect test compares NUMBERS, not strings. Round 4 of the first successful run read
  # 'Display is 1,234' against an expected 'Display is 1234' and scored a working click as a
  # failure, because Calculator inserts a thousands separator at 4+ digits. Comparing the
  # digits-only form of both sides keeps the oracle honest about what actually changed while
  # leaving the raw strings in the log, so a real formatting difference is still visible.
  $expDigits = ($expected -replace '[^0-9]', '')
  $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $f0 = [CA]::Focus(); $cx0 = [CA]::Cursor()
  $err = ''
  try {
    $bp = $null
    if ($pick.el.TryGetCurrentPattern([System.Windows.Automation.InvokePatternIdentifiers]::Pattern, [ref]$bp)) {
      $bp.Invoke()
    } else { $err = 'no InvokePattern on the re-resolved element' }
  } catch { $err = $_.Exception.Message }
  Start-Sleep -Milliseconds 500
  $f1 = [CA]::Focus(); $cx1 = [CA]::Cursor()
  # $t1 is taken at the END of the round, after the effect read-back, so the attribution
  # window covers everything this action did. A narrower window would be a prettier number
  # but could miss a delayed disturbance and attribute it to nothing at all.
  $tEnd = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  # The oracle is RE-READ, never trusted from the pre-action snapshot: a cached element whose
  # text went stale would report the old display and turn a working click into 'no effect'.
  $after = Get-CalNodes $hwnd 4000
  $d1 = if ($after) { $after.display } else { 're-read-failed' }
  $d1Digits = ([string]$d1 -replace '[^0-9]', '')
  $d0Digits = ([string]$cur.display -replace '[^0-9]', '')
  $rows += [pscustomobject]@{ round = $r; kind = 'invoke'; pressed = $pick.name; autoId = $pick.autoId
    d0 = $cur.display; d1 = $d1; expected = $expected; effect = ($d1Digits -eq $expDigits)
    changedDisplay = ($d1Digits -ne $d0Digits)
    fg0 = $f0; fg1 = $f1; changed = ($f0 -ne $f1); cursor0 = $cx0; cursor1 = $cx1; error = $err
    preconditionGuard = $guard
    t0 = $t0; t1 = $tEnd }
  Start-Sleep -Milliseconds 400
}

# $skippedN are rounds where no expected value could be predicted. They are counted out of
# the denominator rather than counted as failures: charging an unmeasurable round to the
# channel would understate coverage, exactly as the omnibox artifact overstated it.
$skippedN = @($rows | Where-Object { $null -eq $_.effect }).Count
$measuredN = $Rounds - $skippedN
$effN = @($rows | Where-Object { $_.effect }).Count
$fgN = @($rows | Where-Object { $_.changed }).Count
$curN = @($rows | Where-Object { $_.cursor0 -ne $_.cursor1 }).Count
$errN = @($rows | Where-Object { $_.error }).Count

# Stop the sampler and attribute every foreground/cursor observation before any number is
# printed. Ordering matters: an aggregate computed from raw counts and then "explained" is
# how a disturbance gets reported as neutral.
$stopped = $null
if ($samp) { $stopped = Stop-WpmSampler -S $samp }
$samples = if ($stopped) { $stopped.rows } else { @() }
$fgSoftTotal = 0; $fgHumanTotal = 0; $curSoftTotal = 0.0; $unattributable = 0; $minQuiet = 100.0
# "Not caused by physical input" is NOT "caused by the channel under test". This machine runs
# the DSH harness, uTools, Edge and others, all of which legitimately change the foreground.
# The destination of a software-attributed change is recorded for DESCRIPTION -- it tells us
# whom to go ask -- but it does NOT decide the verdict. R2.3 forbids foreground changes
# outright, and this instrument can prove only "not caused by physical input": it cannot
# prove the invoke caused a change, and it equally cannot exonerate the invoke. Bucketing by
# destination and then declaring the run neutral because the change landed elsewhere would be
# the laundering RM-4 exists to block, dressed up as rigor. So the neutral branch below is
# gated on softwareForegroundChanges = 0, whatever the destination was.
$fgSoftToTarget = 0; $fgSoftElsewhere = 0
$softDestDetail = @()
if ($samples.Count -ge 2) {
  for ($ri = 0; $ri -lt $rows.Count; $ri++) {
    $rw = $rows[$ri]
    if ($rw.kind -ne 'invoke' -or -not $rw.t0) { continue }
    $at = Get-WpmWindowAttribution -Samples $samples -a $rw.t0 -b $rw.t1
    if ($null -eq $at.fgSoft) { $unattributable++; continue }
    $rows[$ri] | Add-Member -NotePropertyName fgSoft -NotePropertyValue $at.fgSoft -Force
    $rows[$ri] | Add-Member -NotePropertyName fgHuman -NotePropertyValue $at.fgHuman -Force
    $rows[$ri] | Add-Member -NotePropertyName cursorSoftPx -NotePropertyValue $at.cursorSoftPx -Force
    $rows[$ri] | Add-Member -NotePropertyName quietFrac -NotePropertyValue $at.quietFrac -Force
    $fgSoftTotal += $at.fgSoft; $fgHumanTotal += $at.fgHuman
    $curSoftTotal += [double]$at.cursorSoftPx
    if ([double]$at.quietFrac -lt $minQuiet) { $minQuiet = [double]$at.quietFrac }
    if ($at.fgSoft -gt 0) {
      $dest = ([string]$rw.fg1 -split '/')[0]
      # Who actually took the foreground, named rather than numbered: "a software-caused
      # foreground change" is not actionable, "the harness opened a panel next door" is.
      # find-window.ps1 gained a reverse (-Hwnd) mode for exactly this, so the identity
      # comes from the same code path every window lookup in this repo uses.
      $info = ''
      $destPid = 0
      $rev = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
        (Join-Path $PSScriptRoot 'find-window.ps1') -Hwnd $dest 2>$null
      if ($rev) {
        $j = ($rev | Select-Object -Last 1) | ConvertFrom-Json
        $info = "$($j.title) || $($j.cls) || proc=$($j.process)"
        $destPid = [int]$j.procId
      }
      # TARGET means "the app under test took the foreground", which is NOT the same test as
      # "hwnd equals the handle we opened". The first attributed run's one software-caused
      # change went to a handle that is not the ApplicationFrameWindow we hold -- and the
      # reverse lookup shows it is that same Calculator's INNER CoreWindow. An exact-hwnd
      # comparison would have filed a genuine foreground theft under 'some other window' and
      # let the run pass. Comparing the owning process is the honest test.
      $isTarget = ($dest -eq $hwnd.ToString()) -or ($destPid -gt 0 -and $destPid -eq [int]$w.procId)
      if ($isTarget) { $fgSoftToTarget += $at.fgSoft } else { $fgSoftElsewhere += $at.fgSoft }
      $softDestDetail += "round $($rw.round) x$($at.fgSoft) -> hwnd $dest [$info] bucket=" +
        $(if ($isTarget) { 'TARGET' } else { 'other-window' })
    }
  }
} else { $unattributable = @($rows | Where-Object { $_.kind -eq 'invoke' -and $_.t0 }).Count }

''
$rows | ForEach-Object { "  round $($_.round) press $($_.autoId)='$($_.pressed)'  display '$($_.d0)' -> '$($_.d1)' (expected '$($_.expected)') effect=$($_.effect) fg=$($_.fg0)->$($_.fg1) softFg=$($_.fgSoft) humanFg=$($_.fgHuman) quiet=$($_.quietFrac)%$($_.preconditionGuard) err=$($_.error)" }
''
if ($softDestDetail.Count) {
  'software-attributed foreground changes, by destination process:'
  $softDestDetail | ForEach-Object { "  $_" }
  ''
}
"rounds=$Rounds preconditionLostAndReclaimed=$precondReclaims preconditionUnrecoverable=$precondFail measured=$measuredN skippedUnpredictable=$skippedN invokeWithDisplayEffect=$effN/$measuredN foregroundMoves=$fgN cursorMoves=$curN errors=$errN"
"attributed per-transition: softwareForegroundChanges=$fgSoftTotal softwareCursorPathPx=$([Math]::Round($curSoftTotal,1)) humanForegroundChanges=$fgHumanTotal unattributableRounds=$unattributable/$measuredN minQuietPct=$minQuiet"
''
if ($measuredN -lt [Math]::Ceiling($Rounds * 0.6)) {
  "VERDICT: INSTRUMENT INVALID -- only $measuredN/$Rounds rounds had a predictable display " +
  'value, so the effect rate would describe the probe. Re-run against a Calculator left in ' +
  'a plain numeric state.'
} elseif ($unattributable -gt 0 -or $minQuiet -lt 20) {
  "VERDICT: EFFECT RATE STANDS, NEUTRALITY DOES NOT -- $effN/$measuredN invokes changed the " +
  "app's own display, so UIA reaches this family; but unattributable rounds $unattributable " +
  "and lowest physically-quiet share $minQuiet% mean the zero software-caused foreground " +
  'count could be the instrument failing to see a violation rather than the channel being ' +
  'neutral. Quote the reach result, not the neutrality result, from this run.'
} elseif ($effN -ge [Math]::Ceiling($measuredN * 0.9) -and $fgSoftTotal -eq 0 -and [double]$curSoftTotal -eq 0) {
  # The two counts in the condition are the claim in the sentence. Without them here, a run
  # that printed softwareForegroundChanges=1 could still reach a verdict saying the channel
  # does not disturb the user -- which is exactly what the first attributed run did, and the
  # reason this line now checks the number instead of merely reporting it.
  'VERDICT: UIA Invoke reaches this family AND is attributable-neutral. The app display ' +
  "changed in $effN/$measuredN rounds while a DIFFERENT window held the foreground, with " +
  "softwareForegroundChanges=0, softwareCursorPathPx=0 and $fgHumanTotal human-explained " +
  'foreground changes. So the earlier 1/8 was an effect-oracle error, not unreachability: ' +
  'uap-framed, the largest family on this desktop, is drivable through UIA without ' +
  'disturbing the user -- the core of the R2 claim.'
} elseif ($effN -ge [Math]::Ceiling($measuredN * 0.9)) {
  'VERDICT: UIA Invoke REACHES this family (' + $effN + '/' + $measuredN + ' display changes) ' +
  "but neutrality is NOT established: $fgSoftTotal foreground change(s) occurred on physically " +
  "quiet sample gaps (of which $fgSoftToTarget landed on the target window, $fgSoftElsewhere " +
  'elsewhere) and ' + $curSoftTotal + ' cursor px were software-attributed. Reachability and ' +
  'disturbance are separate claims; this run supports the first only.'
} elseif ($effN -eq 0 -and $measuredN -gt 0) {
  'VERDICT: Invoke produced NO display change in any measured round while the oracle ' +
  'demonstrably reads the display. This family is genuinely not reachable through UIA ' +
  'Invoke in this state, and that is a coverage finding, not an instrument one.'
} else {
  "VERDICT: PARTIAL -- $effN/$Rounds. Report the per-round table; some rounds are being lost " +
  'for a reason that the aggregate would hide (tree rebuild between resolve and invoke, or ' +
  'a digit that leaves the display text unchanged).'
}

# Clear the number back toward its starting state: press C (clear) if present.
$cl = Get-CalNodes $hwnd 3000
try { Set-Content -LiteralPath $grabExit -Value 'exit' -Force } catch { }
Start-Sleep -Milliseconds 800
try { Stop-Process -Id $grabProc.Id -Force -ErrorAction Stop } catch { }
