# channel-raise-matrix.ps1 — which input channels raise their target window?
#
# WHY THIS IS THE G0-DECIDING MEASUREMENT. invoke-raise-check.ps1 convicted UIA Invoke: 12/12
# action rounds raised the target against 0/12 control rounds with no call at all, cursor
# never moving. That single result does not kill R2, and does not save it -- R2.2 names TWO
# channels, "UIA pattern, then target-window messages". The claim survives only if the
# message channel does not raise, and it only matters if the message channel exists on the
# targets that dominate this desktop. So the question becomes a matrix, per channel:
#
#   invoke      UIA InvokePattern.Invoke                 (click)
#   setvalue    UIA ValuePattern.SetValue                (text)
#   wm-char     PostMessage WM_CHAR to a child edit      (classic message door)
#   wm-settext  PostMessage WM_SETTEXT to a child edit   (classic message door)
#   none        no call at all -- the control arm
#
# METHOD, IDENTICAL FOR EVERY CELL. The same settle, the same guard sampling (mouse button
# down / Alt-Ctrl-Win chord down / cursor inside the target rect), the same measurement
# duration, with the control arm interleaved round by round. A channel is convicted only when
# its raise rate exceeds the control arm's measured base rate; "no raise observed" is never
# by itself a pass, because on this desktop the control arm IS the null distribution.
#
# TARGETS ARE WINDOWS THIS SCRIPT LAUNCHES: a WPF window (UIA-native, no child HWNDs -- the
# generation where the message door has nowhere to be addressed) and a WinForms window (real
# Edit child windows -- the generation where it does). A third window holds the foreground and
# reclaims it on request, so every action is taken against a window in the BACKGROUND.
#
# WHY BOTH TARGETS MATTER TOGETHER. If invoke/setvalue raise and wm-char does not, then R2 is
# true only where a classic message door exists, which the census says is the minority of
# modern toolkits -- the RM-3 pseudo-gap G0 was built to detect. That is what this run reads
# out, cell by cell.
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
  // Only the declarations this file actually calls. The first draft also declared
  // GetWindowTextW against a placeholder delegate type (`public delegate void
  // StringBuilderT();`) that Add-Type compiled without complaint -- a signature that can
  // never return the text it claims to read, which is how a message channel ends up
  // addressing a window it never verified. Anything unreadable here must fail to compile,
  // not fail silently at call time.

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
    POINT p; if (!GetCursorPos(out p)) return true;
    RC r; if (!GetWindowRect(h, out r)) return true;
    return p.x >= r.l && p.x <= r.r && p.y >= r.t && p.y <= r.b;
  }
  public static string Rect(IntPtr h) {
    RC r; if (!GetWindowRect(h, out r)) return "unreadable";
    return r.l + "," + r.t + "," + r.r + "," + r.b;
  }
}
'@

# Child-window enumeration is done in PowerShell rather than the C# block above: the first
# draft declared GetWindowTextW against a placeholder delegate type and the compile accepted
# it, which is how a message channel ends up addressing a window it never read.
function Get-EditChildren([IntPtr]$parent) {
  $code = @'
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
    EnumChildWindows(delegate (IntPtr h, IntPtr l) {
      StringBuilder cn = new StringBuilder(512); GetClassNameW(h, cn, cn.Capacity);
      StringBuilder tx = new StringBuilder(512); GetWindowTextW(h, tx, tx.Capacity);
      string c = cn.ToString();
      if (c.IndexOf("EDIT", StringComparison.OrdinalIgnoreCase) >= 0 || c == "RichEditD2DPT" ||
          c.IndexOf("RichEdit", StringComparison.OrdinalIgnoreCase) >= 0)
        acc.Add(h.ToInt64() + "\t" + c + "\t" + tx.ToString() + "\t" + IsWindowVisible(h));
      return true;
    }, IntPtr.Zero);
    return acc;
  }
}
'@
  Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
  if (-not ('CH' -as [type])) {
    # Add-Type refuses to redefine an existing type in the same session; reuse the cached one.
    return [CH]::Edits($parent)
  }
  return [CH]::Edits($parent)
}

# ---- text helpers for the message channel, defined BEFORE anything calls them. These
# functions live at script scope, so a call placed earlier in the file resolves to nothing
# and fails mid-experiment rather than at parse time -- the parse gate cannot see it and a
# 10-minute run dies after its first cell.
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

function Get-EditChildren([IntPtr]$parent) {
  # Child-window enumeration is done here rather than in the CM block above: the first draft
  # declared GetClassNameW with an IntPtr buffer and would have returned garbage class names,
  # which is a compile-clean, run-dirty way to address the wrong window.
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

# ---- windows under test and the foreground holder ----
$wpfExit = Join-Path $env:TEMP ('wpm-cm-wpf-' + [guid]::NewGuid().ToString('N') + '.stop')
$wpfProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'wpf-target.ps1'), '-HoldMs', '600000', '-ExitFile', "`"$wpfExit`"" -PassThru
$grabExit = Join-Path $env:TEMP ('wpm-cm-grab-' + [guid]::NewGuid().ToString('N') + '.stop')
$grabReGrab = Join-Path $env:TEMP ('wpm-cm-regrab-' + [guid]::NewGuid().ToString('N'))
$grabProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '600000', '-ExitFile', "`"$grabExit`"",
  '-Title', 'WpmHolderTarget', '-X', '1000', '-Y', '60', '-GrabFgAfterMs', '1500', '-ReGrabFile', "`"$grabReGrab`"" -PassThru
$wfExit = Join-Path $env:TEMP ('wpm-cm-wf-' + [guid]::NewGuid().ToString('N') + '.stop')
$wfProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '600000', '-ExitFile', "`"$wfExit`"",
  '-Title', 'WpmMsgTarget', '-X', '1000', '-Y', '430' -PassThru

$wpf = $null; $grab = $null; $wf = $null
for ($i = 0; $i -lt 80 -and (-not $wpf -or -not $grab -or -not $wf); $i++) {
  Start-Sleep -Milliseconds 400
  if (-not $wpf) { $wpf = Find-Win 'WpmWpfTarget' }
  if (-not $grab) { $grab = Find-Win 'WpmHolderTarget' }
  if (-not $wf) { $wf = Find-Win 'WpmMsgTarget' }
}
if (-not $wpf) { throw 'WPF target never appeared' }
if (-not $grab) { throw 'foreground holder never appeared' }
if (-not $wf) { throw 'message-channel target never appeared' }
$wpfH = [IntPtr]$wpf.hwnd; $grabH = [IntPtr]$grab.hwnd; $wfH = [IntPtr]$wf.hwnd
"wpf (UIA door only):  hwnd=$wpfH rect=$([CM]::Rect($wpfH))"
"winforms(msg door):   hwnd=$wfH rect=$([CM]::Rect($wfH))"
"holder:              hwnd=$grabH rect=$([CM]::Rect($grabH))"

$edits = @(Get-EditChildren $wfH)
"winforms edit children: $($edits.Count) :: $(($edits | ForEach-Object { (($_ -split '\t')[1]) }) -join ', ')"
$editLine = @($edits | Where-Object { (($_ -split '\t')[3]) -eq 'True' } | Select-Object -First 1)
# $script:editH, not $editH: the channel functions below run inside script blocks and a
# plain variable would not be visible to them, leaving the message door addressing handle 0.
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
  try { Set-Content -LiteralPath $grabReGrab -Value 'x' -Force } catch { }
  $settled = $false
  for ($i = 0; $i -lt 25 -and -not $settled; $i++) {
    if (([CM]::Fg()) -eq $grabH.ToString()) { $settled = $true } else { Start-Sleep -Milliseconds 300 }
  }
  try { Remove-Item -LiteralPath $grabReGrab -Force -ErrorAction SilentlyContinue } catch { }
  return $settled
}

function Guard-Sample([int]$count, [IntPtr]$rectH, [ref]$mouse, [ref]$chord, [ref]$inRect) {
  for ($k = 0; $k -lt $count; $k++) {
    if ([CM]::MouseDown()) { $mouse.Value = $true }
    if ([CM]::ChordKeyDown()) { $chord.Value = $true }
    if ([CM]::CursorInRect($rectH)) { $inRect.Value = $true }
    Start-Sleep -Milliseconds $SampleEveryMs
  }
}

function First-Line([string]$t) {
  # The WinForms RichTextBox holds 'rich-abc' plus a trailing newline in some builds, and an
  # exact string compare against that would report a working write as broken. The effect test
  # only needs the first line, so the trim happens in one named place.
  if ($null -eq $t) { return '' }
  return (($t -split "`r")[0] -split "`n")[0]
}

function Invoke-Channel([string]$ch) {
  # Returns @{ ok; detail; err }. Effect verification happens HERE, per channel, so a cell can
  # never report "no raise" for a call that did nothing -- which is A1 without A2, the
  # self-deception TS-3 exists to block.
  switch ($ch) {
    'none' { return @{ ok = $true; detail = 'control: no call' } }
    'invoke' {
      $b2 = Get-WpfControl $wpfH 'button'
      if (-not $b2) { return @{ ok = $false; err = 'button not resolvable' } }
      try { $b2.bp.Invoke() } catch { return @{ ok = $false; err = $_.Exception.Message } }
      Start-Sleep -Milliseconds 120
      $b3 = Get-WpfControl $wpfH 'button'
      $n1 = if ($b3) { $b3.name } else { 're-read-failed' }
      $eff = ($n1 -ne $b2.name)
      return @{ ok = $eff; detail = "name '$($b2.name)' -> '$n1'"; err = $(if (-not $eff) { 'name unchanged' } else { '' }) }
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
      $eff = ($after -eq ([string]$before + 'Q'))
      try { $e2.vp.SetValue([string]$before) } catch { }
      $d = "value '$before' -> '$after'"
      return @{ ok = $eff; detail = $d; err = $(if (-not $eff) { 'value not written as expected' } else { '' }) }
    }
    'wm-char' {
      $t0 = First-Line (Get-WfText)
      # WM_CHAR to the CHILD edit, never the frame: WM_SETTEXT addressed at a top-level window
      # once edited its TITLE and the reachability matrix scored that as a content write,
      # which would have fabricated a ~100% coverage figure. The handle here comes from
      # EnumChildWindows filtered to edit classes, and the effect is read back from the same
      # child, so a write that landed anywhere else cannot pass.
      [void][CM]::SendMessageW($script:editH, 0x0102, [IntPtr]([int][char]'Q'), [IntPtr]::Zero)
      Start-Sleep -Milliseconds 150
      $t1 = First-Line (Get-WfText)
      $eff = ($t1 -like '*Q*')
      $d = "text '$t0' -> '$t1'"
      return @{ ok = $eff; detail = $d; err = $(if (-not $eff) { 'Q not visible in the edit' } else { '' }) }
    }
    'wm-settext' {
      $t0 = First-Line (Get-WfText)
      $txt = [string]$t0 + 'Z'
      $ptr = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($txt)
      try { [void][CM]::SendMessageW($script:editH, 0x000C, [IntPtr]::Zero, $ptr) }
      finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
      Start-Sleep -Milliseconds 150
      $t1 = First-Line (Get-WfText)
      $eff = ($t1 -like '*Z')
      $d = "text '$t0' -> '$t1'"
      return @{ ok = $eff; detail = $d; err = $(if (-not $eff) { 'Z not visible in the edit' } else { '' }) }
    }
    default { return @{ ok = $false; err = "unknown channel $ch" } }
  }
}

$rows = @()
foreach ($ch in $Channels) {
  for ($r = 1; $r -le $Rounds; $r++) {
    if (-not (Settle-Holder)) {
      $rows += [pscustomobject]@{ channel = $ch; round = $r; usable = $false; effect = $false
        raised = $false; tookTarget = $false; mouseDownSeen = $false; chordDownSeen = $false
        cursorInTargetSeen = $false; fg0 = ''; fg1 = ''; cursor0 = ''; cursor1 = ''
        detail = ''; why = 'holder never became foreground' }
      continue
    }
    # The rect the guards watch is the TARGET being acted on, which differs per channel:
    # UIA channels act on the WPF window, message channels act on the WinForms one.
    $rectH = if ($ch -in @('wm-char', 'wm-settext')) { $wfH } else { $wpfH }
    $mouse = $false; $chord = $false; $inRect = $false
    Guard-Sample 8 $rectH ([ref]$mouse) ([ref]$chord) ([ref]$inRect)
    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $f0 = [CM]::Focus(); $cx0 = [CM]::Cursor()
    $res = Invoke-Channel $ch
    Guard-Sample $ActionWindowSamples $rectH ([ref]$mouse) ([ref]$chord) ([ref]$inRect)
    $f1 = [CM]::Focus(); $cx1 = [CM]::Cursor()
    $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $clean = (-not $mouse) -and (-not $chord) -and (-not $inRect)
    # A control round needs no effect, only cleanliness. An action round needs BOTH: a round
    # where the call failed tells us nothing about disturbance, and counting it as "no raise"
    # is exactly the A1-without-A2 self-deception.
    $usable = $clean -and ($ch -eq 'none' -or $res.ok)
    $why = if (-not $clean) {
      $p = @(); if ($mouse) { $p += 'mouse' }; if ($chord) { $p += 'chord' }; if ($inRect) { $p += 'cursorInRect' }
      'human mechanism: ' + ($p -join '+')
    } elseif (-not $res.ok) { 'action had no verified effect: ' + $res.err } else { '' }
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
  if (-not $_.usable) { "  $($_.channel) r$($_.round) DISCARDED ($($_.why))" }
  else { "  $($_.channel) r$($_.round) raised=$($_.raised) tookTarget=$($_.tookTarget) fg=$($_.fg0)->$($_.fg1) cursor=$($_.cursor0)->$($_.cursor1) $($_.detail)" }
}
''
$none = @($rows | Where-Object { $_.channel -eq 'none' -and $_.usable })
$baseRaised = @($none | Where-Object { $_.raised }).Count
"BASE (none): usable=$($none.Count) raised=$baseRaised/$($none.Count)"
''
$report = @()
foreach ($ch in ($Channels | Where-Object { $_ -ne 'none' })) {
  $u = @($rows | Where-Object { $_.channel -eq $ch -and $_.usable })
  $d = @($rows | Where-Object { $_.channel -eq $ch -and -not $_.usable })
  $raised = @($u | Where-Object { $_.raised }).Count
  $took = @($u | Where-Object { $_.tookTarget }).Count
  $cur = @($u | Where-Object { $_.cursor0 -ne $_.cursor1 }).Count
  $eff = @($u | Where-Object { $_.effect }).Count
  $report += [pscustomobject]@{
    channel = $ch; usable = $u.Count; discarded = $d.Count; effectOk = $eff
    raised = $raised; tookTarget = $took; cursorMoved = $cur
    verdict = $(if ($u.Count -lt 3) { 'COULD NOT TELL (too few usable)' }
      elseif ($raised -gt $baseRaised) { 'RAISES THE WINDOW' }
      else { 'no raise beyond base rate' })
  }
}
$report | Format-Table -AutoSize | Out-String -Width 200
''
foreach ($x in $report) {
  if ($x.verdict -eq 'RAISES THE WINDOW') {
    "$($x.channel): raised $($x.raised)/$($x.usable) against a control base of $baseRaised/$($none.Count) => the channel itself changes the foreground."
  } elseif ($x.usable -ge 3) {
    "$($x.channel): raised $($x.raised)/$($x.usable), base $baseRaised => indistinguishable from the desktop doing nothing; effect verified in $($x.effectOk)/$($x.usable)."
  }
}
''
$raising = @($report | Where-Object { $_.verdict -eq 'RAISES THE WINDOW' })
$neutral = @($report | Where-Object { $_.usable -ge 3 -and $_.verdict -eq 'no raise beyond base rate' })
if ($neutral.Count -eq 0) {
  'OVERALL: NO channel tested is foreground-neutral beyond the control base rate. R2 as written ' +
  '(hwnd-targeted actions that never change the foreground) is not achievable on this desktop ' +
  'with these channels, and the plan must go to the RM-3 branch rather than continue.'
} elseif ($raising.Count -eq 0) {
  'OVERALL: no tested channel raised beyond base rate. R2 is supported across every channel here.'
} else {
  'OVERALL: R2 holds ONLY for the neutral channels listed above. The engine must therefore ' +
  'restrict itself to those channels and refuse the rest -- which turns R2.2 (UIA pattern ' +
  'FIRST, messages second) on its head, since the preferred channel is the disruptive one. ' +
  'Coverage of the neutral channels is what decides whether that is still a product: see the ' +
  'toolkit census and the reachability matrix.'
}

foreach ($e in @($wpfExit, $grabExit, $wfExit)) { try { Set-Content -LiteralPath $e -Value 'exit' -Force } catch { } }
Start-Sleep -Milliseconds 900
foreach ($p in @($wpfProc, $grabProc, $wfProc)) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
