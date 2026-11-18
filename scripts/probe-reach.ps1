# probe-reach.ps1 — injection-channel reachability matrix (P0 / task_4).
#
# WHY THIS EXISTS: the parallel claim (R2) only survives if hwnd-directed channels land
# on real targets. UIA patterns and PostMessage are best-effort by design: Chromium
# widgets ignore many window messages, XAML controls may expose no pattern at all, and
# elevated or secure-desktop windows reject cross-process calls outright. If the
# reachable share is small, "true parallel" is really "parallel in a few apps", and the
# product promise would be dishonest. Measure before building -- that is this file's job.
#
# SAFETY: every target window is created by the launch/resident phase of this script and
# closed by its cleanup. It never touches windows the user already had open, never sends
# Enter or hotkeys, and never calls SetForegroundWindow, SetCursorPos or SendInput.
#
# CHANNELS
#   uiA.value       ValuePattern.SetValue
#   uiA.invoke      InvokePattern.Invoke
#   msg.WM_CHAR     PostMessage WM_CHAR per char (no Enter)
#   msg.WM_SETTEXT  SendMessage WM_SETTEXT to a child control window
#   msg.click       PostMessage WM_LBUTTONDOWN+UP at a control's centre
#
# OUTCOMES
#   ok         call returned cleanly AND an observable state change was verified
#   no-effect  call returned cleanly, nothing changed (silent no-op -- the dangerous one)
#   refused    rejected or not testable this way (read-only / frame-only / exception)
#   absent     the target exposes no control this channel could be tested on
#
# POWERSHELL RULES THIS FILE HAS LEARNED THE HARD WAY (each of these, when violated,
# produced numbers that looked like findings about the apps but were findings about the
# instrument):
#   * .NET static calls need parenthesis form: [Reach]::Get($h), never [Reach]::Get $h.
#   * GetCurrentPattern takes an AutomationPattern IDENTIFIER ([ValuePattern]::Pattern).
#     Passing the Type throws MethodException; inside a try/catch that reads exactly like
#     "this element supports no patterns" and the whole matrix scores 0 reachable.
#   * InvokePattern.Invoke() takes no argument (or an int timeout), not a TimeSpan.
#   * `return ,$out` turns an EMPTY array into a length-1 outer array whose [0] is empty,
#     so .Count says 1 while [0] is falsy. Plain `return $out` with @() at call sites.
#   * Set-Content -Encoding UTF8 writes a BOM; JSON.parse then chokes. Use Write-Utf8NoBom.
#   * $pid is a read-only automatic variable -- never assign it.
param(
  [string]$Only = '',
  [ValidateSet('launch', 'act', 'cleanup', 'resident', 'all')][string]$Phase = 'all',
  [string]$TargetsFile = (Join-Path $env:USERPROFILE '.dsh\windows-parallel-mcp\targets.json'),
  [string]$ReadyFile = (Join-Path $env:TEMP 'wpm-resident-ready'),
  [string]$ActFile = (Join-Path $env:TEMP 'wpm-resident-act'),
  [string]$ResultFile = (Join-Path $env:TEMP 'wpm-resident-result.json'),
  [string]$DoneFile = (Join-Path $env:TEMP 'wpm-resident-done'),
  [ValidateSet('json', 'table')][string]$Format = 'json'
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class Reach {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags;
    public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
    public RECT rcCaret;
  }

  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, out GUITHREADINFO i);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
  [DllImport("user32.dll")] public static extern int GetWindowTextLengthW(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr dc, int index);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);

  public const uint WM_CHAR = 0x0102, WM_SETTEXT = 0x000C, WM_GETTEXT = 0x000D,
                    WM_GETTEXTLENGTH = 0x000E, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202,
                    WM_CLOSE = 0x0010;

  // "foreground/focusOwner" as one string: enough to tell whether an injection moved
  // focus, and onto which handle, without a second round-trip.
  public static string FocusNow() {
    IntPtr fg = GetForegroundWindow();
    uint pid; uint tid = GetWindowThreadProcessId(fg, out pid);
    IntPtr focus = IntPtr.Zero;
    if (tid != 0) {
      GUITHREADINFO gi = new GUITHREADINFO();
      gi.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
      if (GetGUIThreadInfo(tid, out gi)) focus = gi.hwndFocus;
    }
    return fg.ToInt64().ToString() + "/" + focus.ToInt64().ToString();
  }

  public static bool PostChar(IntPtr h, int ch) { return PostMessageW(h, WM_CHAR, (IntPtr)ch, (IntPtr)1); }
  public static int TextLen(IntPtr h) { return SendMessageW(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero).ToInt32(); }
  public static string GetTextWin32(IntPtr h) {
    int n = TextLen(h);
    if (n <= 0) return "";
    StringBuilder sb = new StringBuilder(n + 2);
    SendMessageW(h, WM_GETTEXT, (IntPtr)sb.Capacity, sb);
    return sb.ToString();
  }
  public static void SetTextWin32(IntPtr h, string s) { SendMessageW(h, WM_SETTEXT, IntPtr.Zero, s); }
  public static void Close(IntPtr h) { PostMessageW(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); }

  public static int[] ClientOf(IntPtr h, int sx, int sy) {
    POINT p = new POINT(); p.x = sx; p.y = sy;
    ScreenToClient(h, ref p);
    return new int[] { p.x, p.y };
  }

  public static double ScaleOf(IntPtr h) {
    try { uint d = GetDpiForWindow(h); if (d > 0) return d / 96.0; } catch { }
    IntPtr dc = GetDC(IntPtr.Zero);
    try { int dx = GetDeviceCaps(dc, 88); if (dx > 0) return dx / 96.0; }
    finally { ReleaseDC(IntPtr.Zero, dc); }
    return 1.0;
  }

  public class Hit {
    public string hwnd; public string cls; public string title;
    public int pid; public int x, y, w, h; public bool visible;
  }

  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);

  // Native child window tree. UIA elements expose geometry and, when they are backed by
  // a window, a NativeWindowHandle -- but message channels need the handle, so this is
  // how a cell says "I posted to <class>, not to the frame".
  public static Hit[] Children(IntPtr top) {
    List<Hit> acc = new List<Hit>();
    EnumProc cb = delegate (IntPtr h, IntPtr l) {
      StringBuilder sb = new StringBuilder(256);
      GetClassNameW(h, sb, sb.Capacity);
      int tl = GetWindowTextLengthW(h);
      string title = "";
      if (tl > 0) { StringBuilder t = new StringBuilder(tl + 2); GetWindowTextW(h, t, t.Capacity); title = t.ToString(); }
      RECT r; GetWindowRect(h, out r);
      Hit hi = new Hit();
      hi.hwnd = h.ToInt64().ToString();
      hi.cls = sb.ToString();
      hi.title = title;
      uint pid; GetWindowThreadProcessId(h, out pid);
      hi.pid = (int)pid;
      hi.x = r.l; hi.y = r.t; hi.w = r.r - r.l; hi.h = r.b - r.t;
      hi.visible = IsWindowVisible(h);
      acc.Add(hi);
      return true;
    };
    EnumChildWindows(top, cb, IntPtr.Zero);
    return acc.ToArray();
  }

  // Top-level windows for a process (or all). MainWindowHandle lies for tabbed Win11
  // Notepad and lags behind CalculatorApp launch; enumerating is the only reliable way
  // to find the window the probe is allowed to own.
  public static Hit[] TopsOf(int procId) {
    List<Hit> acc = new List<Hit>();
    EnumProc cb = delegate (IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (procId != 0 && (int)pid != procId) return true;
      StringBuilder sb = new StringBuilder(256);
      GetClassNameW(h, sb, sb.Capacity);
      int tl = GetWindowTextLengthW(h);
      string title = "";
      if (tl > 0) { StringBuilder t = new StringBuilder(tl + 2); GetWindowTextW(h, t, t.Capacity); title = t.ToString(); }
      if (string.IsNullOrEmpty(title) && !IsWindowVisible(h)) return true;
      RECT r; GetWindowRect(h, out r);
      Hit hi = new Hit();
      hi.hwnd = h.ToInt64().ToString();
      hi.cls = sb.ToString();
      hi.title = title;
      hi.pid = (int)pid;
      hi.x = r.l; hi.y = r.t; hi.w = r.r - r.l; hi.h = r.b - r.t;
      hi.visible = IsWindowVisible(h);
      acc.Add(hi);
      return true;
    };
    EnumWindows(cb, IntPtr.Zero);
    return acc.ToArray();
  }
}
'@
Set-StrictMode -Off

# ---------------------------------------------------------------------------------
# report primitives
function Write-Utf8NoBom([string]$path, [string]$text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $text, $enc)
}

function Cell([string]$target, [string]$channel, [string]$control, [string]$outcome, [string]$reason, [bool]$effect, [string]$focusBefore, [string]$focusAfter) {
  # Focus is recorded as raw before/after strings, not a boolean, because the one
  # distinction that matters is WHO owns the new focus:
  #   moved onto this target's own window  = the injection took focus (forbidden by R2.3)
  #   moved somewhere unrelated            = a human clicked elsewhere mid-cell
  $fp = ($focusAfter -split '/')[1]
  $stole = ($focusBefore -ne $focusAfter) -and $fp -and @($script:TargetHwnds).Contains($fp)
  [pscustomobject]@{
    target = $target; channel = $channel; control = $control
    outcome = $outcome; reason = $reason
    effectVerified = $effect
    focusChanged = ($focusBefore -ne $focusAfter)
    focusBefore = $focusBefore; focusAfter = $focusAfter
    stoleFocusToTarget = [bool]$stole
  }
}

function CellOf([string]$target, [string]$channel, [string]$control, [string]$outcome, [string]$reason, [bool]$effect) {
  # Static cell: no call happened, so nothing could move focus. Sample once, both sides.
  $f = [Reach]::FocusNow()
  Cell $target $channel $control $outcome $reason $effect $f $f
}

function ShortErr($e) {
  $m = if ($e.Exception -and $e.Exception.Message) { $e.Exception.Message } else { [string]$e }
  $m = $m -replace '\s+', ' '
  if ($m.Length -gt 160) { $m = $m.Substring(0, 160) }
  return $m
}

# ---------------------------------------------------------------------------------
# UIA helpers
function UiaRoot([IntPtr]$hwnd) {
  if ($hwnd -eq [IntPtr]::Zero) { return $null }
  try { return [System.Windows.Automation.AutomationElement]::FromHandle($hwnd) } catch { return $null }
}

function Native-Hwnd($el) {
  if (-not $el) { return [IntPtr]::Zero }
  try {
    $v = $el.Current.NativeWindowHandle
    if ($v -and $v -ne 0) { return [IntPtr]([int64]$v) }
  } catch { }
  return [IntPtr]::Zero
}

function Get-Val($el) {
  if (-not $el) { return $null }
  try {
    $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($vp) { return [string]$vp.Current.Value }
  } catch { }
  return $null
}

function Find-PatternElements($root, $patternId, [int]$max) {
  # Selection by supported pattern, not by control type: WinForms controls surface as bare
  # Panes under PS 5.1's default AppContext, so "first Edit" found nothing on the very
  # target built to be reachable. Return style is load-bearing (see file header).
  $out = @()
  try {
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  } catch { return @() }
  $n = $all.Count
  for ($i = 0; $i -lt $n -and $out.Count -lt $max; $i++) {
    $p = $null
    try { $p = $all[$i].GetCurrentPattern($patternId) } catch { continue }
    if ($p) { $out += $all[$i] }
  }
  return $out
}

function Pattern-Census($root, [int]$cap = 60) {
  # What the tree actually offers. When a cell says 'absent', this is the evidence that
  # separates "the app exposes nothing" from "the query was wrong".
  $h = @{ }
  try { $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) } catch { return 'census-error' }
  $n = [Math]::Min($all.Count, $cap)
  for ($i = 0; $i -lt $n; $i++) {
    try {
      foreach ($sp in $all[$i].GetSupportedPatterns()) {
        $k = ($sp.ProgrammaticName -replace 'Identifiers\.$', '' -replace '^System\.Windows\.Automation\.', '')
        if (-not $h.ContainsKey($k)) { $h[$k] = 0 }
        $h[$k] = $h[$k] + 1
      }
    } catch { }
  }
  if (-not $h.Count) { return 'none' }
  (($h.Keys | Sort-Object | ForEach-Object { "$_=$($h[$_])" }) -join ' ')
}

function Describe-Control($el, [int]$index) {
  if (-not $el) { return "elem[$index]=none" }
  $ct = '?'; $nm = ''
  try { $ct = ($el.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { }
  try { $nm = $el.Current.Name; if ($nm.Length -gt 22) { $nm = $nm.Substring(0, 22) } } catch { }
  'e'+$index+'='+$ct+"/'"+$nm+"'/native="+(Native-Hwnd $el)
}

function Parse-Rect($el) {
  try { $r = $el.Current.BoundingRectangle.ToString() } catch { return $null }
  $nums = [regex]::Matches($r, '[-0-9]+(?:\.[0-9]+)?') | ForEach-Object { [double]$_.Value }
  if ($nums.Count -lt 4) { return $null }
  $x = $nums[0]; $y = $nums[1]; $w = $nums[2]; $hh = $nums[3]
  if ($w -le 0 -or $hh -le 0) { return $null }
  return @{ x = $x; y = $y; w = $w; h = $hh; raw = $r }
}

# ---------------------------------------------------------------------------------
# target resolution
function Pick-Child([IntPtr]$top, $rc) {
  # Geometry bridge: a UIA rect centre matched to the smallest child window that contains
  # it. Tried raw, then scaled by the window's DPI -- the cell records which landed, so a
  # coordinate-space mismatch is visible instead of silent.
  if ($top -eq [IntPtr]::Zero) { return @{ hwnd = [IntPtr]::Zero; how = 'no-top'; scale = 1.0; cls = '' } }
  $hits = @([Reach]::Children($top))
  if (-not $rc) { return @{ hwnd = $top; how = 'no-geometry'; scale = 1.0; cls = '' } }
  $scale = [double]([Reach]::ScaleOf($top))
  foreach ($cand in @(@(1.0, 'raw'), @($scale, "dpi$scale"))) {
    $s = [double]$cand[0]
    $px = [int](($rc.x + $rc.w / 2) * $s); $py = [int](($rc.y + $rc.h / 2) * $s)
    $cont = @($hits | Where-Object { $_.visible -and $px -ge $_.x -and $px -lt ($_.x + $_.w) -and $py -ge $_.y -and $py -lt ($_.y + $_.h) -and $_.w -gt 0 })
    if ($cont.Count) {
      $best = $cont | Sort-Object { $_.w * $_.h } | Select-Object -First 1
      return @{ hwnd = [IntPtr]([int64]$best.hwnd); how = "point-in-child class=$($best.cls) via=$($cand[1])"; scale = $s; cls = $best.cls }
    }
  }
  return @{ hwnd = $top; how = 'no-child-at-point'; scale = 1.0; cls = '' }
}

function Pick-InputWindow([IntPtr]$top, [IntPtr]$uiaHwnd) {
  # Message target chosen by window CLASS, because the class is what decides whether WM_*
  # can be handled at all. A fallback to the frame is reported, never used to fake a hit.
  if ($top -eq [IntPtr]::Zero) { return @{ hwnd = [IntPtr]::Zero; how = 'no-top'; cls = '' } }
  $hits = @([Reach]::Children($top))
  if ($uiaHwnd -ne [IntPtr]::Zero -and $uiaHwnd.ToInt64() -ne $top.ToInt64()) {
    $m = $hits | Where-Object { $_.hwnd -eq $uiaHwnd.ToString() } | Select-Object -First 1
    if ($m) { return @{ hwnd = $uiaHwnd; how = "uia-handle class=$($m.cls)"; cls = $m.cls } }
    return @{ hwnd = $uiaHwnd; how = 'uia-handle-not-in-child-tree'; cls = '?' }
  }
  foreach ($w in 'Edit', 'RichEdit', 'RICHEDIT50W', 'Chrome_RenderWidgetHostHWND', 'xaml_window', 'TextBox', 'ComboBox') {
    $m = $hits | Where-Object { $_.visible -and $_.w -gt 0 -and $_.cls -like "*$w*" } | Sort-Object { $_.w * $_.h } | Select-Object -First 1
    if ($m) { return @{ hwnd = [IntPtr]([int64]$m.hwnd); how = "class-match $w"; cls = $m.cls } }
  }
  return @{ hwnd = $top; how = 'no-input-class-child'; cls = '' }
}

# ---------------------------------------------------------------------------------
# channels
function Test-UiaValue($target, $el, $label) {
  if (-not $el) { return (CellOf $target 'uiA.value' $label 'absent' 'no element' $false) }
  $before = Get-Val $el
  $f0 = [Reach]::FocusNow()
  try {
    $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if (-not $vp) { return (CellOf $target 'uiA.value' $label 'refused' 'ValuePattern unsupported' $false) }
    if ($vp.Current.IsReadOnly) { return (CellOf $target 'uiA.value' $label 'refused' 'ValuePattern.IsReadOnly=true' $false) }
    $vp.SetValue([string]$before + 'Q')
  } catch {
    return (Cell $target 'uiA.value' $label 'refused' ('exception: ' + (ShortErr $_)) $false $f0 ([Reach]::FocusNow()))
  }
  $after = Get-Val $el
  $effect = ($null -ne $after -and $after -ne $before)
  try { if ($effect) { $vp.SetValue([string]$before) } } catch { }
  $why = if ($effect) { "value '$before' -> '$after'" } elseif ($null -eq $after) { 'no readable value' } else { "value unchanged ('$before')" }
  return (Cell $target 'uiA.value' $label $(if ($effect) { 'ok' } else { 'no-effect' }) $why $effect $f0 ([Reach]::FocusNow()))
}

function Test-UiaInvoke($target, $el, $label) {
  if (-not $el) { return (CellOf $target 'uiA.invoke' $label 'absent' 'no element' $false) }
  $f0 = [Reach]::FocusNow()
  $bName = ''; try { $bName = $el.Current.Name } catch { $bName = '<err>' }
  $bVal = Get-Val $el
  try {
    $ip = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if (-not $ip) { return (CellOf $target 'uiA.invoke' $label 'refused' 'InvokePattern unsupported' $false) }
    $ip.Invoke()
  } catch {
    return (Cell $target 'uiA.invoke' $label 'refused' ('exception: ' + (ShortErr $_)) $false $f0 ([Reach]::FocusNow()))
  }
  Start-Sleep -Milliseconds 220
  $aName = ''; try { $aName = $el.Current.Name } catch { $aName = '<err>' }
  $aVal = Get-Val $el
  $effect = ($aName -ne $bName) -or ($aVal -ne $bVal)
  $why = if ($effect) { "'$bName/$bVal' -> '$aName/$aVal'" } else { "no observable state delta on '$bName'" }
  return (Cell $target 'uiA.invoke' $label $(if ($effect) { 'ok' } else { 'no-effect' }) $why $effect $f0 ([Reach]::FocusNow()))
}

function Test-WmChar($target, [IntPtr]$top, [IntPtr]$child, $el, $label, [string]$text) {
  $f0 = [Reach]::FocusNow()
  $h = $child
  if ($h.ToInt64() -eq $top.ToInt64()) {
    return (Cell $target 'msg.WM_CHAR' $label 'refused' 'target is the top-level frame: WM_GETTEXTLENGTH there reports the title, so a length delta would prove nothing about content' $false $f0 ([Reach]::FocusNow()))
  }
  $beforeLen = [Reach]::TextLen($h)
  $beforeVal = Get-Val $el
  foreach ($ch in $text.ToCharArray()) {
    if (-not [Reach]::PostChar($h, [int]$ch)) {
      return (Cell $target 'msg.WM_CHAR' $label 'refused' 'PostMessageW(WM_CHAR) returned false' $false $f0 ([Reach]::FocusNow()))
    }
    Start-Sleep -Milliseconds 15
  }
  Start-Sleep -Milliseconds 300
  $afterLen = [Reach]::TextLen($h)
  $afterVal = Get-Val $el
  $effect = ($afterLen -ne $beforeLen) -or ($null -ne $afterVal -and $afterVal -ne $beforeVal)
  $why = "textlen $beforeLen -> $afterLen; uia '$beforeVal' -> '$afterVal'"
  return (Cell $target 'msg.WM_CHAR' $label $(if ($effect) { 'ok' } else { 'no-effect' }) $why $effect $f0 ([Reach]::FocusNow()))
}

function Test-WmSetText($target, [IntPtr]$top, [IntPtr]$child, $label, [string]$text) {
  $f0 = [Reach]::FocusNow()
  $h = $child
  if ($h.ToInt64() -eq $top.ToInt64()) {
    # WM_SETTEXT on the frame renames its TITLE. Scoring that as a content write would
    # fabricate a 100% reach rate for every window on the desktop -- this exact trap
    # produced the first matrix's "ok" on all five targets.
    return (Cell $target 'msg.WM_SETTEXT' $label 'refused' 'target is the top-level frame: WM_SETTEXT there edits the title, not content' $false $f0 ([Reach]::FocusNow()))
  }
  $before = [Reach]::GetTextWin32($h)
  [Reach]::SetTextWin32($h, ($before + $text))
  Start-Sleep -Milliseconds 200
  $after = [Reach]::GetTextWin32($h)
  $effect = $after -ne $before
  if ($effect) { [Reach]::SetTextWin32($h, $before) }
  return (Cell $target 'msg.WM_SETTEXT' $label $(if ($effect) { 'ok' } else { 'no-effect' }) "text '$before' -> '$after'" $effect $f0 ([Reach]::FocusNow()))
}

function Test-WmClick($target, $el, [IntPtr]$top, [IntPtr]$child, $label, [double]$scale = 1.0) {
  if (-not $el) { return (CellOf $target 'msg.click' $label 'absent' 'no element' $false) }
  $rc = Parse-Rect $el
  if (-not $rc) { return (CellOf $target 'msg.click' $label 'absent' 'no usable bounding rect' $false) }
  if ($child.ToInt64() -eq $top.ToInt64()) {
    return (CellOf $target 'msg.click' $label 'refused' 'click target resolved to the frame; coordinates there land on window chrome, not the control' $false)
  }
  $f0 = [Reach]::FocusNow()
  $bName = ''; try { $bName = $el.Current.Name } catch { }
  $bVal = Get-Val $el
  $sx = [int](($rc.x + $rc.w / 2) * $scale); $sy = [int](($rc.y + $rc.h / 2) * $scale)
  $cl = [Reach]::ClientOf($child, $sx, $sy)
  $lc = [int]$cl[0]; $tc = [int]$cl[1]
  if ($lc -lt 0 -or $tc -lt 0) {
    return (Cell $target 'msg.click' $label 'absent' "client point ($lc,$tc) invalid from screen ($sx,$sy)" $false $f0 ([Reach]::FocusNow()))
  }
  $lparam = [IntPtr](($tc -shl 16) -bor ($lc -band 0xFFFF))
  [void][Reach]::PostMessageW($child, [Reach]::WM_LBUTTONDOWN, [IntPtr]1, $lparam)
  Start-Sleep -Milliseconds 60
  [void][Reach]::PostMessageW($child, [Reach]::WM_LBUTTONUP, [IntPtr]0, $lparam)
  Start-Sleep -Milliseconds 350
  $aName = ''; try { $aName = $el.Current.Name } catch { }
  $aVal = Get-Val $el
  $effect = ($aName -ne $bName) -or ($aVal -ne $bVal)
  $why = if ($effect) { "'$bName/$bVal' -> '$aName/$aVal'" } else { "WM_LBUTTON* at client ($lc,$tc), no state delta" }
  return (Cell $target 'msg.click' $label $(if ($effect) { 'ok' } else { 'no-effect' }) $why $effect $f0 ([Reach]::FocusNow()))
}

# ---------------------------------------------------------------------------------
# targets we own
$script:opened = @()
function Register($o) { $script:opened += $o }

function Snapshot-Tops {
  $h = @{ }
  foreach ($t in @([Reach]::TopsOf(0))) { $h[[string]$t.hwnd] = $t }
  return $h
}

function Wait-NewWindow($before, [scriptblock]$match, [int]$timeoutSec = 12) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    foreach ($t in @([Reach]::TopsOf(0))) {
      if ($before.ContainsKey([string]$t.hwnd)) { continue }
      if (-not $t.visible) { continue }
      if (& $match $t) { return $t }
    }
    Start-Sleep -Milliseconds 300
  }
  return $null
}

function Test-Big($t) { return ($t.w * $t.h) -gt 20000 }

function New-WinFormsBaseline {
  # Positive control: classic Win32 Edit/Button child windows. If channels fail HERE, the
  # instrument is broken and no other cell in the matrix says anything about its app.
  $wf = Join-Path $PSScriptRoot 'winforms-target.ps1'
  $exit = Join-Path $env:TEMP ('wpm-wf-' + [guid]::NewGuid().ToString('N') + '.stop')
  $before = Snapshot-Tops
  $p = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $wf, '-HoldMs', '180000', '-ExitFile', "`"$exit`"" -PassThru
  Register @{ kind = 'process'; pid = $p.Id }
  Register @{ kind = 'file'; path = $exit }
  $t = Wait-NewWindow $before { param($w) $w.title -like '*WpmWinFormsTarget*' } 15
  if ($t) { Register @{ kind = 'window'; hwnd = [IntPtr]([int64]$t.hwnd) } }
  @{ id = 'winforms-baseline'; role = 'positive control'; hwnd = $(if ($t) { [IntPtr]([int64]$t.hwnd) } else { [IntPtr]::Zero }); cls = $(if ($t) { $t.cls } else { '' }) }
}

function New-Notepad {
  $before = Snapshot-Tops
  Start-Process notepad | Out-Null
  $t = Wait-NewWindow $before { param($w) (Test-Big $w) -and $w.title -and $w.cls -match 'Notepad' } 14
  if (-not $t) { $t = Wait-NewWindow $before { param($w) (Test-Big $w) -and $w.title } 6 }
  if ($t) { Register @{ kind = 'window'; hwnd = [IntPtr]([int64]$t.hwnd) } }
  @{ id = 'win32-notepad'; role = 'text editor'; hwnd = $(if ($t) { [IntPtr]([int64]$t.hwnd) } else { [IntPtr]::Zero }); cls = $(if ($t) { $t.cls } else { '' }) }
}

function New-Calc {
  $before = Snapshot-Tops
  Start-Process 'calculator:' | Out-Null
  $t = Wait-NewWindow $before { param($w) $w.cls -match 'ApplicationFrameHost|Calculator|WinUIDesktop' -and $w.title -and (Test-Big $w) } 14
  if ($t) { Register @{ kind = 'window'; hwnd = [IntPtr]([int64]$t.hwnd) } }
  @{ id = 'winui-calc'; role = 'modern XAML app'; hwnd = $(if ($t) { [IntPtr]([int64]$t.hwnd) } else { [IntPtr]::Zero }); cls = $(if ($t) { $t.cls } else { '' }) }
}

function New-Explorer {
  $dir = Join-Path $env:TEMP ('wpm-reach-' + (Get-Date -Format 'HHmmss'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Register @{ kind = 'dir'; path = $dir }
  $before = Snapshot-Tops
  Start-Process explorer -ArgumentList "`"$dir`"" | Out-Null
  $leaf = Split-Path $dir -Leaf
  $t = Wait-NewWindow $before { param($w) $w.cls -eq 'CabinetWClass' -or ($w.title -like "*$leaf*") } 12
  if ($t) { Register @{ kind = 'window'; hwnd = [IntPtr]([int64]$t.hwnd) } }
  @{ id = 'shell-explorer'; role = 'file manager'; hwnd = $(if ($t) { [IntPtr]([int64]$t.hwnd) } else { [IntPtr]::Zero }); cls = $(if ($t) { $t.cls } else { '' }) }
}

function New-Chromium {
  # A data: URL with a single <input>: something honest to write into, no navigation, no
  # third-party side effect reachable from it.
  $url = 'data:text/html,<title>WpmReachProbe</title><body style="font:16px sans-serif"><h3>reach</h3><input id=k value=abc style="width:280px;font-size:20px">'
  $before = Snapshot-Tops
  Start-Process msedge -ArgumentList @('--new-window', '--no-first-run', "`"$url`"") | Out-Null
  $t = Wait-NewWindow $before { param($w) $w.cls -match 'Chrome_WidgetWin' -and $w.title -like '*WpmReachProbe*' } 20
  if ($t) { Register @{ kind = 'window'; hwnd = [IntPtr]([int64]$t.hwnd) } }
  @{ id = 'chromium-edge'; role = 'Chromium web input'; hwnd = $(if ($t) { [IntPtr]([int64]$t.hwnd) } else { [IntPtr]::Zero }); cls = $(if ($t) { $t.cls } else { '' }) }
}

function New-Console {
  $before = Snapshot-Tops
  $p = Start-Process powershell -ArgumentList '-NoExit', '-NoProfile', '-Command', "`$Host.UI.RawUI.WindowTitle='WpmReachConsole'`"" -PassThru
  Register @{ kind = 'process'; pid = $p.Id }
  $t = Wait-NewWindow $before { param($w) $w.title -like '*WpmReachConsole*' } 12
  if (-not $t) {
    $own = @([Reach]::TopsOf($p.Id)) | Where-Object { $_.visible -and $_.title } | Sort-Object { $_.w * $_.h } -Descending | Select-Object -First 1
    if ($own) { $t = $own }
  }
  if ($t) { Register @{ kind = 'window'; hwnd = [IntPtr]([int64]$t.hwnd) } }
  @{ id = 'console-host'; role = 'terminal'; hwnd = $(if ($t) { [IntPtr]([int64]$t.hwnd) } else { [IntPtr]::Zero }); cls = $(if ($t) { $t.cls } else { '' }) }
}

function Get-AllTargets {
  @(
    New-WinFormsBaseline
    New-Notepad
    New-Calc
    New-Explorer
    New-Chromium
    New-Console
  )
}

# ---------------------------------------------------------------------------------
# act: one implementation, used by every phase that injects
function Invoke-Act([IntPtr[]]$ignore = $null) {
  $targets = Get-Targets
  $cells = @()
  $diag = @()
  foreach ($t in $targets) {
    if ($Only -and ($Only -split ',') -notcontains $t.id) { continue }
    $script:TargetHwnds = @()
    if ($t.hwnd -eq [IntPtr]::Zero) { $cells += (CellOf $t.id '-' 'window' 'absent' 'window handle never appeared' $false); continue }
    if (-not [Reach]::IsWindow($t.hwnd)) { $cells += (CellOf $t.id '-' 'window' 'absent' 'hwnd is no longer a window (target died before the measured window)' $false); continue }
    $root = UiaRoot $t.hwnd
    if (-not $root) { $cells += (CellOf $t.id '-' 'window' 'refused' 'AutomationElement.FromHandle returned null (UIA blocked or elevated target)' $false); continue }

    $childWins = @([Reach]::Children($t.hwnd))
    # Handle set for focus attribution: frame plus every child window of THIS target.
    $script:TargetHwnds = @((@($childWins | ForEach-Object { $_.hwnd }) + @($t.hwnd.ToString())) | Select-Object -Unique)

    $valueEls = @(Find-PatternElements $root ([System.Windows.Automation.ValuePattern]::Pattern) 3)
    $invokeEls = @(Find-PatternElements $root ([System.Windows.Automation.InvokePattern]::Pattern) 3)
    $classes = (@($childWins | ForEach-Object { $_.cls } | Select-Object -Unique)) -join '/'
    $diag += [ordered]@{
      target = $t.id; cls = $t.cls; hwnd = $t.hwnd.ToString()
      childWindows = $childWins.Count; childClasses = $classes
      valuePatternEls = $valueEls.Count; invokePatternEls = $invokeEls.Count
      patternCensus = (Pattern-Census $root 60)
    }

    $editEl = if ($valueEls.Count) { $valueEls[0] } else { $null }
    if ($editEl) { $cells += Test-UiaValue $t.id $editEl (Describe-Control $editEl 0) }
    else { $cells += (CellOf $t.id 'uiA.value' 'tree' 'absent' "no ValuePattern element in descendants (child classes: $classes)" $false) }

    $btn = if ($invokeEls.Count) { $invokeEls[0] } else { $null }
    if ($btn) { $cells += Test-UiaInvoke $t.id $btn (Describe-Control $btn 0) }
    else { $cells += (CellOf $t.id 'uiA.invoke' 'tree' 'absent' 'no InvokePattern element in descendants' $false) }

    $pw = Pick-InputWindow $t.hwnd $(if ($editEl) { Native-Hwnd $editEl } else { [IntPtr]::Zero })
    $cells += Test-WmChar $t.id $t.hwnd $pw.hwnd $editEl $pw.how 'reach'
    $cells += Test-WmSetText $t.id $t.hwnd $pw.hwnd $pw.how 'QQ'

    if ($btn) {
      $nat = Native-Hwnd $btn
      $bp = if ($nat -ne [IntPtr]::Zero -and $nat.ToInt64() -ne $t.hwnd.ToInt64()) { @{ hwnd = $nat; how = 'uia-native-hwnd'; scale = 1.0 } } else { Pick-Child $t.hwnd (Parse-Rect $btn) }
      $cells += Test-WmClick $t.id $btn $t.hwnd $bp.hwnd $bp.how $bp.scale
    } else {
      # No InvokePattern element: still test the message channel, but observe state on the
      # element bound to the child window itself, so a click's effect is readable.
      $btnWin = $childWins | Where-Object { $_.visible -and $_.cls -match 'Button' } | Select-Object -First 1
      if ($btnWin) {
        $bEl = $null
        try { $bEl = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([int64]$btnWin.hwnd)) } catch { }
        if ($bEl) { $cells += Test-WmClick $t.id $bEl $t.hwnd ([IntPtr]([int64]$btnWin.hwnd)) "class=$($btnWin.cls)" 1.0 }
        else { $cells += (CellOf $t.id 'msg.click' "class=$($btnWin.cls)" 'refused' 'button-class child window found but has no UIA element to observe' $false) }
      } else {
        $cells += (CellOf $t.id 'msg.click' 'tree' 'absent' 'no InvokePattern element and no button-class child window' $false)
      }
    }
  }

  $ok = @($cells | Where-Object { $_.outcome -eq 'ok' }).Count
  $noEffect = @($cells | Where-Object { $_.outcome -eq 'no-effect' }).Count
  $refused = @($cells | Where-Object { $_.outcome -eq 'refused' }).Count
  $absent = @($cells | Where-Object { $_.outcome -eq 'absent' }).Count
  $actionable = $ok + $noEffect + $refused
  $base = @($cells | Where-Object { $_.target -eq 'winforms-baseline' })
  $baseOk = @($base | Where-Object { $_.outcome -eq 'ok' }).Count

  [ordered]@{
    phase = 'act'
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    cells = $cells
    treeDiag = $diag
    summary = [ordered]@{
      ok = $ok; noEffect = $noEffect; refused = $refused; absent = $absent; actionable = $actionable
      okRatePct = $(if ($actionable) { [math]::Round(100 * $ok / $actionable, 1) } else { 0 })
      # The positive control gates the whole number: if WinForms is not reachable, this
      # matrix measures nothing and its rate must not be quoted.
      baselineOk = $baseOk; baselineCells = @($base).Count
      instrumentTrusted = ($baseOk -ge 2)
      writeOkRatePct = $(
        $w = @($cells | Where-Object { $_.channel -in 'uiA.value', 'msg.WM_CHAR', 'msg.WM_SETTEXT' -and $_.outcome -ne 'absent' })
        $wo = @($w | Where-Object { $_.outcome -eq 'ok' })
        if ($w.Count) { [math]::Round(100 * $wo.Count / $w.Count, 1) } else { 0 }
      )
      clickOkRatePct = $(
        $c = @($cells | Where-Object { $_.channel -in 'uiA.invoke', 'msg.click' -and $_.outcome -ne 'absent' })
        $co = @($c | Where-Object { $_.outcome -eq 'ok' })
        if ($c.Count) { [math]::Round(100 * $co.Count / $c.Count, 1) } else { 0 }
      )
      focusChangedCells = @($cells | Where-Object { $_.focusChanged }).Count
      focusTakenCells = @($cells | Where-Object { $_.stoleFocusToTarget }).Count
      okWithFocusTaken = @($cells | Where-Object { $_.outcome -eq 'ok' -and $_.stoleFocusToTarget }).Count
    }
  } | ConvertTo-Json -Depth 6
}

# ---------------------------------------------------------------------------------
# phases
function Get-Targets {
  if (-not (Test-Path -LiteralPath $TargetsFile)) { throw "no targets.json at $TargetsFile -- run --phase launch (or resident) first" }
  $j = Get-Content -LiteralPath $TargetsFile -Raw -Encoding UTF8 | ConvertFrom-Json
  @($j.targets | ForEach-Object { @{ id = $_.id; role = $_.role; hwnd = [IntPtr]([int64]$_.hwnd); cls = $_.cls } })
}

function Save-Targets($targets) {
  $dir = Split-Path $TargetsFile -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $payload = [ordered]@{
    launchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    targets = @($targets | ForEach-Object { [ordered]@{ id = $_.id; role = $_.role; hwnd = $_.hwnd.ToString(); cls = $_.cls } })
    opened = @($script:opened | ForEach-Object {
      $o = [ordered]@{ kind = $_.kind }
      if ($_.hwnd) { $o.hwnd = $_.hwnd.ToString() }
      if ($_.pid) { $o.pid = $_.pid }
      if ($_.path) { $o.path = $_.path }
      $o
    })
  }
  Write-Utf8NoBom $TargetsFile ($payload | ConvertTo-Json -Depth 5)
  return $payload
}

function Cleanup-Opened {
  $list = @($script:opened)
  [array]::Reverse($list)
  $n = 0
  foreach ($o in $list) {
    try {
      if ($o.kind -eq 'window' -and $o.hwnd -ne [IntPtr]::Zero) {
        if ([Reach]::IsWindow($o.hwnd)) { [Reach]::Close($o.hwnd); $n++; Start-Sleep -Milliseconds 250 }
      } elseif ($o.kind -eq 'process') {
        # Kill only processes this script spawned (console, WinForms host). Never a shared
        # browser or shell process, which may already hold the user's own windows.
        Stop-Process -Id $o.pid -Force -ErrorAction SilentlyContinue; $n++
      } elseif ($o.kind -eq 'dir') {
        Remove-Item -LiteralPath $o.path -Recurse -Force -ErrorAction SilentlyContinue; $n++
      } elseif ($o.kind -eq 'file') {
        # Ask the WinForms host to close itself: touching its exit flag is the handshake.
        Set-Content -LiteralPath $o.path -Value 'exit' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
        Remove-Item -LiteralPath $o.path -Force -ErrorAction SilentlyContinue; $n++
      }
    } catch { }
  }
  return $n
}

function Do-Launch {
  $script:opened = @()
  $payload = Save-Targets (Get-AllTargets)
  $payload | ConvertTo-Json -Depth 5
}

function Do-Cleanup {
  if (-not (Test-Path -LiteralPath $TargetsFile)) { [ordered]@{ cleaned = 0; error = 'no targets file' } | ConvertTo-Json; return }
  $j = Get-Content -LiteralPath $TargetsFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $script:opened = @($j.opened | ForEach-Object {
    $o = @{ kind = $_.kind }
    if ($_.hwnd) { $o.hwnd = [IntPtr]([int64]$_.hwnd) }
    if ($_.pid) { $o.pid = [int]$_.pid }
    if ($_.path) { $o.path = [string]$_.path }
    $o
  })
  $n = Cleanup-Opened
  [ordered]@{ cleaned = $n; targetsFile = $TargetsFile } | ConvertTo-Json
}

function Do-Resident {
  # One process holds every target window open while the external driver sequences the
  # measurement. This exists because the shell wrapper on this host kills a command's
  # whole process tree when the command exits: a target created by a separate launch
  # command is gone before any act command can touch it, and a vanished window scores as
  # 'absent' -- the same code as 'this app ignores PostMessage'. Those mean opposite
  # things, so the holder must be long-lived and signalled by files.
  #   ReadyFile  written when targets exist  -> driver may start the sampler
  #   ActFile    touched by driver            -> we inject, write ResultFile
  #   ResultFile our act JSON                 -> driver stops the sampler
  #   DoneFile   touched by driver            -> we clean up and exit
  $script:opened = @()
  $payload = Save-Targets (Get-AllTargets)
  Set-Content -LiteralPath $ReadyFile -Value (Get-Date).ToUniversalTime().ToString('o') -Encoding ASCII

  $deadline = (Get-Date).AddSeconds(240)
  while (-not (Test-Path -LiteralPath $ActFile)) {
    if ((Get-Date) -gt $deadline) { break }
    Start-Sleep -Milliseconds 120
  }
  $actJson = if (Test-Path -LiteralPath $ActFile) { Invoke-Act } else { '{"phase":"act","error":"act file never appeared"}' }
  Write-Utf8NoBom $ResultFile $actJson

  $deadline2 = (Get-Date).AddSeconds(180)
  while (-not (Test-Path -LiteralPath $DoneFile)) {
    if ((Get-Date) -gt $deadline2) { break }
    Start-Sleep -Milliseconds 120
  }
  $n = Cleanup-Opened
  [ordered]@{ phase = 'resident'; cleaned = $n; targets = $payload.targets.Count } | ConvertTo-Json
}

if ($Phase -eq 'launch') { Do-Launch; return }
if ($Phase -eq 'act') { Invoke-Act; return }
if ($Phase -eq 'cleanup') { Do-Cleanup; return }
if ($Phase -eq 'resident') { Do-Resident; return }

# 'all': single-process convenience run for interactive use. Its measured window includes
# the launches themselves, so its focus numbers are not the ones the verdict quotes -- the
# verdict path is resident (driver-sequenced), and this is here for quick manual checks.
$script:opened = @()
$allTargets = Get-AllTargets
Save-Targets $allTargets
Invoke-Act
$n = Cleanup-Opened
[ordered]@{ phase = 'all'; cleaned = $n; note = 'interactive convenience run; use the driver (resident phase) for the verdict' } | ConvertTo-Json
