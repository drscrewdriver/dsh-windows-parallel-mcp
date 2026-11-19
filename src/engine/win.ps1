# win.ps1 -- the IO half of the R2' engine: probe a target's doors, act through the cheapest
# door it has, and put the owner's focus back when the action cost them a flash.
#
# Layering is deliberate. decide.ps1 owns every judgement (pure, unit-tested). This file owns
# every syscall and no judgement: it reports facts, and it executes what it is told. When a
# behaviour is wrong, the question is then 'was the fact wrong or the table wrong', and those
# live in different files with different tests.
#
# WHAT THIS FILE REFUSES TO DO, because the stance predates the code:
#   * no SendInput / keybd_event / mouse_event -- no physical injection, not even as a fallback
#   * no forged Alt key to defeat the foreground lock (it works; it also drops the owner's next
#     keystroke into whichever window the trick raised)
#   * no acting on a window this process did not create, UNLESS it was named as the target by
#     hwnd -- and the restore path only ever reverses an activation this process caused
#
# All coordinates crossing this boundary are SCREEN pixels. Client-space conversion happens only
# at the moment a message is posted to a child window, because lParam for WM_LBUTTONDOWN is
# child-relative and getting that wrong clicks the title bar instead of the control.

Set-StrictMode -Version 2.0

Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('WpmWin' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class WpmWin
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO
    {
        public uint cbSize; public uint flags; public IntPtr hwndActive; public IntPtr hwndFocus;
        public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize;
        public IntPtr hwndCaret; public RECT rcCaret;
    }

    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint to, bool join);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO gti);

    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageStrW(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);

    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr ChildWindowFromPointEx(IntPtr h, POINT p, uint flags);
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);

    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO l);
    [DllImport("kernel32.dll")] static extern ulong GetTickCount64();

    public const int SW_MINIMIZE = 6;
    public const int SW_SHOWNA = 8;
    public const int SW_RESTORE = 9;

    public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassNameW(h, s, s.Capacity); return s.ToString(); }
    public static string Txt(IntPtr h) { var s = new StringBuilder(1024); GetWindowTextW(h, s, s.Capacity); return s.ToString(); }
    public static string Fg() { return GetForegroundWindow().ToInt64().ToString(); }
    public static IntPtr FgHandle() { return GetForegroundWindow(); }
    public static string Cursor() { POINT p; GetCursorPos(out p); return p.X + "," + p.Y; }
    public static uint PidOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
    public static IntPtr Root(IntPtr h) { IntPtr r = GetAncestor(h, 2); return r == IntPtr.Zero ? h : r; }

    public static List<long> Children(IntPtr parent)
    {
        var acc = new List<long>();
        EnumChildWindows(parent, delegate (IntPtr h, IntPtr l) { if (IsWindowVisible(h)) acc.Add(h.ToInt64()); return true; }, IntPtr.Zero);
        return acc;
    }

    // Age of the last physical input, in ms; -1 when the call fails. Callers must treat -1 as
    // UNKNOWN rather than as 'idle' -- counting unknown as idle is how a software-caused change
    // gets laundered into 'the owner was away'.
    public static long LastInputAgeMs()
    {
        LASTINPUTINFO i = new LASTINPUTINFO();
        i.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref i)) return -1;
        uint now = (uint)(GetTickCount64() & 0xFFFFFFFF);
        return (long)((now - i.dwTime) & 0xFFFFFFFF);
    }

    // hwndActive / hwndFocus for the foreground thread. hwndFocus is the CONTROL inside the
    // window; that distinction is what makes 'the window came back' testable separately from
    // 'the caret came back'.
    public static long[] GuiFocusOfForeground()
    {
        GUITHREADINFO g = new GUITHREADINFO();
        g.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
        IntPtr fg = GetForegroundWindow();
        uint pid; uint tid = GetWindowThreadProcessId(fg, out pid);
        if (!GetGUIThreadInfo(tid, ref g)) return new long[] { 0, 0, 0 };
        return new long[] { g.hwndActive.ToInt64(), g.hwndFocus.ToInt64(), (long)tid };
    }

    // Restore the foreground to a window we previously took it from. Joins the input queue of the
    // thread that OWNS THE CURRENT foreground (the documented unlock) rather than of the window
    // being restored to -- the earlier failure in this repo was joining the wrong one and
    // concluding the door was locked.
    public static string RestoreForeground(IntPtr want)
    {
        IntPtr cur = GetForegroundWindow();
        uint pid; uint tid = GetWindowThreadProcessId(cur, out pid);
        bool joined = AttachThreadInput(GetCurrentThreadId(), tid, true);
        bool ok = false;
        try { ok = SetForegroundWindow(want); }
        finally { if (joined) AttachThreadInput(GetCurrentThreadId(), tid, false); }
        Thread.Sleep(40);
        return (ok ? "true" : "false") + "|" + (joined ? "true" : "false") + "|" + GetForegroundWindow().ToInt64();
    }

    // Click a child control by POSTING mouse messages inside it. lParam is child-relative, which
    // is why the conversion happens here and not at the call site.
    public static string MessageClick(IntPtr child, int screenX, int screenY)
    {
        POINT p = new POINT(); p.X = screenX; p.Y = screenY;
        if (!ScreenToClient(child, ref p)) return "convert-failed";
        IntPtr lp = (IntPtr)((p.Y * 0x10000) + (p.X & 0xFFFF));
        SendMessageW(child, 0x0201, (IntPtr)1, lp);
        Thread.Sleep(30);
        SendMessageW(child, 0x0202, IntPtr.Zero, lp);
        return "ok|" + p.X + "," + p.Y;
    }

    public static string MessageText(IntPtr child, string text, bool replace)
    {
        if (!replace)
        {
            for (int i = 0; i < text.Length; i++) SendMessageW(child, 0x0102, (IntPtr)text[i], IntPtr.Zero);
            return "char|" + text.Length;
        }
        SendMessageStrW(child, 0x000C, IntPtr.Zero, text);
        return "settext|" + text.Length;
    }
}
'@
}

$script:WpmUia = $null
function Get-WpmUiaCached {
  # Each pattern type is resolved independently and a missing one is simply absent from the table.
  # The first version built the table in one literal, and on this runtime
  # [System.Windows.Automation.LegacyIAccessiblePattern] does not exist -- so the constructor threw,
  # the table came back empty, every target reported 'no pattern', and the engine refused windows
  # that demonstrably had patterns. One optional identifier took the whole engine down because the
  # lookup was all-or-nothing. Now a missing type costs only that type.
  if (-not $script:WpmUia) {
    $t = @{}
    $map = @{
      invoke = 'System.Windows.Automation.InvokePattern'
      value  = 'System.Windows.Automation.ValuePattern'
      toggle = 'System.Windows.Automation.TogglePattern'
      select = 'System.Windows.Automation.SelectionItemPattern'
      legacy = 'System.Windows.Automation.LegacyIAccessiblePattern'
      range  = 'System.Windows.Automation.RangeValuePattern'
    }
    foreach ($k in $map.Keys) {
      try {
        # Resolve against the assemblies already loaded by Add-Type -AssemblyName above. Probing
        # by assembly-qualified name failed here because the assembly's simple name is not what
        # GetType expects, and guessing names is how a resolver turns into a silent 'type not
        # found'. Asking the loaded assemblies what they actually contain cannot guess wrong.
        $ty = $null
        foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
          try { $ty = $asm.GetType($map[$k]); } catch { $ty = $null }
          if ($ty) { break }
        }
        if ($ty) {
          # Pattern is a public static FIELD on these classes, not a property. Asking only for a
          # property returned $null for every pattern and produced 'no identifiers resolved' -- the
          # same shape of mistake as reading an empty field as evidence.
          $v = $null
          $pr = $ty.GetProperty('Pattern')
          if ($pr) { $v = $pr.GetValue($null) }
          if (-not $v) {
            $fl = $ty.GetField('Pattern')
            if ($fl) { $v = $fl.GetValue($null) }
          }
          if ($v) { $t[$k] = $v }
        }
      } catch { }
    }
    if ($t.Count -eq 0) { throw 'no UIA pattern identifiers resolved; the automation client is unusable' }
    $script:WpmUia = $t
  }
  return $script:WpmUia
}

function Get-WpmFamily([IntPtr]$Hwnd, [string]$Cls) {
  # Family decides which door is even possible, so it is measured from the class name rather than
  # guessed from the title: a title is the user's text, a class is the toolkit's identity.
  if ($Cls -like 'CASCADIA_HOSTING_WINDOW_CLASS*') { return 'terminal' }
  if ($Cls -like 'WindowsForms10*') { return 'winforms' }
  if ($Cls -like 'HwndWrapper*') { return 'wpf' }
  if ($Cls -eq 'ApplicationFrameWindow' -or $Cls -eq 'Windows.UI.Core.CoreWindow') { return 'uwp' }
  if ($Cls -like 'Chrome_WidgetWin*') { return 'chromium' }
  if ($Cls -like 'Edit' -or $Cls -like 'RichEdit*' -or $Cls -eq '#32770') { return 'win32-classic' }
  return 'unknown'
}

function Get-WpmFacts {
  <#
    Measure a target's doors. Returns the hashtable decide.ps1 consumes, plus the raw handles the
    executor needs. Cached per hwnd because UIA enumeration costs hundreds of ms and a batch of 50
    clicks must not pay it 50 times -- but the cache is keyed on hwnd AND invalidated by the caller
    when the window set changes, never assumed fresh.
  #>
  param([IntPtr]$Hwnd, [string]$Action = 'click', [string]$ElementName = '', [switch]$NoCache)

  $cls = [WpmWin]::Cls($Hwnd)
  $fam = Get-WpmFamily $Hwnd $cls
  $kids = @([WpmWin]::Children($Hwnd))
  $childHandles = @()
  $doorKinds = @()
  foreach ($k in $kids) {
    $kh = [IntPtr]$k
    $kc = [WpmWin]::Cls($kh)
    if ($kc -like 'Edit' -or $kc -like 'RichEdit*' -or $kc -like 'TextBox*') { $doorKinds += 'text'; $childHandles += $kh }
    elseif ($kc -like 'Button' -or $kc -eq 'ComboBox') { $doorKinds += 'click'; $childHandles += $kh }
  }

  # An element named by the caller always gets a UIA probe, even when a message door exists: the
  # door tiers address a whole window, so 'click the Save button' cannot be expressed in them
  # without coordinates. Naming an element is how a caller asks for a specific control instead of
  # whichever one happens to be found first -- and 'first found' is not a contract, it is an
  # accident of tree order that changes between app versions.
  $hasPattern = $false
  $patKind = 'none'
  $uiaElement = $null
  $uiaErr = ''
  if ($doorKinds.Count -eq 0 -or $ElementName) {
    try {
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
      $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsEnabledProperty, $true)
      $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
      $pats = Get-WpmUiaCached
      $limit = [Math]::Min($found.Count, 200)
      for ($i = 0; $i -lt $limit; $i++) {
        $el = $found[$i]
        if ($ElementName) {
          # Match on Name or AutomationId. The two are different fields: Name is the visible label
          # (localised, may change), AutomationId is the developer's id (stable). Accepting either
          # keeps the caller from having to know which one a given app populates.
          $nm = ''; $aid = ''
          try { $nm = [string]$el.Current.Name } catch { }
          try { $aid = [string]$el.Current.AutomationId } catch { }
          if ($nm -ne $ElementName -and $aid -ne $ElementName) { continue }
        }
        foreach ($k in @('invoke', 'value', 'toggle', 'select', 'legacy')) {
          if (-not $pats.ContainsKey($k)) { continue }
          $obj = $null
          try { if ($el.TryGetCurrentPattern($pats[$k], [ref]$obj)) { } } catch { continue }
          if ($obj) { $hasPattern = $true; $patKind = $k; $uiaElement = $el; break }
        }
        if ($hasPattern) { break }
      }
    } catch {
      # NOT swallowed. A silent catch here made the probe report 'no pattern' on a target that
      # demonstrably had one, and the engine then refused a perfectly reachable window -- with no
      # diagnostic anywhere. The error travels out with the facts so a refusal can say why.
      $uiaErr = $_.Exception.Message
    }
  }

  # Elevated-target detection is deliberately absent rather than faked. A correct check needs a
  # token comparison against the target process, and a WRONG check is worse than none: it would
  # either refuse ordinary windows or bless an elevated one. So elevation is not claimed here; an
  # elevated target simply produces no effect, which the app-side verification step reports as
  # 'unverified' rather than as success. Writing a placeholder that always says false and then
  # trusting it downstream is how a product ends up reporting completed actions that never ran.

  $facts = New-WpmFacts -Hwnd ($Hwnd.ToInt64().ToString()) -Family $fam `
    -MessageDoor ($doorKinds.Count -gt 0) -HasPattern $hasPattern -PatternKind $patKind `
    -Action $Action -FactsMeasured $true

  return @{
    facts = $facts
    cls = $cls
    family = $fam
    childHandles = $childHandles
    doorKinds = @($doorKinds | Sort-Object -Unique)
    uiaElement = $uiaElement
    uiaErr = $uiaErr
    pid = [WpmWin]::PidOf($Hwnd)
  }
}

function Get-WpmFocusEntry {
  # The focus table entry required by R2'.4: foreground HWND, the control that holds focus, and the
  # owning thread id (needed for the input-queue join). Keyed by HWND, never by pid: on this
  # desktop ApplicationFrameHost owns every UWP frame, so pid both misses the target's own
  # CoreWindow and blames unrelated apps.
  $g = [WpmWin]::GuiFocusOfForeground()
  $fg = [WpmWin]::FgHandle()
  return @{
    fgHwnd = $fg.ToInt64().ToString()
    fgPid = ([WpmWin]::PidOf($fg)).ToString()
    activeHwnd = ([IntPtr]$g[0]).ToInt64().ToString()
    focusHwnd = ([IntPtr]$g[1]).ToInt64().ToString()
    threadId = $g[2]
    lastInputAgeMs = [WpmWin]::LastInputAgeMs()
  }
}

function Restore-WpmFocus {
  <#
    Put the foreground back, honouring the restore table. Returns the table's verdict plus what the
    syscall actually did, so 'we decided to restore' and 'it worked' stay separate numbers.
  #>
  param([hashtable]$Entry, [string]$RaisedHwnd, [string]$TargetPid, [string]$RaisedElsewhere = '', [bool]$AlreadyRestored = $false)

  # The foreground moved to a window that is NOT our target. That is never ours to reverse: either
  # the target app opened its own window (a dialog, same pid) or a third party took the focus.
  # This branch has to come first. An earlier version set RaisedHwnd to whatever held the
  # foreground after the action, so a dialog launched by the action looked like "our raised window"
  # and got restored away -- the exact failure R2'.6 exists to prevent, caught by the measurement
  # rather than by review.
  if ($RaisedElsewhere -and -not $RaisedHwnd) {
    $ep = [WpmWin]::PidOf([IntPtr][int64]$RaisedElsewhere)
    if ($TargetPid -and ("$ep" -eq "$TargetPid")) {
      return @{ restore = $false; outcome = 'skip-dialog'; setFg = ''; joined = ''; fgAfter = $RaisedElsewhere
        reason = 'the target app opened this window itself (same pid); restoring would close the dialog it just opened' }
    }
    return @{ restore = $false; outcome = 'skip-taken'; setFg = ''; joined = ''; fgAfter = $RaisedElsewhere
      reason = 'a third-party window holds the foreground; never pull it from the owner' }
  }

  $cur = [WpmWin]::FgHandle()
  $verdict = Get-WpmRestoreDecision -CurrentFg ($cur.ToInt64().ToString()) -RaisedHwnd $RaisedHwnd `
    -TargetPid $TargetPid -CurrentFgPid ([WpmWin]::PidOf($cur)).ToString() `
    -RaisedHappened ([bool]($RaisedHwnd -ne '')) -AlreadyRestored $AlreadyRestored

  $res = @{ restore = $verdict.restore; outcome = $verdict.outcome; reason = $verdict.reason
            setFg = ''; joined = ''; fgAfter = '' }

  if ($verdict.restore -and $Entry -and $Entry.fgHwnd) {
    $want = [IntPtr][int64]$Entry.fgHwnd
    if ([WpmWin]::IsWindow($want)) {
      $r = [WpmWin]::RestoreForeground($want)
      $parts = $r.Split('|')
      $res.setFg = $parts[0]; $res.joined = $parts[1]; $res.fgAfter = $parts[2]
    } else {
      # The window we would restore to no longer exists. Nothing legal is left to do: this process
      # may not move the owner's focus to a window it does not own, and the target window belongs
      # to another process. Reported so the caller can surface it instead of pretending.
      $res.outcome = 'skip-vanished'; $res.reason = 'the window that held focus before the action no longer exists'
    }
  }
  return $res
}
