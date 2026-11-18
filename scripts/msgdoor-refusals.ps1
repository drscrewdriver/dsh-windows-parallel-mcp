# msgdoor-refusals.ps1 — failure list with reason codes, for the message-door channels.
#
# WHY THIS EXISTS. G0 line 3 asks for "the failure list and failure reason codes", and the
# channel matrix could not produce one: its target offered only a working TextBox, a working
# RichTextBox and an enabled Button, so every cell was a success and no refusal was observable.
# A door that silently refuses is indistinguishable from a dead driver unless the dead case is
# present in the same run -- and the case that matters most is the one where the API ANSWERS
# SUCCESSFULLY while the control does nothing. Cross-process SendMessage of WM_SETTEXT to a
# read-only edit was measured to return 1 (TRUE) with no effect: an engine trusting the return
# value would report a completed write. This run puts eight control shapes and three message
# channels through that test and counts the lies.
#
# WHAT COUNTS AS AN EFFECT. Never the API's answer, never WM_GETTEXT (measured blind across
# processes), only the owning application's own state, refreshed 4x/second into a file. For the
# click channel, the button's caption text changing is the app's own report that its Click
# handler ran.
#
# IDENTIFICATION. Children are matched to the app's labels through UIA Name, which equals the
# control's text for these shapes. A child whose Name matches nothing authored is reported as
# IDENT-FAILED rather than being placed by position: positional matching is exactly the
# heuristic that made an earlier experiment type into a browser's address bar believing it had
# reached the page, so where it would be needed here, the gap is printed instead.
#
# OWN WINDOW ONLY. This launches and closes its own target. No physical cursor movement, no
# keyboard, and no window this script did not create.
param(
  [int]$RoundsPerCell = 3,
  [string[]]$Channels = @('none', 'wm-char', 'wm-settext', 'wm-lbutton'),
  [int]$WaitMs = 20000
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $PSScriptRoot 'sampler-hooks.ps1')
function Find-Win([string]$m) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $m 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class MD {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct RC { public int l, t, r, b; }
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EP c, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  // The foreground window, for the raise check. Declared here rather than reused from the
  // channel matrix's CM class: this script is a separate process, and a reference to a type
  // defined in another file resolves at RUNTIME -- the parse gate passes and the run dies
  // after it has already launched its target, which is the failure class this repo keeps
  // meeting and keeps forgetting to check for.
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassNameW(h, s, s.Capacity); return s.ToString(); }
  public static string Rect(IntPtr h) { RC r; return GetWindowRect(h, out r) ? r.l + "," + r.t + "," + r.r + "," + r.b : "unreadable"; }
  public static List<long> Children(IntPtr top) {
    var acc = new List<long>();
    EnumChildWindows(top, delegate (IntPtr h, IntPtr l) { if (IsWindowVisible(h)) acc.Add(h.ToInt64()); return true; }, IntPtr.Zero);
    return acc;
  }
  public static string Cursor() { POINT p; GetCursorPos(out p); return p.x + "," + p.y; }
  public static string Fg() { return GetForegroundWindow().ToInt64().ToString(); }
}
'@

# ---- launch our own target ----
$exitF = Join-Path $env:TEMP ('wpm-md-' + [guid]::NewGuid().ToString('N') + '.stop')
$stateF = Join-Path $env:TEMP ('wpm-md-state-' + [guid]::NewGuid().ToString('N') + '.txt')
$proc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'msgdoor-target.ps1'), '-HoldMs', '300000',
  '-ExitFile', "`"$exitF`"", '-StateFile', "`"$stateF`"", '-Title', 'WpmDoorTarget',
  '-X', '1000', '-Y', '300' -PassThru
$w = $null
for ($i = 0; $i -lt [int]($WaitMs / 400) -and -not $w; $i++) { Start-Sleep -Milliseconds 400; $w = Find-Win 'WpmDoorTarget' }
if (-not $w) { throw 'door target never appeared' }
$hwnd = [IntPtr]$w.hwnd
"door target: hwnd=$hwnd rect=$([MD]::Rect($hwnd))"

function Get-AppState {
  if (-not (Test-Path -LiteralPath $stateF)) { return @{} }
  $l = (Get-Content -LiteralPath $stateF -Tail 1 -ErrorAction SilentlyContinue | Select-Object -Last 1)
  $d = @{}
  if ($l) { foreach ($p in ($l -split "`t")) { $kv = $p -split '=', 2; if ($kv.Count -eq 2) { $d[$kv[0]] = $kv[1] } } }
  return $d
}
$app0 = @{}
for ($i = 0; $i -lt 40 -and -not $app0.Count; $i++) {
  # WAIT for the oracle, do not sample it once. The window becomes enumerable before the
  # target's first timer tick writes the state file, so a single read loses a race that
  # depends on where the 250ms tick happens to fall: of three otherwise-identical runs, two
  # died here and one passed, which is the definition of a flaky instrument. A retry loop
  # turns that into a precondition with a deadline, and the deadline failure still says what
  # was missing rather than guessing.
  $app0 = Get-AppState
  if (-not $app0.Count) { Start-Sleep -Milliseconds 300 }
}
if (-not $app0.Count) { throw 'app-side state file never appeared within ~12s: no effect can be verified' }
"app-side labels at start: $(($app0.Keys | Sort-Object) -join ', ')"

# ---- child HWND -> label, via UIA Name (= the control's own text) ----
$AUTHORED = @{}
foreach ($k in $app0.Keys) { $AUTHORED[[string]$app0[$k]] = $k }
$childOf = @{}
$identFail = @()
try {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  for ($i = 0; $i -lt [Math]::Min($all.Count, 200); $i++) {
    $nh = 0
    try { $nh = [int64]$all[$i].Current.NativeWindowHandle } catch { continue }
    if ($nh -eq 0) { continue }
    $nm = ''
    try { $nm = [string]$all[$i].Current.Name } catch { }
    if ($AUTHORED.ContainsKey($nm)) { $childOf[$AUTHORED[$nm]] = [IntPtr]$nh }
    else { $identFail += "hwnd $nh name='$nm'" }
  }
} catch { "UIA mapping threw: $($_.Exception.Message)" }
# `$childOf.Count` does not interpolate in a double-quoted string -- expansion stops at the
# variable name, so this printed "resolved System.Collections.Hashtable.Count" -- it needs $(...).
"resolved $(@($childOf.Keys).Count) / $($app0.Count) labels by name:"
foreach ($k in ($childOf.Keys | Sort-Object)) { "  {0,-14} hwnd={1}" -f $k, $childOf[$k] }
if ($identFail.Count) { "unmatched (NOT placed by position, which is where wrong-window writes come from):" + ($identFail -join '; ') }
''

# ---- the classification that turns 'nothing happened' into a reason code ----
function Classify-Refusal([string]$label, [int]$ret, [bool]$eff, [bool]$dis, [bool]$ro) {
  # -1 is MY sentinel for "this channel does not address this shape" -- no message was sent
  # at all. It has to be its own code: the first version fell through to SILENT_NOOP, so
  # 14 cells reported "SendMessage answered success and nothing changed" included cells where
  # nothing was ever sent. That is the same laundering as counting a refused action as a
  # quiet one -- it converts an untested cell into a result.
  if ($ret -eq -1) { return 'NOT_APPLICABLE (no message sent)' }
  if ($eff) { return 'SUCCESS' }
  # Read-only/disabled state is asked of the app itself rather than inferred from the API's
  # answer, because the API is the thing under suspicion.
  if ($dis) { return 'CONTROL_DISABLED' }
  if ($ro) { return 'CONTROL_READONLY' }
  if ($ret -eq 0) { return 'WNDPROC_REFUSED (SendMessage returned FALSE)' }
  return 'SILENT_NOOP (returned success, control unchanged)'
}
# app-side readonly/disabled truth for each shape, from the target's own knowledge: encoded
# here as authored expectation, since a cross-process read of another app's control flags is
# not reliably available. The state file cannot say it, so the table says it and the run
# reports which cells relied on the table rather than on a measurement.
$EXPECT = @{
  doorEditOk = @{ dis = $false; ro = $false; kind = 'edit' }
  doorEditRo = @{ dis = $false; ro = $true; kind = 'edit' }
  doorEditDis = @{ dis = $true; ro = $false; kind = 'edit' }
  doorEditMulti = @{ dis = $false; ro = $false; kind = 'edit' }
  doorRich = @{ dis = $false; ro = $false; kind = 'rich' }
  doorCombo = @{ dis = $false; ro = $false; kind = 'combo' }
  doorBtnOk = @{ dis = $false; ro = $false; kind = 'button' }
  doorBtnDis = @{ dis = $true; ro = $false; kind = 'button' }
}

function Act([string]$ch, [IntPtr]$child, [string]$label) {
  $before = [string](Get-AppState).$label
  switch ($ch) {
    'none' { return @{ ret = 1; before = $before; after = $before; expect = $before; note = 'control: no call' } }
    'wm-char' {
      if ($EXPECT[$label].kind -notin @('edit', 'rich', 'combo')) { return @{ ret = -1; before = $before; after = $before; expect = $before; note = 'not a text shape' } }
      $r = [MD]::SendMessageW($child, 0x0102, [IntPtr]([int][char]'Q'), [IntPtr]::Zero)
      Start-Sleep -Milliseconds 500
      # WM_CHAR inserts at the caret, which without focus sits at 0 (measured abc -> Qabc), so
      # 'Q anywhere' is the honest expectation. The previous draft tried to express an OR by
      # concatenating two patterns into one string ('LIKE:*Q*' + ';EQ:Qabc'), which is a single
      # glob that nothing can match -- and the resulting 6 SILENT_NOOP rows were then an
      # artifact of my own oracle, not evidence that the API lied. An expectation encoding
      # must be checkable against a known-good cell before its failures are believed.
      return @{ ret = [int]$r; before = $before; after = [string](Get-AppState).$label
        expect = 'LIKE:*Q*'; note = 'WM_CHAR Q' }
    }
    'wm-settext' {
      if ($EXPECT[$label].kind -notin @('edit', 'rich')) { return @{ ret = -1; before = $before; after = $before; expect = $before; note = 'not a text shape' } }
      $txt = [string]$before + 'Z'
      $ptr = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($txt)
      try { $r = [MD]::SendMessageW($child, 0x000C, [IntPtr]::Zero, $ptr) }
      finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
      Start-Sleep -Milliseconds 500
      # WM_SETTEXT is a literal assignment, so the expected result is EXACT: before + 'Z'.
      # Using "after != before" here would score a field that got WIPED as a success -- and a
      # multiline edit was measured doing exactly that (QQmulti-abc -> empty, ret=1). The weak
      # oracle called a corruption SUCCESS, which is the A2 failure in its most useful form:
      # not "no effect counted as effect" but "wrong effect counted as right effect".
      return @{ ret = [int]$r; before = $before; after = [string](Get-AppState).$label
        expect = 'EQ:' + $txt; note = 'WM_SETTEXT +Z' }
    }
    'wm-lbutton' {
      if ($EXPECT[$label].kind -ne 'button') { return @{ ret = -1; before = $before; after = $before; expect = $before; note = 'not a button' } }
      $lp = [IntPtr](6 + (6 -shl 16))
      [void][MD]::SendMessageW($child, 0x0201, [IntPtr]1, $lp)
      Start-Sleep -Milliseconds 60
      [void][MD]::SendMessageW($child, 0x0202, [IntPtr]0, $lp)
      Start-Sleep -Milliseconds 500
      $after = [string](Get-AppState).$label
      return @{ ret = 1; before = $before; after = $after
        # The handler rewrites 'Press' -> 'Press(n)'. Any change to the caption proves the
        # Click handler ran; exactness is not expected because the counter value depends on
        # how many prior rounds fired.
        expect = 'LIKE:*(*'; note = 'WM_LBUTTONDOWN/UP' }
    }
  }
}

# The sampler MUST be running before any cell acts, so every observed raise and cursor move
# can later be attributed to physical input or to the channel. Failing closed if it cannot
# record: a run without attribution can only report raw observations, and a raw 'the cursor
# moved during this cell' is indistinguishable from the human operator moving the mouse --
# exactly the run6-vs-run7 split (raw 0/0 vs 1/6 from one identical command) that this probe
# produced before attribution existed. The reason-code table needs no sampler, but the
# foreground/cursor claims do, and the script must not emit those unsupported.
$samp = Start-WpmSampler -Hz 20 -Tag 'refusals'
if (-not $samp.ok) { throw "sampler failed to record (bootBytes=$($samp.bootBytes)): observed raises/cursor-moves could not be attributed to physical input vs the channel, so no neutrality claim may be made" }
"sampler: bootBytes=$($samp.bootBytes) out=$(Split-Path $samp.out -Leaf)"
''
$rows = @()
foreach ($label in ($app0.Keys | Sort-Object)) {
  $child = if ($childOf.ContainsKey($label)) { $childOf[$label] } else { $null }
  if (-not $child) {
    $rows += [pscustomobject]@{ shape = $label; channel = '(all)'; ret = ''; effect = $false
      code = 'IDENT-FAILED'; raised = $false; before = [string]$app0[$label]; after = '' }
    continue
  }
  foreach ($ch in $Channels) {
    for ($r = 1; $r -le $RoundsPerCell; $r++) {
      $cur = [string](Get-AppState).$label
      $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $cx0 = [MD]::Cursor(); $f0 = [MD]::Fg()
      $res = Act $ch $child $label
      $cx1 = [MD]::Cursor()
      $raisedRaw = ($f0 -ne [MD]::Fg())
      $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $eff = $false
      $corrupt = $false
      if ($ch -ne 'none' -and $res.ret -ne -1) {
        $exp = [string]$res.expect
        if ($exp.StartsWith('LIKE:')) {
          $pat = $exp.Substring(5)
          $eff = ($res.after -like $pat)
        } elseif ($exp.StartsWith('EQ:')) {
          $want = $exp.Substring(3)
          $eff = ($res.after -eq $want)
          # changed but NOT to the expected value: the write landed somewhere unintended.
          $corrupt = (-not $eff) -and ($res.after -ne $res.before)
        }
      }
      $code = if ($ch -eq 'none') { 'CONTROL-ARM' } else { Classify-Refusal $label $res.ret $eff $EXPECT[$label].dis $EXPECT[$label].ro }
      if ($corrupt) { $code = 'CORRUPTION (value changed, not as expected)' }
      $rows += [pscustomobject]@{ shape = $label; channel = $ch; ret = $res.ret; effect = $eff
        corrupt = $corrupt; code = $code; raisedRaw = $raisedRaw; before = $res.before; after = $res.after
        cursorMovedRaw = ($cx0 -ne $cx1); note = $res.note; t0 = $t0; t1 = $t1 }
    }
  }
}
''
$stopped = Stop-WpmSampler -S $samp
$samples = if ($stopped) { $stopped.rows } else { @() }
"sample rows collected: $($samples.Count)"
''
$rows | Where-Object { $_.channel -ne 'none' } | ForEach-Object {
  "  $($_.shape) $($_.channel) ret=$($_.ret) effect=$($_.effect) raisedRaw=$($_.raisedRaw) $($_.before) -> $($_.after) [$($_.code)]"
}
''
$table = @($rows | Where-Object { $_.channel -ne 'none' -and $_.code -ne 'CONTROL-ARM' } |
  Group-Object code | ForEach-Object {
    [pscustomobject]@{ reason_code = $_.Name; cells = $_.Count
      channels = (($_.Group | ForEach-Object { $_.channel } | Sort-Object -Unique) -join '/')
      shapes = (($_.Group | ForEach-Object { $_.shape } | Sort-Object -Unique) -join ',') }
  })
$table | Format-Table -AutoSize | Out-String -Width 220

# ---- ATTRIBUTION: which observed disturbance is the CHANNEL's ----
# A raw 'the cursor moved' or 'the foreground changed' during a cell is NOT the channel's
# doing unless the sampler shows it happened during time NOT attributable to physical input
# (the per-gap GetLastInputInfo rule shared via sampler-hooks). Without this, run6 and run7
# of the identical command disagreed (0/0 vs raised=1/cursor=6) purely because a human was
# moving the mouse in one of them -- and the script would have cried 'A1 VIOLATED' at the
# operator's own hand. Each cell is attributed over its OWN [t0,t1] window.
$curSoftTotal = 0.0
$raiseSoft = 0; $raiseHuman = 0; $raiseUnknown = 0
foreach ($rw in $rows) {
  $at = Get-WpmWindowAttribution -Samples $samples -a $rw.t0 -b $rw.t1
  $rw | Add-Member -NotePropertyName fgSoft -NotePropertyValue $at.fgSoft -Force
  $rw | Add-Member -NotePropertyName fgHuman -NotePropertyValue $at.fgHuman -Force
  $rw | Add-Member -NotePropertyName cursorSoftPx -NotePropertyValue $at.cursorSoftPx -Force
  if ($at.cursorSoftPx) { $curSoftTotal += $at.cursorSoftPx }
  if ($rw.raisedRaw) {
    if ($at.fgSoft) { $raiseSoft++ }
    elseif ($at.fgHuman) { $raiseHuman++ }
    else { $raiseUnknown++ }
  }
}
$lied = @($rows | Where-Object { $_.code -eq 'SILENT_NOOP (returned success, control unchanged)' })
$none = @($rows | Where-Object { $_.channel -eq 'none' })
$noneRaised = @($none | Where-Object { $_.raisedRaw }).Count
''
"cells acted on: $(@($rows | Where-Object { $_.channel -ne 'none' }).Count)   control (no call) rounds: $($none.Count) raised=$noneRaised"
"raises attributed to CHANNEL: $raiseSoft  to HUMAN input: $raiseHuman  unattributable: $raiseUnknown"
"cursor displacement during software-quiet time: $([Math]::Round($curSoftTotal,1)) px (channel-attributable A1 measure)"
"cells where SendMessage answered nonzero while the control did NOT change: $($lied.Count)"
''
if ($curSoftTotal -gt 1) {
  'A1 VIOLATED: ' + [Math]::Round($curSoftTotal,1) + ' px of cursor movement occurred while the ' +
  'sampler attributed that time to NO physical input. The premise of the whole channel is that ' +
  'messages do not touch the pointer, so this is a channel failure, not an operator artifact.'
} elseif ($raiseSoft -gt $noneRaised) {
  "RAISING ATTRIBUTED TO THE CHANNEL: $raiseSoft cells raised on software-quiet time against " +
  "$noneRaised/$($none.Count) control rounds. The message door is NOT foreground-neutral on " +
  'these shapes. (A further ' + "$raiseHuman raised only during human input and $raiseUnknown " +
  'during an unknown gap -- those are NOT counted against the channel.)'
} elseif ($lied.Count -gt 0) {
  'REFUSAL SEMANTICS: the API return value is NOT a success signal. In ' + "$($lied.Count) cells " +
  'SendMessage answered nonzero while the owning application reported no change, so an engine ' +
  'that trusts the return value would have reported completed writes that never happened. The ' +
  'engine must therefore verify every message write app-side -- or against a read path that is ' +
  'not the one the write is suspected of missing -- and must map the observed refusals to the ' +
  'codes above rather than collapsing them into one generic failure.'
} else {
  'REFUSAL SEMANTICS: no case observed where the API answered success and the control did not ' +
  'change, in this sample. That is a statement about these shapes, not a licence to trust ' +
  'return values generally.'
}

try { Set-Content -LiteralPath $exitF -Value 'exit' -Force } catch { }
Start-Sleep -Milliseconds 1200
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
