# channel-raise-matrix.ps1 — which input channels raise their target window?
#
# THE QUESTION. R2.2 says "UIA pattern, then target-window messages", assuming UIA is the
# quiet channel. Measured: UIA Invoke raises its window and window messages do not. This
# script is the instrument that decided that, and it is the third design of itself; the two
# earlier ones printed wrong conclusions, recorded below because each wrong conclusion was a
# specific and non-obvious failure of method.
#
# WHAT IS MEASURED, PER CHANNEL, all four acting on the SAME window:
#   invoke      UIA InvokePattern.Invoke        on the classic BUTTON child
#   setvalue    UIA ValuePattern.SetValue       on the classic EDIT child
#   wm-char     WM_CHAR to the EDIT child       (the classic text door)
#   wm-settext  WM_SETTEXT to the EDIT child    (the classic text door)
#   none        no call at all -- the control arm, which measures this desktop's own rate of
#               spontaneously foregrounding this window
#
# WHY ONE WINDOW AND ONE TOOLKIT. The previous version put UIA channels on a WPF window and
# message channels on a WinForms one. UIA raises, so the next round must first push the window
# BACK out of the foreground, and that reset works on WinForms but not on WPF -- WPF
# re-asserts its own visibility from its render pass. Result: 11 discards, all on the WPF-side
# channels, and an OVERALL line that read "R2 is supported across every channel" while the
# same table hid those failures. Two arms that cannot be given the same precondition are not a
# comparison. Every channel now acts on the window whose reset is verifiable.
#
# WHY NOTHING HERE CALLS SetForegroundWindow. Only the process owning the current foreground
# window, or holding the last input event, may take it -- so a foreground hand-off is a favour
# the desktop grants or withholds. One run got 30 of 36 rounds rejected because Calculator held
# the foreground and was not ours to move. Reproducibility must not depend on somebody else's
# permission, so this instrument only ever REMOVES its own window from the foreground, via
# ShowWindow, which the foreground lock does not restrict. The RESET CONTROL below proves that
# route against a real raise.
#
# CONVICTION IS A COMPARISON. Guards (mouse button down, Alt/Ctrl/Win chord down, cursor
# inside the target rect) exclude the human mechanisms we can detect, in BOTH arms equally --
# chord keys matter because Alt+Tab changes the foreground with no mouse and no cursor motion,
# so absence of mouse input alone proves nothing. A round failing a guard is discarded and
# counted, never averaged into a rate. Effect verification lives INSIDE each channel, because a
# cell that reports "no raise" on the strength of a call that did nothing is A1 without A2.
#
# VERDICT ORDER IS THE POINT. Insufficient data and instrument failure are checked BEFORE any
# conclusion about channels, in both the per-cell and overall branches. Every wrong output this
# instrument has ever produced came from a branch order that let a null result speak.
param(
  [int]$Rounds = 8,
  [int]$SampleEveryMs = 20,
  [int]$ActionWindowSamples = 30,
  [string[]]$Channels = @('none', 'invoke', 'setvalue', 'wm-char', 'wm-settext')
)
$ErrorActionPreference = 'Stop'
# BEFORE any UIA type is touched, in THIS process. The targets set these switches themselves,
# but the driver reads patterns from here, and powershell.exe runs with the legacy defaults --
# under which WinForms surfaces through the MSAA bridge with NO patterns at all. The first run
# of this file reported "InvokePattern=FALSE ValuePattern=FALSE" and concluded ABSENT ON THIS
# TOOLKIT, which was a true statement about this process's UIA client and a false one about
# WinForms. The same trap is recorded in the repo for the target scripts; it had to be hit a
# second time in the reader to be caught.
foreach ($sw in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.2', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.3') {
  try { [AppContext]::SetSwitch($sw, $false) } catch { }
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $PSScriptRoot 'sampler-hooks.ps1')

function Find-Win([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CM {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct RC { public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential)] public struct GTI {
    public int cbSize; public int flags; public IntPtr hwndActive; public IntPtr hwndFocus;
    public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret;
    public RC rc;
  }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint id, ref GTI g);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  public static string Cursor() { POINT p; GetCursorPos(out p); return p.x + "," + p.y; }
  public static string Fg() { return GetForegroundWindow().ToInt64().ToString(); }
  public static string Focus() {
    IntPtr fg = GetForegroundWindow();
    uint tid = GetWindowThreadProcessId(fg, IntPtr.Zero);
    GTI g = new GTI(); g.cbSize = Marshal.SizeOf(typeof(GTI));
    if (!GetGUIThreadInfo(tid, ref g)) return fg.ToInt64() + "/ERR";
    return fg.ToInt64() + "/" + g.hwndFocus.ToInt64();
  }
  public static bool MouseDown() {
    return (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0 ||
           (GetAsyncKeyState(0x04) & 0x8000) != 0 || (GetAsyncKeyState(0x05) & 0x8000) != 0;
  }
  public static bool ChordKeyDown() {
    return (GetAsyncKeyState(0x11) & 0x8000) != 0 || (GetAsyncKeyState(0x12) & 0x8000) != 0 ||
           (GetAsyncKeyState(0x5B) & 0x8000) != 0 || (GetAsyncKeyState(0x5C) & 0x8000) != 0;
  }
  public static bool CursorInRect(IntPtr h) {
    POINT p; if (!GetCursorPos(out p)) return true;    // unreadable counts as SUSPECT
    RC r; if (!GetWindowRect(h, out r)) return true;   // unknown is never "clean"
    return p.x >= r.l && p.x <= r.r && p.y >= r.t && p.y <= r.b;
  }
  public static string Rect(IntPtr h) {
    RC r; if (!GetWindowRect(h, out r)) return "unreadable";
    return r.l + "," + r.t + "," + r.r + "," + r.b;
  }
  public static bool Iconic(IntPtr h) { return IsIconic(h); }
  // SW_HIDE(0) then SW_SHOWNA(8): remove OUR OWN window from the foreground. ShowWindow does
  // not activate, so the foreground lock never refuses it -- the only route that works
  // whether or not anyone currently holds a foreground grant.
  public static void Unforeground(IntPtr h) { ShowWindow(h, 0); ShowWindow(h, 8); }
}
'@

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class CHW {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EP c, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassNameW(h, s, s.Capacity); return s.ToString(); }
  public static List<string> ByKind(IntPtr parent, string want) {
    List<string> acc = new List<string>();
    EnumChildWindows(parent, delegate (IntPtr h, IntPtr l) {
      string c = Cls(h);
      bool hit = want == "edit"
        ? (c.IndexOf("EDIT", StringComparison.OrdinalIgnoreCase) >= 0 ||
           c.IndexOf("RichEdit", StringComparison.OrdinalIgnoreCase) >= 0)
        : c.IndexOf("BUTTON", StringComparison.OrdinalIgnoreCase) >= 0;
      if (hit) {
        StringBuilder tx = new StringBuilder(512); GetWindowTextW(h, tx, tx.Capacity);
        acc.Add(h.ToInt64() + "\t" + c + "\t" + tx.ToString() + "\t" + IsWindowVisible(h));
      }
      return true;
    }, IntPtr.Zero);
    return acc;
  }
}
'@
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WT {
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  public static string Of(IntPtr h) {
    int n = GetWindowTextLength(h);
    StringBuilder sb = new StringBuilder(n + 2);
    GetWindowTextW(h, sb, sb.Capacity);
    return sb.ToString();
  }
}
'@

# ---- the acting window -----------------------------------------------------------
$wfExit = Join-Path $env:TEMP ('wpm-cm-wf-' + [guid]::NewGuid().ToString('N') + '.stop')
$wfState = Join-Path $env:TEMP ('wpm-cm-wfstate-' + [guid]::NewGuid().ToString('N') + '.txt')
$wfProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '600000', '-ExitFile', "`"$wfExit`"",
  '-StateFile', "`"$wfState`"", '-Title', 'WpmMsgTarget', '-X', '1000', '-Y', '430' -PassThru
$wf = $null
for ($i = 0; $i -lt 80 -and -not $wf; $i++) { Start-Sleep -Milliseconds 400; $wf = Find-Win 'WpmMsgTarget' }
if (-not $wf) { throw 'target window never appeared' }
$actH = [IntPtr]$wf.hwnd
"acting window (all channels): hwnd=$($actH) rect=$([CM]::Rect($actH)) iconic=$([CM]::Iconic($actH))"

function Get-AppState {
  # The owning process's own view of its controls, refreshed every timer tick. THIS is the
  # effect oracle for every channel: cross-process WM_GETTEXT on another process's edit was
  # measured BLIND -- it kept returning 'abc' after a WM_SETTEXT the app itself reported as
  # 'abcZ', and returned '' for a RichTextBox holding 'rich-abc'. Verifying a write with the
  # same read path the write is suspected of not reaching is circular, and here also false.
  if (-not (Test-Path -LiteralPath $wfState)) { return @{ ok = $false; edit = ''; rich = ''; btn = '' } }
  $l = (Get-Content -LiteralPath $wfState -Tail 1 -ErrorAction SilentlyContinue | Select-Object -Last 1)
  if (-not $l) { return @{ ok = $false; edit = ''; rich = ''; btn = '' } }
  $p = $l -split "`t"
  return @{ ok = $true; edit = $p[0]; rich = $(if ($p.Count -gt 1) { $p[1] } else { '' })
    btn = $(if ($p.Count -gt 2) { $p[2] } else { '' }) }
}
$stStart = Get-AppState
if (-not $stStart.ok) { throw 'app-side state oracle never appeared: no channel can be verified' }
"app-side oracle: edit='$($stStart.edit)' rich='$($stStart.rich)' btn='$($stStart.btn)'"

# ---- element addresses, from the classic tree ------------------------------------
$editKids = @([CHW]::ByKind($actH, 'edit'))
$btnKids = @([CHW]::ByKind($actH, 'button'))
"children: edit=$($editKids.Count) button=$($btnKids.Count)"
if (-not $btnKids.Count) { throw 'no BUTTON child: invoke channel untestable' }
if (-not $editKids.Count) { throw 'no EDIT child: message channels untestable' }
$btnH = [IntPtr]([int64](($btnKids[0] -split '\t')[0]))
# The SINGLE-LINE edit, not the RichEdit: WM_SETTEXT on a RichEdit answers differently, and
# mixing them in one cell would report one control's behaviour as the toolkit's.
$editLine = @($editKids | Where-Object { (($_ -split '\t')[1]) -notlike '*RichEdit*' } | Select-Object -First 1)
if (-not $editLine) { $editLine = @($editKids)[0] }
$editH = [IntPtr]([int64](($editLine -split '\t')[0]))
"invoke child: hwnd=$btnH class=$((($btnKids[0] -split '\t')[1]))"
"message/value child: hwnd=$editH class=$((($editLine -split '\t')[1]))"

function Get-UiaForChild([IntPtr]$top, [IntPtr]$child, [string]$kind) {
  # Matched by NativeWindowHandle, NOT by ControlType. Measured directly: this target's WinForms
  # controls arrive as ControlType=Pane to this UIA client (three descendants, all Pane, all
  # with real HWNDs). Filtering for Button/Edit would therefore report the pattern door as
  # ABSENT on the one toolkit where the message door works -- the reverse of the truth.
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($top)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    for ($i = 0; $i -lt [Math]::Min($all.Count, 300); $i++) {
      $h2 = 0
      try { $h2 = [int64]$all[$i].Current.NativeWindowHandle } catch { continue }
      if ($h2 -ne [int64]$child) { continue }
      $nm = ''
      try { $nm = [string]$all[$i].Current.Name } catch { }
      if ($kind -eq 'invoke') {
        $bp = $null
        try { if ($all[$i].TryGetCurrentPattern([System.Windows.Automation.InvokePatternIdentifiers]::Pattern, [ref]$bp)) { return @{ pat = $bp; name = $nm } } } catch { }
      } else {
        $vp = $null
        try { if ($all[$i].TryGetCurrentPattern([System.Windows.Automation.ValuePatternIdentifiers]::Pattern, [ref]$vp)) { return @{ pat = $vp; name = $nm } } } catch { }
      }
      return $null
    }
  } catch { }
  return $null
}

function Ensure-TargetBackground([IntPtr]$h) {
  # Return '' once the target verifiably does NOT hold the foreground, else the reason.
  for ($i = 0; $i -lt 6; $i++) {
    if (([CM]::Fg()) -ne $h.ToString()) { return '' }
    [CM]::Unforeground($h)
    Start-Sleep -Milliseconds 350
  }
  if (([CM]::Fg()) -ne $h.ToString()) { return '' }
  return 'could not move our own target out of the foreground (hide/show refused)'
}

# ---- pattern preflight -----------------------------------------------------------
$preBtn = Get-UiaForChild $actH $btnH 'invoke'
$preEdit = Get-UiaForChild $actH $editH 'setvalue'
"UIA pattern preflight: InvokePattern(button)=$([bool]$preBtn) ValuePattern(edit)=$([bool]$preEdit)"
if (-not $preBtn -or -not $preEdit) {
  # ABSENT has two very different causes and they must not share a verdict: the toolkit really
  # exposes no pattern, OR this script's element-matching (by NativeWindowHandle) failed to
  # find the element it was looking for. Dumping the tree answers which, in the same run.
  'preflight diagnostic -- what the UIA tree actually reports for this window:'
  try {
    $diagRoot = [System.Windows.Automation.AutomationElement]::FromHandle($actH)
    $diagAll = $diagRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    for ($i = 0; $i -lt [Math]::Min($diagAll.Count, 8); $i++) {
      $dct = ''
      try { $dct = ($diagAll[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { }
      $dh = 0
      try { $dh = [int64]$diagAll[$i].Current.NativeWindowHandle } catch { }
      $dn = ''
      try { $dn = [string]$diagAll[$i].Current.Name } catch { }
      # The target's own handles, printed alongside, so a matching failure is visible as the
      # two sets not overlapping rather than as an invisible absence.
      '  ct={0,-8} native={1,-10} name={2,-14} (seeking button={3} edit={4})' -f $dct, $dh, $dn, $btnH, $editH
    }
  } catch { "  diagnostic threw: $($_.Exception.Message)" }
}
if (-not $preBtn) {
  '  InvokePattern is NOT exposed to this UIA client on this child: the invoke cell will ' +
  'report ABSENT, which is a coverage finding, not a quiet-channel finding.'
}
if (-not $preEdit) {
  '  ValuePattern is NOT exposed to this UIA client on this child: same reading as above.'
}

# ---- RESET CONTROL, permission-free ----------------------------------------------
# Uses the finding as the test. UIA Invoke is known to raise its window; if invoking the
# button moves the foreground here, the reset must then undo a raise produced by the real
# mechanism rather than undo nothing. If the reset works against that, a 0-raise result below
# means the channel was genuinely tested from the background.
$rcErr0 = Ensure-TargetBackground($actH)
$rcRaised = $false
$rcDetail = 'no InvokePattern available'
if (-not $rcErr0 -and $preBtn) {
  try {
    $preBtn.pat.Invoke()
    Start-Sleep -Milliseconds 400
    $rcRaised = (([CM]::Fg()) -eq $actH.ToString())
    $rcDetail = "invoke raised target=$rcRaised"
  } catch { $rcDetail = "control invoke threw: $($_.Exception.Message)" }
}
$rcResetErr = Ensure-TargetBackground($actH)
if ($rcErr0) { "RESET CONTROL FAILED AT BASELINE: $rcErr0" }
elseif ($preBtn -and -not $rcRaised) { "RESET CONTROL INCONCLUSIVE: $rcDetail (contradicts the earlier run)" }
elseif ($rcResetErr) { "RESET CONTROL FAILED: $rcDetail but reset refused ($rcResetErr)" }
else { "RESET CONTROL PASSED: $rcDetail and the reset undid it (fg now=$([CM]::Fg()))" }

# The run is invalid if the precondition cannot be established or restored: a raise cannot be
# observed from a window that is already foreground, and rounds following an unrestorable raise
# start from the foreground and cannot raise again.
$instrumentBad = ($rcErr0 -or ($preBtn -and -not $rcRaised) -or $rcResetErr)
''

function Invoke-Channel([string]$ch) {
  # @{ ok; detail; missing }. `missing` marks a channel that does not EXIST on this
  # toolkit/client -- absent and quiet are different findings and must never share a cell.
  switch ($ch) {
    'none' { return @{ ok = $true; detail = 'control: no call' } }
    'invoke' {
      if (-not $preBtn) { return @{ missing = $true; ok = $false; detail = 'InvokePattern absent' } }
      $b2 = Get-UiaForChild $actH $btnH 'invoke'
      if (-not $b2) { return @{ ok = $false; detail = 'button lost from UIA tree' } }
      $n0 = (Get-AppState).btn
      try { $b2.pat.Invoke() } catch { return @{ ok = $false; detail = "threw: $($_.Exception.Message)" } }
      Start-Sleep -Milliseconds 300
      $n1 = (Get-AppState).btn
      return @{ ok = ($n1 -ne $n0); detail = "app btn '$n0' -> '$n1'" }
    }
    'setvalue' {
      if (-not $preEdit) { return @{ missing = $true; ok = $false; detail = 'ValuePattern absent' } }
      $e2 = Get-UiaForChild $actH $editH 'setvalue'
      if (-not $e2) { return @{ ok = $false; detail = 'edit lost from UIA tree' } }
      $before = ''
      try { $before = [string]$e2.pat.Current.Value } catch { return @{ ok = $false; detail = 'value unreadable' } }
      try { $e2.pat.SetValue([string]$before + 'Q') } catch { return @{ ok = $false; detail = "threw: $($_.Exception.Message)" } }
      Start-Sleep -Milliseconds 400
      $after = (Get-AppState).edit
      # Effect is judged app-side. The UIA read-back is printed but not trusted: it was
      # measured growing leading whitespace every round on a different toolkit (pad 56 by
      # round 6), so a UIA-side equality test called a working write broken.
      return @{ ok = ($after -like '*Q*'); detail = "uia '$before' app-side '$after'" }
    }
    'wm-char' {
      $t0 = (Get-AppState).edit
      # WM_CHAR addressed at the CHILD edit, never the frame: WM_SETTEXT to a top-level window
      # once edited its TITLE and the reachability matrix scored that as a content write, which
      # would have fabricated a ~100% coverage figure. SendMessage not PostMessage: a posted
      # message can still be queued when the effect is read, reporting a live channel as dead.
      [void][CM]::SendMessageW($editH, 0x0102, [IntPtr]([int][char]'Q'), [IntPtr]::Zero)
      Start-Sleep -Milliseconds 400
      $t1 = (Get-AppState).edit
      # Q ANYWHERE, not at the end: WM_CHAR without a caret inserts at position 0 (measured:
      # abc -> Qabc), so a suffix test called a working channel dead.
      return @{ ok = ($t1 -ne $t0 -and $t1 -like '*Q*'); detail = "app '$t0' -> '$t1'" }
    }
    'wm-settext' {
      $t0 = (Get-AppState).edit
      $txt = [string]$t0 + 'Z'
      $ptr = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($txt)
      try { [void][CM]::SendMessageW($editH, 0x000C, [IntPtr]::Zero, $ptr) }
      finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
      Start-Sleep -Milliseconds 400
      $t1 = (Get-AppState).edit
      return @{ ok = ($t1 -like '*Z' -and $t1 -ne $t0); detail = "app '$t0' -> '$t1'" }
    }
    default { return @{ ok = $false; detail = "unknown channel $ch" } }
  }
}

# The 20Hz sampler record is kept even though the per-round guards use GetAsyncKeyState
# directly (which is stronger: it samples inside the action window, not the tail of a file).
# It stays because A1 requires the raw sampling sequence as evidence, not a summary -- and
# because its boot check tells us, before any round runs, whether evidence is being recorded
# at all. Without this start, Stop-WpmSampler below would have thrown and the record would
# not exist, which is the same class of silent-instrument failure this file keeps meeting.
$samp = Start-WpmSampler -Hz 20 -Tag 'chanmatrix'
if (-not $samp.ok) { throw "sampler failed to record (bootBytes=$($samp.bootBytes))" }
"sampler: out=$($samp.out) bootBytes=$($samp.bootBytes)"

$rows = @()
foreach ($ch in $Channels) {
  for ($r = 1; $r -le $Rounds; $r++) {
    # PRECONDITION first, before any guard sampling: measuring the control arm from a state the
    # action arm left behind would compare an arm that started in the background against one
    # that started in the foreground, and that difference manufactures the result.
    $bg0 = Ensure-TargetBackground($actH)
    if ($bg0) {
      $rows += [pscustomobject]@{ channel = $ch; round = $r; usable = $false; effect = $false
        raised = $false; tookTarget = $false; missing = $false; resetFailed = $true
        mouseDownSeen = $false; chordDownSeen = $false; cursorInTargetSeen = $false
        fg0 = ''; fg1 = ''; cursor0 = ''; cursor1 = ''; detail = ''; why = $bg0 }
      continue
    }
    $mouse = $false; $chord = $false; $inRect = $false
    for ($k = 0; $k -lt 8; $k++) {
      if ([CM]::MouseDown()) { $mouse = $true }
      if ([CM]::ChordKeyDown()) { $chord = $true }
      if ([CM]::CursorInRect($actH)) { $inRect = $true }
      Start-Sleep -Milliseconds $SampleEveryMs
    }
    $f0 = [CM]::Focus(); $cx0 = [CM]::Cursor()
    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $res = Invoke-Channel $ch
    for ($k = 0; $k -lt $ActionWindowSamples; $k++) {
      if ([CM]::MouseDown()) { $mouse = $true }
      if ([CM]::ChordKeyDown()) { $chord = $true }
      if ([CM]::CursorInRect($actH)) { $inRect = $true }
      Start-Sleep -Milliseconds $SampleEveryMs
    }
    $f1 = [CM]::Focus(); $cx1 = [CM]::Cursor()
    $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    # Restore IMMEDIATELY, in both arms, so the next round of either arm starts identically.
    $bg1 = Ensure-TargetBackground($actH)
    $clean = (-not $mouse) -and (-not $chord) -and (-not $inRect)
    $usable = $clean -and (-not $bg1) -and (-not $res.missing) -and ($ch -eq 'none' -or $res.ok)
    $why = if (-not $clean) {
      $ps = @(); if ($mouse) { $ps += 'mouse' }; if ($chord) { $ps += 'chord' }; if ($inRect) { $ps += 'cursorInRect' }
      'human mechanism: ' + ($ps -join '+')
    } elseif ($bg1) { 'post-action reset refused: ' + $bg1
    } elseif ($res.missing) { 'channel absent on this toolkit/client'
    } elseif (-not $res.ok) { 'action had no verified effect' } else { '' }
    $rows += [pscustomobject]@{ channel = $ch; round = $r; usable = $usable; effect = [bool]$res.ok
      raised = ($f1 -ne $f0); tookTarget = (([string]$f1 -split '/')[0] -eq $actH.ToString())
      missing = [bool]$res.missing; resetFailed = [bool]$bg1
      mouseDownSeen = $mouse; chordDownSeen = $chord; cursorInTargetSeen = $inRect
      fg0 = $f0; fg1 = $f1; cursor0 = $cx0; cursor1 = $cx1; t0 = $t0; t1 = $t1
      detail = $res.detail; why = $why }
    Start-Sleep -Milliseconds 250
  }
}

$stopped = Stop-WpmSampler -S $samp
''
"sample rows=$($stopped.rows.Count) stoppedCleanly=$($stopped.graceful)"
''
$rows | ForEach-Object {
  if (-not $_.usable) { "  $($_.channel) r$($_.round) DISCARDED ($($_.why)) $($_.detail)" }
  elseif ($_.channel -eq 'none') { "  none r$($_.round) tookTarget=$($_.tookTarget) fg=$($_.fg0)->$($_.fg1)" }
  else { "  $($_.channel) r$($_.round) $($_.detail) tookTarget=$($_.tookTarget) raised=$($_.raised) fg=$($_.fg0)->$($_.fg1) cursor=$($_.cursor0)->$($_.cursor1)" }
}
''
$noneU = @($rows | Where-Object { $_.channel -eq 'none' -and $_.usable }).Count
$baseTook = @($rows | Where-Object { $_.channel -eq 'none' -and $_.usable -and $_.tookTarget }).Count
$baseRate = if ($noneU) { $baseTook / $noneU } else { -1 }
$resetFails = @($rows | Where-Object { $_.resetFailed }).Count
$missingN = @($rows | Where-Object { $_.missing }).Count
"BASE (no call at all): usable=$noneU spontaneouslyTookForeground=$baseTook/$noneU"
"reset refused in $resetFails rounds; channel absent in $missingN rounds"
''
$report = @()
foreach ($ch in ($Channels | Where-Object { $_ -ne 'none' })) {
  $u = @($rows | Where-Object { $_.channel -eq $ch -and $_.usable })
  $d = @($rows | Where-Object { $_.channel -eq $ch -and -not $_.usable })
  $n = $u.Count
  $took = @($u | Where-Object { $_.tookTarget }).Count
  $raised = @($u | Where-Object { $_.raised }).Count
  $cur = @($u | Where-Object { $_.cursor0 -ne $_.cursor1 }).Count
  $eff = @($u | Where-Object { $_.effect }).Count
  $miss = @($rows | Where-Object { $_.channel -eq $ch -and $_.missing }).Count
  $rate = if ($n) { $took / $n } else { -1 }
  # RATE AND COUNT, not count alone: an earlier draft compared `$raised -gt $baseRaised` across
  # different denominators, so one hit in three action rounds beat zero in ten control rounds
  # and convicted a channel on a single sample. Conviction needs 2+ hits AND a rate gap these
  # sample sizes can carry; anything narrower is INCONCLUSIVE, which is a result.
  $verdict = if ($miss -ge $Rounds) { 'ABSENT ON THIS TOOLKIT' }
    elseif ($n -lt 3) { 'COULD NOT TELL (too few usable)' }
    elseif ($took -ge 2 -and $rate -ge $baseRate + 0.5) { 'RAISES ITS WINDOW' }
    elseif ($took -eq 0) { 'never took foreground' }
    else { 'INCONCLUSIVE (separation too small)' }
  $report += [pscustomobject]@{ channel = $ch; usable = $n; discarded = $d.Count; effectOk = $eff
    raised = $raised; tookTarget = $took; tookPct = $(if ($n) { [Math]::Round(100 * $rate) } else { '' })
    cursorMoved = $cur; verdict = $verdict }
}
$report | Format-Table -AutoSize | Out-String -Width 200
$discAll = @($rows | Where-Object { -not $_.usable })
$byWhy = @{}
foreach ($d in $discAll) { $k = if ($d.why) { $d.why } else { 'other' }; if (-not $byWhy.ContainsKey($k)) { $byWhy[$k] = 0 }; $byWhy[$k]++ }
if ($byWhy.Count) { 'discarded by cause:'; foreach ($k in $byWhy.Keys) { "  $k : $($byWhy[$k])" } }
''
$tellable = @($report | Where-Object { $_.usable -ge 3 })
$raising = @($report | Where-Object { $_.verdict -eq 'RAISES ITS WINDOW' })
$neutral = @($report | Where-Object { $_.verdict -eq 'never took foreground' })
$absent = @($report | Where-Object { $_.verdict -eq 'ABSENT ON THIS TOOLKIT' })
# ORDER IS THE FINDING. Every wrong output this instrument has produced came from a branch
# order that let a null speak: "NO channel is neutral" printed from an empty control arm, and
# "R2 is supported across every channel" printed while the table hid 11 rounds whose
# precondition failed. Instrument failure, then insufficient data, then conclusions.
if ($instrumentBad) {
  'OVERALL: INSTRUMENT INVALID (see RESET CONTROL) -- the background precondition could not be ' +
  'demonstrated, so no verdict of any kind may be taken from this run.'
} elseif ($resetFails -gt 0) {
  "OVERALL: PRECONDITION NOT MAINTAINABLE -- $resetFails rounds could not be returned to the " +
  'background. A channel measured while its window already held the foreground was never ' +
  'tested for a raise, so this run supports neither "raises" nor "neutral".'
} elseif ($noneU -lt 3 -or $tellable.Count -lt 1) {
  "OVERALL: NO CONCLUSION -- $noneU usable control rounds and $($tellable.Count) of " +
  "$($report.Count) channels reached 3 usable. Fix the instrument and re-run; do NOT carry a " +
  'verdict out of this output.'
} elseif ($neutral.Count -eq 0) {
  'OVERALL: no channel was foreground-neutral against a base of ' + "$baseTook/$noneU. R2 as " +
  'written is not achievable with these channels on this toolkit.'
} elseif ($raising.Count -eq 0 -and $absent.Count -eq 0) {
  "OVERALL: no tested channel raised beyond its base rate ($baseTook/$noneU). R2 holds across " +
  'every channel measured on this toolkit.'
} else {
  # Built as named strings rather than one inline concatenation: the previous version nested
  # $(if ...) inside a + chain, an unbalanced paren several levels deep landed the parser's
  # complaint forty lines away from the mistake, and the run cost 400ms at the gate rather
  # than ten minutes of setup.
  $neutralList = ($neutral | ForEach-Object { $_.channel }) -join ', '
  $raisingList = ($raising | ForEach-Object { $_.channel }) -join ', '
  $absentNote = ''
  if ($absent.Count) {
    $absentList = ($absent | ForEach-Object { $_.channel }) -join ', '
    $absentNote = " (absent on this toolkit/client: $absentList)"
  }
  'OVERALL: R2 holds ONLY for ' + $neutralList + '. The engine must restrict itself to those ' +
  'and refuse ' + $raisingList + $absentNote + ' -- which inverts R2.2, because the channel ' +
  'the plan preferred is the disruptive one. Coverage of the neutral channels decides whether ' +
  'that is still a product: neutral-coverage-census.ps1.'
}

try { Set-Content -LiteralPath $wfExit -Value 'exit' -Force } catch { }
Start-Sleep -Milliseconds 900
try { Stop-Process -Id $wfProc.Id -Force -ErrorAction Stop } catch { }
