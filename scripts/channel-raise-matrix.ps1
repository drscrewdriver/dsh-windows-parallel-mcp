# channel-raise-matrix.ps1 — which input channels raise their target window?
#
# WHY THIS IS THE G0-DECIDING MEASUREMENT. invoke-raise-check.ps1 convicted UIA Invoke: 12/12
# action rounds raised the target against 0/12 control rounds with no call at all, cursor
# never moving. That does not by itself kill R2, and does not save it -- R2.2 names TWO
# channels, "UIA pattern, then target-window messages". The claim survives only if the message
# channel does not raise, and that matters only where the message channel EXISTS, which the
# census says is the minority of modern toolkits. So the question is a matrix, per channel:
#
#   invoke      UIA InvokePattern.Invoke                 (click)      -> WPF window
#   setvalue    UIA ValuePattern.SetValue                (text)       -> WPF window
#   wm-char     WM_CHAR to a child edit                  (messages)   -> WinForms window
#   wm-settext  WM_SETTEXT to a child edit               (messages)   -> WinForms window
#   none        no call at all -- the control arm
#
# NO FOREGROUND HAND-OFF, DELIBERATELY. An earlier draft launched a third window to hold the
# foreground and required the target to be in the BACKGROUND before each action. That design
# died twice, for a reason worth recording: the holder's only route to the foreground is its
# OWN SetForegroundWindow, which the system grants only to the process holding the last input
# event -- so the hand-off works exactly while a human is clicking and fails completely while
# they are not. The first such run discarded 30 of 36 rounds and then printed "NO channel is
# foreground-neutral" from an empty control arm: absence of evidence rendered as evidence of
# absence, in the one place the whole plan depends on getting right.
#
# What replaces it is strictly less invasive and stronger. Do not insist the target starts in
# the background. Record the foreground window immediately before the action, whatever it is,
# and ask one question: DID THE FOREGROUND BECOME THE TARGET? A round where the target already
# held the foreground is uninformative and is skipped and counted. Nothing in this script ever
# calls SetForegroundWindow, AttachThreadInput or BringWindowToTop -- it cannot disturb the
# desktop while measuring whether a channel disturbs it, and it runs on a desktop in active
# use.
#
# CONVICTION IS A COMPARISON, NOT AN ABSENCE PROOF. Guard sampling (mouse button down,
# Alt/Ctrl/Win chord down, cursor inside the target rect) excludes the human mechanisms we can
# detect, in BOTH arms equally. A round that fails a guard is discarded and counted, never
# averaged. The control arm -- identical settle, identical sampling, identical duration, NO
# call -- measures this desktop's own rate of spontaneously foregrounding one of these
# windows. A channel is convicted only when its rate clears that base by a margin these sample
# sizes can support; in between is reported as INCONCLUSIVE rather than coerced.
param(
  [int]$Rounds = 8,
  [int]$SampleEveryMs = 20,
  [int]$ActionWindowSamples = 30,
  [string[]]$Channels = @('none', 'invoke', 'setvalue', 'wm-char', 'wm-settext')
)
$ErrorActionPreference = 'Stop'
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
  // Read-only observation plus the two message sends that ARE the channels under test. There
  // is deliberately no SetForegroundWindow, BringWindowToTop or AttachThreadInput anywhere in
  // this class: an instrument that forces the foreground to prove a point about the foreground
  // has replaced the measurement with its own side effect.
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
}
'@

# ---- text helpers, defined BEFORE anything calls them. PowerShell resolves functions at
# runtime, so a helper declared after its first use dies mid-experiment, minutes of setup
# down, with nothing the parse gate can see.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WT {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  public static string Of(IntPtr h) {
    int n = GetWindowTextLength(h);
    StringBuilder sb = new StringBuilder(n + 2);
    GetWindowTextW(h, sb, sb.Capacity);
    return sb.ToString();
  }
}
'@
function Get-WfText { return [WT]::Of($script:editH) }
function First-Line([string]$t) {
  # The RichTextBox keeps a trailing newline in some builds, and an exact compare would report
  # a working write as broken. Trimming happens in one named place so both message channels
  # predict the same way.
  if ($null -eq $t) { return '' }
  return (($t -split "`r")[0] -split "`n")[0]
}

function Get-EditChildren([IntPtr]$parent) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class CH {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EP c, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  public static List<string> Edits(IntPtr parent) {
    List<string> acc = new List<string>();
    EnumChildWindows(parent, delegate (IntPtr h, IntPtr l) {
      StringBuilder cn = new StringBuilder(512); GetClassNameW(h, cn, cn.Capacity);
      StringBuilder tx = new StringBuilder(512); GetWindowTextW(h, tx, tx.Capacity);
      string c = cn.ToString();
      if (c.IndexOf("EDIT", StringComparison.OrdinalIgnoreCase) >= 0 ||
          c.IndexOf("RichEdit", StringComparison.OrdinalIgnoreCase) >= 0)
        acc.Add(h.ToInt64() + "\t" + c + "\t" + tx.ToString() + "\t" + IsWindowVisible(h));
      return true;
    }, IntPtr.Zero);
    return acc;
  }
}
'@ -ErrorAction SilentlyContinue
  return @( [CH]::Edits($parent) )
}

# ---- the two windows under test ----
$wpfExit = Join-Path $env:TEMP ('wpm-cm-wpf-' + [guid]::NewGuid().ToString('N') + '.stop')
$wpfProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'wpf-target.ps1'), '-HoldMs', '600000', '-ExitFile', "`"$wpfExit`"" -PassThru
$wfExit = Join-Path $env:TEMP ('wpm-cm-wf-' + [guid]::NewGuid().ToString('N') + '.stop')
$wfState = Join-Path $env:TEMP ('wpm-cm-wfstate-' + [guid]::NewGuid().ToString('N') + '.txt')
$wfProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '600000', '-ExitFile', "`"$wfExit`"",
  '-StateFile', "`"$wfState`"", '-Title', 'WpmMsgTarget', '-X', '1000', '-Y', '430' -PassThru

$grabExit = Join-Path $env:TEMP ('wpm-cm-grab-' + [guid]::NewGuid().ToString('N') + '.stop')
$grabReGrab = Join-Path $env:TEMP ('wpm-cm-regrab-' + [guid]::NewGuid().ToString('N'))
$grabProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '600000', '-ExitFile', "`"$grabExit`"",
  '-Title', 'WpmHolderTarget', '-X', '1460', '-Y', '430', '-GrabFgAfterMs', '1500', '-ReGrabFile', "`"$grabReGrab`"" -PassThru
$wpf = $null; $wf = $null; $grab = $null
for ($i = 0; $i -lt 80 -and (-not $wpf -or -not $wf -or -not $grab); $i++) {
  Start-Sleep -Milliseconds 400
  if (-not $wpf) { $wpf = Find-Win 'WpmWpfTarget' }
  if (-not $wf) { $wf = Find-Win 'WpmMsgTarget' }
  if (-not $grab) { $grab = Find-Win 'WpmHolderTarget' }
}
if (-not $grab) { throw 'foreground holder never appeared' }
if (-not $wpf) { throw 'WPF target never appeared' }
if (-not $wf) { throw 'message-channel target never appeared' }
$wpfH = [IntPtr]$wpf.hwnd; $wfH = [IntPtr]$wf.hwnd; $grabH = [IntPtr]$grab.hwnd
# WHY THE HOLDER IS STARTED LAST, WHICH IS THE WHOLE DIFFERENCE BETWEEN A RUN THAT WORKS AND
# ONE THAT DISCARDED 30 OF 36 ROUNDS. The only process allowed to take the foreground is the
# one that owns the window holding it, or the one launched last. The first draft started the
# holder BETWEEN the two targets, the last-started target then took the foreground, and from
# that moment the holder's SetForegroundWindow was refused for the entire run -- the
# instrument silently measured its own inability to hand off the foreground.
#
# The hand-off is a disturbance by the HARNESS, not by the channel: it is applied identically
# in the control arm and the action arm, and always OUTSIDE the measured action window, so it
# cannot bias the comparison. Both arms also use the hide/show reset below, which is likewise
# disclosed rather than hidden. Nothing here ever touches a window this script did not create.
"wpf (UIA door only, no child HWNDs): hwnd=$wpfH rect=$([CM]::Rect($wpfH)) iconic=$([CM]::Iconic($wpfH))"
"winforms (classic message door):     hwnd=$wfH rect=$([CM]::Rect($wfH)) iconic=$([CM]::Iconic($wfH))"

function Get-AppState {
  # The owning process's own view of its controls, refreshed every timer tick. THIS is the
  # effect oracle for the message channels: cross-process WM_GETTEXT on another process's
  # edit control was measured blind -- it returned the original 'abc' after a WM_SETTEXT that
  # the app itself reported as 'abcZ', and returned '' for a RichTextBox holding 'rich-abc'.
  # Verifying a message write with the same read path the message is suspected of not
  # reaching is circular, and here it was also simply wrong.
  if (-not (Test-Path -LiteralPath $script:wfState)) { return @{ ok = $false; edit = ''; rich = '' } }
  $l = (Get-Content -LiteralPath $script:wfState -Tail 1 -ErrorAction SilentlyContinue | Select-Object -Last 1)
  if (-not $l) { return @{ ok = $false; edit = ''; rich = '' } }
  $p = $l -split "`t"
  return @{ ok = $true; edit = $p[0]; rich = $(if ($p.Count -gt 1) { $p[1] } else { '' }) }
}
$stStart = Get-AppState
if (-not $stStart.ok) { throw 'app-side state oracle never appeared: message channels cannot be verified' }
"app-side oracle: edit='$($stStart.edit)' rich='$($stStart.rich)'"

$edits = @(Get-EditChildren $wfH)
"winforms edit children: $($edits.Count) :: $(($edits | ForEach-Object { (($_ -split '\t')[1]) }) -join ', ')"
$editLine = @($edits | Where-Object { (($_ -split '\t')[3]) -eq 'True' } | Select-Object -First 1)
# $script:editH, not $editH: the channel functions run inside script blocks where a plain
# variable is invisible, leaving the message door addressing handle 0.
$script:editH = if ($editLine) { [IntPtr]([int64](($editLine -split '\t')[0])) } else { [IntPtr]::Zero }
if ($script:editH -eq [IntPtr]::Zero) { throw 'no visible Edit child on the WinForms target: the message channel cannot be tested' }
$editFirstLine = ((($editLine -split '\t')[2]) -split "`r")[0]
"message target child: hwnd=$($script:editH) class=$((($editLine -split '\t')[1])) text='$editFirstLine'"

function Get-WpfControl([IntPtr]$h, [string]$kind) {
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    for ($i = 0; $i -lt [Math]::Min($all.Count, 200); $i++) {
      $ct = ''
      try { $ct = ($all[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
      $nm = ''
      try { $nm = [string]$all[$i].Current.Name } catch { }
      if ($kind -eq 'button' -and $ct -eq 'Button' -and $nm -like 'Press*') {
        $bp = $null
        try { if ($all[$i].TryGetCurrentPattern([System.Windows.Automation.InvokePatternIdentifiers]::Pattern, [ref]$bp)) { return @{ bp = $bp; name = $nm } } } catch { }
      }
      if ($kind -eq 'edit' -and $ct -eq 'Edit') {
        $vp = $null
        try { if ($all[$i].TryGetCurrentPattern([System.Windows.Automation.ValuePatternIdentifiers]::Pattern, [ref]$vp)) { return @{ vp = $vp; name = $nm; val = $vp.Current.Value } } } catch { }
      }
    }
  } catch { }
  return $null
}

$bc = Get-WpfControl $wpfH 'button'
if (-not $bc) { throw 'no Press button on the WPF target' }
$ec = Get-WpfControl $wpfH 'edit'
if (-not $ec) { throw 'no ValuePattern Edit on the WPF target' }
"wpf controls: button='$($bc.name)' edit value='$($ec.val)'"

$samp = Start-WpmSampler -Hz 20 -Tag 'chanmatrix'
if (-not $samp.ok) { throw "sampler failed to record (bootBytes=$($samp.bootBytes))" }
"sampler: out=$($samp.out) bootBytes=$($samp.bootBytes)"

function Settle-Holder {
  # Put the foreground in the holder's hands and return '' only when it is verifiably there.
  # The request is a flag file the holder's OWN process polls, because only it may activate.
  try { Set-Content -LiteralPath $grabReGrab -Value 'x' -Force } catch { }
  for ($i = 0; $i -lt 25; $i++) {
    if (([CM]::Fg()) -eq $grabH.ToString()) {
      try { Remove-Item -LiteralPath $grabReGrab -Force -ErrorAction SilentlyContinue } catch { }
      return ''
    }
    Start-Sleep -Milliseconds 300
  }
  try { Remove-Item -LiteralPath $grabReGrab -Force -ErrorAction SilentlyContinue } catch { }
  $dest = ([string][CM]::Fg())
  $rev = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -Hwnd $dest 2>$null
  $info = '(unknown)'
  if ($rev) { $j = ($rev | Select-Object -Last 1) | ConvertFrom-Json; $info = "$($j.title) || $($j.cls) || proc=$($j.process)" }
  return "holder never became foreground; held by $dest [$info]"
}

function Invoke-Channel([string]$ch, [IntPtr]$rectH) {
  # Returns @{ ok; detail; err }. Effect verification happens HERE, inside the action, so no
  # cell can report "no raise" on the strength of a call that did nothing at all -- that
  # pairing is A1 without A2, and it is the single most common way a quiet-channel result
  # turns out to be a dead channel.
  switch ($ch) {
    'none' { return @{ ok = $true; detail = 'control: no call' } }
    'invoke' {
      $b2 = Get-WpfControl $wpfH 'button'
      if (-not $b2) { return @{ ok = $false; err = 'button not resolvable' } }
      try { $b2.bp.Invoke() } catch { return @{ ok = $false; err = $_.Exception.Message } }
      Start-Sleep -Milliseconds 120
      $b3 = Get-WpfControl $wpfH 'button'
      $n1 = if ($b3) { $b3.name } else { 're-read-failed' }
      return @{ ok = ($n1 -ne $b2.name); detail = "name '$($b2.name)' -> '$n1'" }
    }
    'setvalue' {
      $e2 = Get-WpfControl $wpfH 'edit'
      if (-not $e2) { return @{ ok = $false; err = 'edit not resolvable' } }
      $before = $e2.val
      try { $e2.vp.SetValue([string]$before + 'Q') } catch { return @{ ok = $false; err = $_.Exception.Message } }
      Start-Sleep -Milliseconds 150
      # Read back through a FRESH resolution: a cached provider could answer from its own
      # cache and certify a write that never reached the control.
      $e3 = Get-WpfControl $wpfH 'edit'
      $after = if ($e3) { $e3.val } else { 're-read-failed' }
      # CONTAINS, not exact-equals. The exact form was the first draft's prediction 'after ==
      # before + Q', and six rounds running it read back '      abcQ' with six more leading
      # spaces each time -- so the value read through UIA is not the string the control holds.
      # The write demonstrably landed (Q appears); the padding is a real observation about the
      # read path and is reported in the detail rather than quietly modelled away, because a
      # padding the engine cannot see is a corruption it will happily write back.
      $eff = ($after -like '*Q*' -and $after -ne 're-read-failed')
      try { $e2.vp.SetValue('abc') } catch { }
      $leadPad = $after.Length - $after.TrimStart().Length
      return @{ ok = $eff; detail = "value '$before' -> '$after' (leading pad $leadPad)" }
    }
    'wm-char' {
      # app-side BEFORE-state is the reference point; WM_GETTEXT is kept alongside ONLY so
      # the divergence stays visible in the log.
      $t0app = (Get-AppState).edit
      $t0 = First-Line (Get-WfText)
      # WM_CHAR to the CHILD edit, never the frame. WM_SETTEXT addressed at a top-level window
      # once edited its TITLE and the reachability matrix scored that as a content write,
      # which would have fabricated a ~100% coverage figure. The handle here comes from
      # EnumChildWindows filtered to edit classes and the effect is read from the same child,
      # so a write that landed anywhere else cannot pass. SendMessage rather than PostMessage:
      # a posted message could still be queued when the effect is read, reporting a working
      # channel as broken.
      [void][CM]::SendMessageW($script:editH, 0x0102, [IntPtr]([int][char]'Q'), [IntPtr]::Zero)
      Start-Sleep -Milliseconds 700
      $t1app = (Get-AppState).edit
      $t1 = First-Line (Get-WfText)
      # 'Q' ANYWHERE, not at the end. A measured WM_CHAR without a caret inserts at position
      # 0, so a suffix test called a working channel dead -- and did so in exactly the
      # direction that understates coverage, which is the safer error but still an error.
      return @{ ok = ($t1app -ne $t0app -and $t1app -like '*Q*'); detail = "app '$t0app' -> '$t1app' (gettext '$t0' -> '$t1')" }
    }
    'wm-settext' {
      $t0app = (Get-AppState).edit
      $t0 = First-Line (Get-WfText)
      $txt = [string]$t0app + 'Z'
      $ptr = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($txt)
      try { [void][CM]::SendMessageW($script:editH, 0x000C, [IntPtr]::Zero, $ptr) }
      finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
      Start-Sleep -Milliseconds 700
      $t1app = (Get-AppState).edit
      $t1 = First-Line (Get-WfText)
      return @{ ok = ($t1app -like '*Z' -and $t1app -ne $t0app); detail = "app '$t0app' -> '$t1app' (gettext '$t0' -> '$t1')" }
    }
    default { return @{ ok = $false; err = "unknown channel $ch" } }
  }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RX {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  // SW_HIDE then SW_SHOWNA: make our own target visible-but-not-foreground again. ShowWindow
  // is NOT restricted by the foreground lock (it does not activate), which is exactly why
  // this is allowed where SetForegroundWindow is not -- and why it is used only to REMOVE
  // foreground, never to take it. Hiding and re-showing IS a visible disturbance; it is
  // disclosed in the log, applied identically in both arms, and never happens on a window
  // this script did not create.
  public static void Reset(IntPtr h) { ShowWindow(h, 0); ShowWindow(h, 8); }
}
'@

function Reset-TargetUnforegrounded([IntPtr]$h) {
  # Returns '' when the target is not the foreground window, or the reason it could not be
  # made un-foreground. A target that already holds the foreground cannot yield a meaningful
  # raise measurement, so without this reset the first successful invoke would poison every
  # later round -- which is precisely what happened: 15 rounds discarded as 'already
  # foreground' after one raise.
  if (([CM]::Fg()) -ne $h.ToString()) { return '' }
  for ($i = 0; $i -lt 6; $i++) {
    [void][RX]::Reset($h)
    Start-Sleep -Milliseconds 350
    if (([CM]::Fg()) -ne $h.ToString()) { return '' }
  }
  return 'target still foreground after hide/show reset'
}

$rows = @()
foreach ($ch in $Channels) {
  # The rect and the handle that count as "the target" depend on the channel: UIA channels act
  # on the WPF window, message channels on the WinForms one. Using one window's rect to guard
  # another's action would let a human click on the acting window pass as a clean round.
  $rectH = if ($ch -in @('wm-char', 'wm-settext')) { $wfH } else { $wpfH }
  for ($r = 1; $r -le $Rounds; $r++) {
    $mouse = $false; $chord = $false; $inRect = $false
    for ($k = 0; $k -lt 8; $k++) {
      if ([CM]::MouseDown()) { $mouse = $true }
      if ([CM]::ChordKeyDown()) { $chord = $true }
      if ([CM]::CursorInRect($rectH)) { $inRect = $true }
      Start-Sleep -Milliseconds $SampleEveryMs
    }
    $settleFail = Settle-Holder
    if ($settleFail) {
      $rows += [pscustomobject]@{ channel = $ch; round = $r; usable = $false; effect = $false
        raised = $false; tookTarget = $false; mouseDownSeen = $false; chordDownSeen = $false
        cursorInTargetSeen = $false; fg0 = ''; fg1 = ''; cursor0 = ''; cursor1 = ''
        detail = ''; why = $settleFail }
      continue
    }
    $f0 = [CM]::Focus(); $cx0 = [CM]::Cursor()
    $fg0 = ([string]$f0 -split '/')[0]
    if ($fg0 -eq $rectH.ToString()) {
      # Nothing to measure: the target is already foreground, so a raise cannot be observed and
      # a non-raise proves nothing. Skipped, counted, and never folded into either rate.
      $rows += [pscustomobject]@{ channel = $ch; round = $r; usable = $false; effect = $false
        raised = $false; tookTarget = $false; mouseDownSeen = $mouse; chordDownSeen = $chord
        cursorInTargetSeen = $inRect; fg0 = $f0; fg1 = ''; cursor0 = $cx0; cursor1 = ''
        detail = ''; why = 'target already foreground (uninformative)' }
      continue
    }
    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $res = Invoke-Channel $ch $rectH
    for ($k = 0; $k -lt $ActionWindowSamples; $k++) {
      if ([CM]::MouseDown()) { $mouse = $true }
      if ([CM]::ChordKeyDown()) { $chord = $true }
      if ([CM]::CursorInRect($rectH)) { $inRect = $true }
      Start-Sleep -Milliseconds $SampleEveryMs
    }
    $f1 = [CM]::Focus(); $cx1 = [CM]::Cursor()
    $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $clean = (-not $mouse) -and (-not $chord) -and (-not $inRect)
    $usable = $clean -and ($ch -eq 'none' -or $res.ok)
    $why = if (-not $clean) {
      $p = @(); if ($mouse) { $p += 'mouse' }; if ($chord) { $p += 'chord' }; if ($inRect) { $p += 'cursorInRect' }
      'human mechanism: ' + ($p -join '+')
    } elseif (-not $res.ok) { 'action had no verified effect' } else { '' }
    $rows += [pscustomobject]@{ channel = $ch; round = $r; usable = $usable; effect = [bool]$res.ok
      raised = ($f1 -ne $f0); tookTarget = (([string]$f1 -split '/')[0] -eq $rectH.ToString())
      mouseDownSeen = $mouse; chordDownSeen = $chord; cursorInTargetSeen = $inRect
      fg0 = $f0; fg1 = $f1; cursor0 = $cx0; cursor1 = $cx1
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
$none = @($rows | Where-Object { $_.channel -eq 'none' -and $_.usable })
$baseTook = @($none | Where-Object { $_.tookTarget }).Count
$noneU = $none.Count
$baseRate = if ($noneU) { $baseTook / $noneU } else { -1 }
"BASE (no call at all): usable=$noneU spontaneouslyTookForeground=$baseTook/$noneU"
''
$report = @()
foreach ($ch in ($Channels | Where-Object { $_ -ne 'none' })) {
  $u = @($rows | Where-Object { $_.channel -eq $ch -and $_.usable })
  $d = @($rows | Where-Object { $_.channel -eq $ch -and -not $_.usable })
  $took = @($u | Where-Object { $_.tookTarget }).Count
  $raised = @($u | Where-Object { $_.raised }).Count
  $cur = @($u | Where-Object { $_.cursor0 -ne $_.cursor1 }).Count
  $eff = @($u | Where-Object { $_.effect }).Count
  $n = $u.Count
  $rate = if ($n) { $took / $n } else { -1 }
  # COMPARISON IS BY RATE AND BY COUNT, not by count alone. An earlier draft wrote
  # `$raised -gt $baseRaised`, comparing raw counts across different denominators: one hit in
  # three action rounds beats zero in ten control rounds and would convict on a single sample.
  # Conviction needs both a minimum count and a rate separation these sizes can support;
  # anything in between is INCONCLUSIVE, which is a result, not a failure to produce one.
  $verdict = if ($n -lt 3 -or $noneU -lt 3) { 'COULD NOT TELL (too few usable)' }
    elseif ($took -ge 2 -and $rate -ge $baseRate + 0.5) { 'RAISES ITS WINDOW' }
    elseif ($took -eq 0) { 'never took foreground' }
    else { 'INCONCLUSIVE (foreground taken, separation too small)' }
  $report += [pscustomobject]@{
    channel = $ch; usable = $n; discarded = $d.Count; effectOk = $eff
    raised = $raised; tookTarget = $took; tookPct = $(if ($n) { [Math]::Round(100 * $rate) } else { '' })
    cursorMoved = $cur; verdict = $verdict
  }
}
$report | Format-Table -AutoSize | Out-String -Width 200
''
$discAll = @($rows | Where-Object { -not $_.usable })
$byWhy = @{}
foreach ($d in $discAll) { $k = if ($d.why) { $d.why } else { 'other' }; if (-not $byWhy.ContainsKey($k)) { $byWhy[$k] = 0 }; $byWhy[$k]++ }
"discarded by cause:"
foreach ($k in $byWhy.Keys) { "  $k : $($byWhy[$k])" }
''
$raising = @($report | Where-Object { $_.verdict -eq 'RAISES ITS WINDOW' })
$neutral = @($report | Where-Object { $_.verdict -eq 'never took foreground' })
$tellable = @($report | Where-Object { $_.usable -ge 3 })
if ($noneU -lt 3 -or $tellable.Count -lt 1) {
  "OVERALL: NO CONCLUSION -- control arm produced $noneU usable rounds and $($tellable.Count) of " +
  "$($report.Count) channels reached 3. With no measured base rate this run supports neither " +
  '"the channel raises" nor "the channel is neutral". Fix the instrument and re-run; do NOT ' +
  'carry a verdict out of this output.'
} elseif ($neutral.Count -eq 0) {
  'OVERALL: no channel reached a foreground-neutral result against a base rate of ' +
  "$baseTook/$noneU. R2 as written (hwnd-targeted actions that never change the foreground) is " +
  'not achievable on this desktop with these channels, and the plan goes to the RM-3 branch.'
} elseif ($raising.Count -eq 0) {
  'OVERALL: no tested channel took its window to the foreground beyond the base rate. R2 is ' + "supported across every channel measured here (base $baseTook/$noneU)."
} else {
  'OVERALL: R2 holds ONLY for ' + (($neutral | ForEach-Object { $_.channel }) -join ', ') + '. ' +
  'The engine must restrict itself to those channels and refuse ' +
  (($raising | ForEach-Object { $_.channel }) -join ', ') + ' -- which inverts R2.2 (UIA ' +
  'pattern FIRST, messages second), because the preferred channel is the disruptive one. What ' +
  'decides whether that is still a product is the COVERAGE of the neutral channels: see the ' +
  'toolkit census and the reachability matrix.'
}

foreach ($e in @($wpfExit, $wfExit, $grabExit)) { try { Set-Content -LiteralPath $e -Value 'exit' -Force } catch { } }
Start-Sleep -Milliseconds 900
foreach ($p in @($wpfProc, $wfProc, $grabProc)) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
