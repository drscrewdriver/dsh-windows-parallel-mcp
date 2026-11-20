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

    // ---- integrity level: the REAL elevated_target check -------------------------------------
    // The old comment in Get-WpmFacts said this was deliberately unwired because "a wrong check is
    // worse than none". That is still true, which is why the check below is the documented,
    // side-effect-free one: OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION) -> GetTokenInformation
    // (TokenIntegrityLevel) -> the RID's last sub-authority. No writes, no SeDebug privilege, and
    // it degrades to -1 (unknown) on any failure -- unknown is NOT treated as elevated, because
    // that would refuse every window the moment a handle read failed, which is the opposite wrong
    // check. Unknown instead falls through to the door probe, and a genuinely elevated target then
    // simply produces no effect, which the app-side verification reports as unverified.
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr tok, int cls, IntPtr info, uint len, out uint need);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr h);

    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const uint TOKEN_QUERY = 0x0008;
    const int TokenIntegrityLevel = 25;

    /// <summary>Integrity RID of a pid: 0x1000 low, 0x2000 medium, 0x3000 high, 0x4000 system. -1 = unknown.</summary>
    public static long IntegrityOf(uint pid)
    {
        IntPtr proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (proc == IntPtr.Zero) return -1;
        try
        {
            IntPtr tok;
            if (!OpenProcessToken(proc, TOKEN_QUERY, out tok)) return -1;
            try
            {
                uint need;
                // Two-pass: the SIZE-PROBE call is DOCUMENTED to fail -- it returns FALSE with
                // ERROR_INSUFFICIENT_BUFFER and fills `needed`. Treating that false as a dead end
                // made every read come back unknown on the first run of test/integrity-probe.ps1,
                // which is exactly how a 'wrong check is worse than none' failure looks in the wild:
                // the flag stayed false everywhere, so nothing was refused and nothing was claimed.
                // The real condition is `needed > 0`, not the return value.
                GetTokenInformation(tok, TokenIntegrityLevel, IntPtr.Zero, 0, out need);
                if (need == 0) return -1;
                IntPtr buf = Marshal.AllocHGlobal((int)need);
                try
                {
                    if (!GetTokenInformation(tok, TokenIntegrityLevel, buf, need, out need)) return -1;
                    // TOKEN_MANDATORY_LABEL { SID_AND_ATTRIBUTES Label }; Label.Sid is at offset 0.
                    IntPtr sid = Marshal.ReadIntPtr(buf);
                    if (sid == IntPtr.Zero) return -1;
                    // SID layout: Revision(1) | SubAuthorityCount(1) | IdentifierAuthority(6) |
                    // SubAuthority(4*n). The integrity RID is the LAST sub-authority.
                    //
                    // GetLengthSid was the first attempt and is NOT used: on this host it returns
                    // TRUE with length 0 for a SID whose bytes read back correctly (revision 1,
                    // count 1, authority 0x10, RID 0x2000 = medium) -- a silent contradiction that
                    // made every read come back unknown. The length is therefore computed from the
                    // SID's own header, which is the authoritative source anyway. Two wrong
                    // behaviours this replaced, both discovered only by measuring: trusting the
                    // size-probe's return value, and trusting GetLengthSid's output.
                    int rev = Marshal.ReadByte(sid, 0);
                    int count = Marshal.ReadByte(sid, 1);
                    if (rev != 1 || count < 1 || count > 15) return -1;
                    int needed = 8 + 4 * count;
                    if (needed > (int)need) return -1;   // header claims more than the buffer holds
                    // The integrity RID is the LAST sub-authority.
                    return (long)BitConverter.ToUInt32(
                        new byte[] { Marshal.ReadByte(sid, 8 + 4 * (count - 1)),
                                     Marshal.ReadByte(sid, 9 + 4 * (count - 1)),
                                     Marshal.ReadByte(sid, 10 + 4 * (count - 1)),
                                     Marshal.ReadByte(sid, 11 + 4 * (count - 1)) }, 0);
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            finally { CloseHandle(tok); }
        }
        finally { CloseHandle(proc); }
    }

    /// <summary>Whether the target outruns us. Equal integrity is NOT elevated for our purposes.</summary>
    public static bool IsElevatedTarget(uint pid)
    {
        long mine = IntegrityOf((uint)System.Diagnostics.Process.GetCurrentProcess().Id);
        long theirs = IntegrityOf(pid);
        if (mine < 0 || theirs < 0) return false;   // unknown never claims elevated
        return theirs > mine;
    }

    // ---- overlay support: ex-styles, hotkey, and the cross-thread control board --------------
    // WpmCtl is the ONE shared state between the worker's main thread (stdin/protocol/actions)
    // and the overlay thread (WPF dispatcher, global hotkey). A PowerShell script variable is
    // not visible across runspaces, so a static holder is the honest shape; the bools are
    // volatile because the hotkey handler writes them from another thread while actions read
    // them mid-flight.
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOPMOST = 0x00000008;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WM_HOTKEY = 0x0312;
    public const int WM_CLOSE = 0x0010;
    public const uint MOD_CONTROL = 0x0002;
    public const uint MOD_ALT = 0x0001;

    [DllImport("user32.dll", SetLastError=true)] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);

    /// <summary>
    /// Declare this process DPI aware, BEFORE any window exists.
    /// Why this is not cosmetic: PowerShell starts DPI UNAWARE, so Windows virtualises every
    /// coordinate it passes to user32. The engine receives PHYSICAL screen pixels (that is what a
    /// click point is), the marker is placed through the same user32 -- and with an unaware process
    /// a target of (470,410) rendered the marker at (303,263), exactly /1.5 on this 150% display.
    /// Two components, one coordinate space, or the AI cursor points at the wrong place while every
    /// style assertion still passes. Must run before any window is created (per-process setting);
    /// returns false when the manifest already set it, which is success, not failure.
    /// </summary>
    public static bool EnsureDpiAware() {
        try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }   // PER_MONITOR_AWARE_V2
        try { return SetProcessDPIAware(); } catch { return false; }
    }

    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;

    /// <summary>
    /// Move a window in PHYSICAL pixels without activating it or changing its z-order.
    /// This exists instead of WPF's Window.Left/Top because WPF's units are device independent while
    /// every coordinate this product receives from Win32 is physical. Measured on this machine
    /// (150% display): setting Left/Top put the marker at (303,263) for a target of (470,410) -- the
    /// DIP conversion and the window's actual rendering disagreed by the scale factor, and no amount
    /// of matrix arithmetic inside the process fixes a process-wide DPI-awareness mismatch.
    /// SetWindowPos takes the same units the caller has, so there is nothing left to guess.
    /// </summary>
    public static bool MoveNoActivate(IntPtr h, int x, int y, int cx, int cy) {
        return SetWindowPos(h, IntPtr.Zero, x, y, cx, cy, SWP_NOZORDER | SWP_NOACTIVATE);
    }

    /// <summary>Add ex-style bits and return the new value (the trio lives here, once).</summary>
    public static int AddExStyles(IntPtr h, int bits) {
        int v = GetWindowLong(h, GWL_EXSTYLE);
        SetWindowLong(h, GWL_EXSTYLE, v | bits);
        return v | bits;
    }

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

if (-not ('WpmCtl' -as [type])) {
Add-Type -TypeDefinition @'
using System;
public static class WpmCtl {
    public static volatile bool Paused = false;
    public static volatile bool OverlayOn = false;
    public static volatile bool HotkeyOk = false;
    // The chord that ACTUALLY registered, not the one the docs promise: on this machine Ctrl+Alt+Q
    // is already owned by another app (RegisterHotKey -> 1409, measured in
    // scripts/hotkey-availability.ps1, 7/8 other candidates free). A silent fallback would make the
    // README's "Ctrl+Alt+Q" untrue with nothing to notice; the real chord is reported instead.
    public static string HotkeyLabel = "";
    // Marker placement travels through these fields INSTEAD of a cross-thread Dispatcher.Invoke.
    // Measured (.tmp/ov-seg.log): Invoke(priority, Action) from the worker's thread cost 1818ms and
    // sometimes never returned -- the delegate is a PowerShell scriptblock and the overlay thread is
    // already inside Dispatcher.Run(), so the engine has to reach a runspace that is busy. Writing
    // three fields costs nothing, and the overlay's own pump applies them from its own thread.
    public static volatile int MarkerX = -1;
    public static volatile int MarkerY = -1;
    public static volatile bool MarkerHide = false;
    public static volatile int MarkerSeq = 0;   // incremented per request; the pump compares it
    // volatile is illegal on long in C# (the compiler rejects it, which is the point: a 64-bit
    // read is not guaranteed atomic). The hwnd is written once before any reader exists and read
    // as a value, so plain static is honest here; Interlocked would be the answer if it changed.
    public static long OverlayHwnd = 0;
    public static string Reason = "";
    public static object Dispatcher = null;   // overlay thread's WPF dispatcher (set by that thread)
    public static object Window = null;        // the marker window (touched ONLY on its own thread)
    public static object Timer = null;         // auto-hide timer (same rule)
}
'@
}

# Before anything can create a window. See EnsureDpiAware: an unaware process virtualises the same
# coordinates the engine uses for clicks, which is how the marker ended up off by the display scale.
$script:WpmDpiAware = [WpmWin]::EnsureDpiAware()

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
  $doorHandles = @()
  foreach ($k in $kids) {
    $kh = [IntPtr]$k
    $kc = [WpmWin]::Cls($kh)
    # WinForms child classes are NOT 'Edit'/'Button': they are
    #   WindowsForms10.EDIT.app.0.<hash>_rN_adN / .BUTTON. / .RichEdit20W.
    # and the old exact-ish match ('Edit', 'Button') never hit one of those -- the message door
    # silently did not exist on the one toolkit where it demonstrably works, and the engine
    # reported WinForms as `unreachable`. Found end-to-end by test/llm-action-battery.mjs; the
    # census scripts had their own matching and never exercised this path. The base class is the
    # segment after the `WindowsForms10.` prefix, taken before the next dot.
    $base = $kc
    if ($kc -like 'WindowsForms10.*') { $base = (($kc -split '\.')[1]) }
    $kind = ''
    if ($base -like 'Edit*' -or $base -like 'RichEdit*' -or $kc -like '*TextBox*') { $kind = 'text' }
    elseif ($base -like 'BUTTON*' -or $base -like 'Button*' -or $kc -eq 'ComboBox') { $kind = 'click' }
    if ($kind) {
      $doorKinds += $kind
      $childHandles += $kh
      $doorHandles += @{ kind = $kind; hwnd = $kh }
    }
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

  # Elevation is now measured, not assumed. WpmWin::IsElevatedTarget compares the target's
  # integrity RID against ours; a failure to read either side returns false rather than guessing,
  # because guessing 'elevated' would refuse every window whose handle read failed. The flag is
  # consumed by decide.ps1's table, which checks it BEFORE any capability -- so an elevated target
  # is refused outright and never probed for doors it cannot answer.

  $tpid = [WpmWin]::PidOf($Hwnd)
  $elevated = [WpmWin]::IsElevatedTarget($tpid)

  $facts = New-WpmFacts -Hwnd ($Hwnd.ToInt64().ToString()) -Family $fam `
    -MessageDoor ($doorKinds.Count -gt 0) -HasPattern $hasPattern -PatternKind $patKind `
    -Action $Action -FactsMeasured $true -ElevatedTarget $elevated

  return @{
    facts = $facts
    cls = $cls
    family = $fam
    childHandles = $childHandles
    doorHandles = $doorHandles
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
