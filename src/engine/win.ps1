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

    /// <summary>
    /// Put THIS window at the top of the topmost band without activating it. Exists for the desktop
    /// test arms, which assert facts about a screen point ("WindowFromPoint at the marker returns my
    /// base"; "the click lands on my target's button"). A third-party full-screen window -- a video
    /// player that went fullscreen while these lines were written (measured live: PotPlayer owned every
    /// test point) -- makes WindowFromPoint return the OCCLUDER. When that happens the ENGINE IS RIGHT
    /// to refuse: it must never act under a window the caller did not name. What broke is the arm's
    /// PREMISE, not the product. Raising the test's OWN window into the topmost band uses the same
    /// mechanism the overlay relies on (HWND_TOPMOST + SWP_NOACTIVATE): z-order changes,
    /// GetForegroundWindow does not. This is a test-support primitive, NOT a product surface -- there is
    /// no reason to let a model topmost-raise arbitrary windows, so no such action exists in
    /// tools.json; scripts/raise-topmost.ps1 is the only product-adjacent caller and it is a test
    /// helper under scripts/, not exposed through wpm.
    /// </summary>
    public static bool MakeTopmostNoActivate(IntPtr h) {
        // SWP_NOMOVE(0x2) | SWP_NOSIZE(0x1) | SWP_NOACTIVATE(0x10), insert after HWND_TOPMOST(-1).
        return SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x2u | 0x1u | 0x10u);
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

    // One proof sample: cursor x/y, foreground HWND, focused-control HWND, and the age of the last
    // PHYSICAL input. Every read is a non-disturbing query (GetCursorPos, GetForegroundWindow,
    // GetGUIThreadInfo, GetLastInputInfo change nothing), which is the property that makes it safe to
    // call in a tight loop DURING an action -- unlike spawning a fresh PowerShell per poll, which can
    // itself steal the foreground and contaminate the measured quantity (src/lib/sampler.mjs).
    public static string[] Sample()
    {
        POINT cp; GetCursorPos(out cp);
        IntPtr fg = GetForegroundWindow();
        GUITHREADINFO g = new GUITHREADINFO();
        g.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
        uint pid; uint tid = GetWindowThreadProcessId(fg, out pid);
        long focusHwnd = 0;
        if (GetGUIThreadInfo(tid, ref g)) focusHwnd = g.hwndFocus.ToInt64();
        long age = LastInputAgeMs();   // the one tick-difference calculation; -1 when unreadable
        return new string[] {
            cp.X.ToString(), cp.Y.ToString(),
            fg.ToInt64().ToString(), focusHwnd.ToString(), age.ToString()
        };
    }
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
        SendMessageString(child, 0x000C, IntPtr.Zero, text);
        return "settext|" + text.Length;
    }

    // ---- 0.6.0: reading the value back, and putting the caret somewhere on purpose -------------
    // WHY THESE PRIMITIVES DID NOT EXIST BEFORE. The message door only ever SENT; every claim about
    // "the field now contains this" was a report of what SendMessage returned, which is a statement
    // about delivery, not about the application's state. Measured on 2026-11-23 (findings 8.2) with an
    // in-process oracle: on a plain Win32 EDIT that has never held focus, WM_CHAR is INERT -- every
    // character is accepted and nothing changes -- while the shipped answer was `reported-by-send`.
    // The read is what turns that from a false success into a visible one.
    //
    // ONE MORE THING THIS FIXED, found by running the syscall instead of trusting the import: the
    // previous WM_SETTEXT binding was declared as `SendMessageStrW`, which user32.dll does not export
    // (.tmp/_t-sendmessagestrw.ps1: EntryPointNotFoundException, first call, every call). So
    // `type` with replace:true threw and surfaced as `action_failed` on EVERY target, and no test in
    // the repo exercised it. The entry point is now pinned explicitly, because a marshaller resolves
    // the name it is given and an alias that exists in nobody's header is not a name.
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    public static extern IntPtr SendMessageString(IntPtr h, uint m, IntPtr w, string l);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    public static extern IntPtr SendMessageBuffer(IntPtr h, uint m, IntPtr w, [Out()] StringBuilder l);

    // The hang-proof read. A plain SendMessageW(WM_GETTEXT) to a window whose thread is busy blocks
    // this worker indefinitely, and a read is never worth wedging the sidecar for: with a budget the
    // answer degrades to `unavailable`, which the engine reports instead of inventing.
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
    public static extern IntPtr SendMessageTimeoutBuffer(IntPtr h, uint m, IntPtr w, [Out()] StringBuilder l,
        uint flags, uint ms, out IntPtr res);

    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);

    public const uint WM_SETTEXT = 0x000C, WM_GETTEXT = 0x000D, WM_GETTEXTLENGTH = 0x000E;
    public const uint WM_CHAR = 0x0102, EM_SETSEL = 0x00B1, EM_GETSEL = 0x00B0;
    public const uint SMTO_ABORTIFHUNG = 0x0002;

    /// <summary>WM_GETTEXTLENGTH. A length the CONTROL reports, not a length we computed.</summary>
    public static int TextLength(IntPtr h) { return (int)(long)SendMessageW(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero); }

    /// <summary>{ok, chars, text} from WM_GETTEXT, sized from the control's own WM_GETTEXTLENGTH.
    /// The buffer is deliberately one char LONGER than the reported length: the control writes a
    /// terminating NUL into the buffer it is handed, and a measured truncation (a 1000-char buffer
    /// against a 5000-char value came back as 999) has to stay visible rather than become the answer.</summary>
    public static object[] ReadText(IntPtr h, uint ms)
    {
        int len = TextLength(h);
        if (len < 0) len = 0;
        if (len > 65536) len = 65536;                 // a capped read, reported as truncated downstream
        var sb = new StringBuilder(len + 2);
        IntPtr res;
        IntPtr r = SendMessageTimeoutBuffer(h, WM_GETTEXT, (IntPtr)(len + 1), sb, SMTO_ABORTIFHUNG, ms, out res);
        if (r == IntPtr.Zero) return new object[] { false, -1, "" };
        int n = (int)(long)res;
        string s = sb.ToString();
        if (n >= 0 && n <= s.Length) s = s.Substring(0, n);
        return new object[] { true, n, s };
    }

    /// <summary>{start, end} from EM_GETSEL -- the control's own answer about where a typed
    /// character will land, which is what makes an expected-value model computable (findings 8.2).</summary>
    public static int[] GetSel(IntPtr h)
    {
        long r = (long)SendMessageW(h, EM_GETSEL, IntPtr.Zero, IntPtr.Zero);
        return new int[] { (int)(r & 0xFFFF), (int)((r >> 16) & 0xFFFF) };
    }

    /// <summary>EM_SETSEL. NOTE: -1 is NOT used for `end` -- measured on WinForms EDIT it leaves the
    /// selection at 0,0 and the typed character goes to the FRONT (findings 8.2). The caller passes
    /// the length it read from the control.</summary>
    public static void SetSel(IntPtr h, int a, int b) { SendMessageW(h, EM_SETSEL, (IntPtr)a, (IntPtr)b); }

    /// <summary>
    /// Write text through the message door with an explicit caret intention, and report BOTH what was
    /// asked for and what the control says its selection now is. The selection is read back rather than
    /// echoed because the whole point is that the control, not the caller, decides where text goes:
    /// EM_SETSEL(6,6) on a buffer whose WM_GETTEXTLENGTH is 6 came back as 4,4 on a value containing a
    /// newline, and an engine that reported the requested pair would have been describing a wish.
    /// mode: 'settext' (whole-value replace) | 'char' (per-character, inserted at the reported sel).
    /// </summary>
    public static object[] MessageTextAt(IntPtr child, string text, bool replace, string caret)
    {
        if (replace)
        {
            SendMessageString(child, WM_SETTEXT, IntPtr.Zero, text);
            if (caret == "start") SetSel(child, 0, 0);
            else if (caret == "end") { int l = TextLength(child); SetSel(child, l, l); }
            int[] rs = GetSel(child);
            return new object[] { "settext", text.Length, rs[0], rs[1] };
        }
        int askedStart = -1, askedEnd = -1;
        if (caret == "start") { SetSel(child, 0, 0); askedStart = 0; askedEnd = 0; }
        else if (caret == "end") { int l = TextLength(child); SetSel(child, l, l); askedStart = l; askedEnd = l; }
        int[] sel = GetSel(child);
        for (int i = 0; i < text.Length; i++) SendMessageW(child, WM_CHAR, (IntPtr)text[i], IntPtr.Zero);
        return new object[] { "char", text.Length, sel[0], sel[1], askedStart, askedEnd };
    }

    // ---- 0.5.0: the frame, the virtual screen, and the capture footprint ---------------------
    // THE FRAME COMES FROM DWM, NOT FROM GetWindowRect. Measured on this desktop (2026-11-23):
    // GetWindowRect returns -8,-8,1928,1040 while DwmGetWindowAttribute(EXTENDED_FRAME_BOUNDS)
    // returns 0,0,1920,1032 -- four 8px differences that are the invisible resize shadow. The UIA
    // tree MIXES the two spaces (the ROOT element reports the shadow-inclusive rect, its children the
    // real one), so any arithmetic that mixes them is 8px wrong and looks right. `screenRect` is
    // therefore DWM-only, and the fallback is REPORTED as frame='win32' rather than hidden: an 8px
    // offset with no field to explain it is the failure mode this whole change is written against.
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);

    /// <summary>{hr, left, top, right, bottom}. hr==0 means the DWM answer is usable.</summary>
    public static long[] DwmFrame(IntPtr h)
    {
        RECT r;
        int hr = DwmGetWindowAttribute(h, 9 /* DWMWA_EXTENDED_FRAME_BOUNDS */, out r, Marshal.SizeOf(typeof(RECT)));
        if (hr != 0) return new long[] { hr, 0, 0, 0, 0 };
        return new long[] { 0, r.Left, r.Top, r.Right, r.Bottom };
    }

    /// <summary>{ok, left, top, right, bottom} from GetWindowRect -- the documented FALLBACK only.</summary>
    public static long[] WinRect(IntPtr h)
    {
        RECT r;
        if (!GetWindowRect(h, out r)) return new long[] { 0, 0, 0, 0, 0 };
        return new long[] { 1, r.Left, r.Top, r.Right, r.Bottom };
    }

    /// <summary>{x, y, width, height} of the virtual screen (all monitors, physical pixels).</summary>
    public static int[] VirtualScreen()
    {
        const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77;
        const int SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;
        return new int[] { GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
                           GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN) };
    }

    // ---- 0.6.0-B: the cheaper capture, with the SAME semantics as the one it replaces -----------
    // WHY. Measured on this host (findings 8.4): the capture is not the bottleneck -- PNG encoding is
    // (37-39ms of a ~70ms screenshot). But the capture half still costs 22-33ms through
    // Graphics.CopyFromScreen and 16-21ms through a direct BitBlt, so the cheap primitive is taken and
    // the encoder is left alone. JPEG (10ms, but it smears text), WIC (158ms, slower), and 24bpp
    // (7% smaller) were all measured and all rejected.
    //
    // WHY THE SOURCE DC IS THE SCREEN AND NOT THE WINDOW. Get-WpmScreenshot has always captured the
    // frame RECTANGLE OUT OF THE SCREEN, which is what makes its coordinates the same system a click
    // uses and what makes an occluding window appear in the picture (honestly: the picture shows what a
    // user would see). Capturing with GetWindowDC/PrintWindow would be a DIFFERENT product -- unoccluded,
    // and no longer the screen the coordinates refer to. Equivalence was measured, not assumed: on a
    // static scene the two paths give identical size, identical content, 0 max per-channel difference
    // over 17388 sampled points, and byte-identical PNGs (findings 8.3). The one difference is reported:
    // FromHbitmap yields Format32bppRgb where CopyFromScreen yields Format32bppArgb.
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dc, int x, int y, int w, int h,
        IntPtr srcDc, int srcX, int srcY, uint rop);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    const uint SRCCOPY = 0x00CC0020;

    /// <summary>
    /// Capture a SCREEN rectangle into a new HBITMAP through BitBlt. Returns IntPtr.Zero with a named
    /// reason on ANY failure -- the caller falls back to CopyFromScreen and reports which path it used.
    /// Every GDI object created here is released on every path, including the partial ones: a leaked DC
    /// in a long-lived worker is the kind of bug that shows up as "the app stopped painting" an hour in.
    /// The returned handle is owned by the caller and must be passed to FreeHbitmap.
    /// </summary>
    public static IntPtr CaptureBitBlt(int x, int y, int w, int h, out string reason)
    {
        reason = "";
        if (w <= 0 || h <= 0) { reason = "empty rectangle " + w + "x" + h; return IntPtr.Zero; }
        IntPtr screen = GetDC(IntPtr.Zero);
        if (screen == IntPtr.Zero) { reason = "GetDC(NULL) returned no screen DC"; return IntPtr.Zero; }
        IntPtr mem = IntPtr.Zero, bmp = IntPtr.Zero, old = IntPtr.Zero;
        try
        {
            mem = CreateCompatibleDC(screen);
            if (mem == IntPtr.Zero) { reason = "CreateCompatibleDC failed"; return IntPtr.Zero; }
            bmp = CreateCompatibleBitmap(screen, w, h);
            if (bmp == IntPtr.Zero) { reason = "CreateCompatibleBitmap failed"; return IntPtr.Zero; }
            old = SelectObject(mem, bmp);
            if (!BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY)) { reason = "BitBlt refused"; DeleteObject(bmp); return IntPtr.Zero; }
            return bmp;
        }
        finally
        {
            // `old` is restored before the memory DC goes away, and the screen DC is always released.
            if (mem != IntPtr.Zero && old != IntPtr.Zero) SelectObject(mem, old);
            if (mem != IntPtr.Zero) DeleteDC(mem);
            ReleaseDC(IntPtr.Zero, screen);
        }
    }

    /// <summary>Release an HBITMAP from CaptureBitBlt. Safe to call after FromHbitmap: that call copies
    /// the bits into managed memory, so the native handle has nothing left to alias.</summary>
    public static bool FreeHbitmap(IntPtr h) { return h != IntPtr.Zero && DeleteObject(h); }
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

    // ---- R3 takeover surface (spec.md §2) ------------------------------------------------------
    // Same rule as the marker fields: the HUD thread owns the window and reads these; the engine writes
    // the request fields. No scriptblock is ever marshalled across the threads.
    public static volatile bool HudOn = false;
    public static volatile bool TakeoverAbort = false;   // HUD button / abort chord / worker abort
    public static volatile bool AbortChordOk = false;
    // volatile is ILLEGAL on string in C# (like long below): a reference write is atomic, so a plain
    // static is the honest declaration and not a weaker one.
    public static string HudPhase = "";
    public static string HudAction = "";
    public static string AbortChordLabel = "";
    public static volatile int HudElapsedMs = 0;
    public static volatile int HudMaxMs = 0;
    public static volatile int HudSeq = 0;
    public static volatile int InjectedChars = 0;
    public static long HudHwnd = 0;
}
'@
}

# Before anything can create a window. See EnsureDpiAware: an unaware process virtualises the same
# coordinates the engine uses for clicks, which is how the marker ended up off by the display scale.
$script:WpmDpiAware = [WpmWin]::EnsureDpiAware()

$script:WpmUia = $null
# ---- 0.5.0 state. Deliberately IN-PROCESS and BOUNDED: a label is only meaningful in the frame that
# printed it, so this holds at most two snapshots (the newest for label references, the previous as a
# sinceSnapId diff base) and at most shotsKeep screenshots. A worker restart empties both, which is
# exactly what makes a stale id a real, reportable condition instead of an unbounded cache.
$script:WpmSnapshots = @()
$script:WpmShots = @{}
$script:WpmSnapSeq = 0
$script:WpmShotSeq = 0
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

function Test-WpmUiaTreeHasContent([IntPtr]$Hwnd, [int]$MaxElements = 200) {
  <#
    Does this target's accessibility tree contain ANY content element, or is it shell only?
    Returns $true when at least one element carries a content control type, $false when the
    walked tree is only structural chrome, and $false when the walk itself cannot run (a walk
    that failed must not be reported as "measured empty" -- the caller distinguishes that world
    through the probe error, not through this answer).

    WHY CONTENT, NOT COUNT. "The tree is empty" cannot mean Count == 0: a Chromium window with
    renderer accessibility off still exposes ONE shell element -- the Chrome_RenderWidgetHostHWND
    pane ("Chrome Legacy Window") -- so uTools measures raw=1 while carrying zero drivable
    content, and the same window measured raw=0 earlier the same day depending on its own state.
    What never changed across every re-read was the CONTENT count: 0 for the a11y-off window,
    hundreds for the a11y-on ones (DSH 514 at census time, 1019 later; ZCode 497). The stable
    boundary is structural, not numeric: shell types (Pane/Group/Image/Text/Thumb/Separator/
    TitleBar) are the window's own chrome; anything else -- Button, Edit, Document, Custom --
    is something an application chose to expose. Custom counts as content deliberately: it may
    be undrivable, but calling it "empty" would claim the app has a11y off, and a wrong
    uia_tree_empty is a worse lie than an honest unreachable.

    Measured on 2026-11-21 (see scripts/uia-tree-content.ps1, which reads the same two counters
    with the same shell list). This is also why NO retry/polling exists for a tree that answers
    empty: three in-place reads over 2.2s produced zero content elements every time -- there is
    nothing to wait for. The switch is launch-time: --force-renderer-accessibility.
  #>
  try {
    $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    $all = $rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition)
    $n = [Math]::Min($all.Count, $MaxElements)
    for ($i = 0; $i -lt $n; $i++) {
      $t = ''
      try { $t = $all[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '' } catch { continue }
      if (@('Pane', 'Group', 'Image', 'Text', 'Thumb', 'Separator', 'TitleBar') -notcontains $t) { return $true }
    }
    return $false
  } catch {
    return $false
  }
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

function Resolve-WpmUiaElementAtPoint {
  <#
    WHICH UIA ELEMENT SITS UNDER A SCREEN POINT -- the UIA twin of Resolve-WpmChildAtPoint.

    WHY THIS EXISTS. The UIA tier used to take the FIRST descendant carrying any usable pattern and
    invoke that, while the contract (src/schema/tools.json) says x/y are REQUIRED and that a point
    which does not resolve inside the target is refused "instead of being sent somewhere else". On a
    target with no message door -- WPF, UWP, WinUI3, i.e. most modern apps -- 'click 500,300' would
    therefore Invoke whichever control happened to come first in tree order and return ok:true. That
    is not a refusal, it is a wrong action reported as a right one, and it also breaks the marker's
    promise (the marker is drawn at the requested point, which was then not the point acted on).

    THE WALK-UP. AutomationElement.FromPoint returns the DEEPEST element at the point, which for a
    button is usually its text child; the Invoke pattern lives on the ancestor. So the search climbs
    from the hit element towards the target root and takes the nearest ancestor that has a usable
    pattern. Climbing stops at the target's own root element: beyond it lies the caller's other
    windows, and acting there would be acting on a window nobody named.

    ANCESTRY IS PROVEN, NOT ASSUMED. If the climb reaches a null parent without meeting the target
    root, the point belongs to a different window and the answer is a refusal -- the same rule the
    message tier enforces with Root(hit) -ne Hwnd.
  #>
  param([IntPtr]$Hwnd, [int]$X, [int]$Y)

  $out = @{ element = $null; patternKind = 'none'; err = ''; atPoint = $false; reason = '' }
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    if (-not $root) { $out.err = 'target window has no UIA element'; $out.reason = 'target element unavailable'; return $out }

    $pt = New-Object System.Windows.Point([double]$X, [double]$Y)
    $hitEl = [System.Windows.Automation.AutomationElement]::FromPoint($pt)
    if (-not $hitEl) { $out.reason = 'nothing at that point is exposed to UI Automation'; return $out }
    $out.atPoint = $true

    # ANCESTRY FIRST, PATTERN SECOND. The first version of this function searched for a pattern
    # while climbing and returned the moment it found one -- which re-created the very bug it was
    # written to kill, one level down: a click at a point OUTSIDE the target climbed into the
    # taskbar, found a patterned button there, invoked it, and reported ok:true. Caught by the
    # 'point outside the target' arm of test/uia-click-truth.mjs. The order is the invariant:
    # prove the point belongs to THIS window, and only then ask what at the point can be driven.
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $path = @()
    $el = $hitEl
    $sawRoot = $false
    $hop = 0
    while ($el -and $hop -lt 24) {
      if ($el -eq $root) { $sawRoot = $true; break }
      $path += $el
      try { $el = $walker.GetParent($el) } catch { $el = $null }
      $hop++
    }
    if ($el -eq $root) { $sawRoot = $true }

    if (-not $sawRoot) {
      # The climb ended without meeting the target root: the point is in another window, and
      # acting there would be acting on a window nobody named.
      $out.element = $null
      $out.patternKind = 'none'
      $out.reason = 'the element under that point does not belong to the target window'
      return $out
    }

    $pats = Get-WpmUiaCached
    foreach ($node in $path) {
      foreach ($k in @('invoke', 'value', 'toggle', 'select', 'legacy')) {
        if (-not $pats.ContainsKey($k)) { continue }
        $obj = $null
        $has = $false
        try { $has = $node.TryGetCurrentPattern($pats[$k], [ref]$obj) } catch { $has = $false; $obj = $null }
        if ($has -and $obj) { $out.element = $node; $out.patternKind = $k; return $out }
      }
    }
    $out.reason = 'the element under that point exposes no usable UIA pattern'
    return $out
  } catch {
    $out.err = $_.Exception.Message
    $out.reason = 'the point probe threw'
    return $out
  }
}

function Get-WpmFacts {
  <#
    Measure a target's doors. Returns the hashtable decide.ps1 consumes, plus the raw handles the
    executor needs. Cached per hwnd because UIA enumeration costs hundreds of ms and a batch of 50
    clicks must not pay it 50 times -- but the cache is keyed on hwnd AND invalidated by the caller
    when the window set changes, never assumed fresh.
  #>
  param([IntPtr]$Hwnd, [string]$Action = 'click', [string]$ElementName = '', [int]$X = -1, [int]$Y = -1, [switch]$NoCache)

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
  $uiaReason = ''
  $scanProbed = $false

  # A CLICK WITH COORDINATES IS RESOLVED AT THE POINT, never by tree order. See
  # Resolve-WpmUiaElementAtPoint for what went wrong before this: the first descendant carrying a
  # pattern was invoked regardless of x/y, so an unnamed click on a WPF/UWP/WinUI target acted on a
  # control the caller never pointed at -- and answered ok:true. Naming an element (ElementName) is
  # a different contract: there the caller asked for that control, so tree scan is correct.
  $pointResolved = $false
  if ($doorKinds.Count -eq 0 -and -not $ElementName -and $Action -eq 'click' -and $X -ge 0 -and $Y -ge 0) {
    $pr = Resolve-WpmUiaElementAtPoint -Hwnd $Hwnd -X $X -Y $Y
    $uiaErr = $pr.err
    $uiaReason = $pr.reason
    $pointResolved = $true
    if ($pr.element) {
      $hasPattern = $true
      $patKind = $pr.patternKind
      $uiaElement = $pr.element
    }
  } elseif ($doorKinds.Count -eq 0 -or $ElementName) {
    $scanProbed = $true
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

  # EMPTY TREE vs PATTERN-LESS CONTENT, measured rather than folded into one word. When the UIA
  # probe ran and found nothing usable, two different worlds produce the same hasPattern=false:
  # a tree that was never populated (the app has a11y off -- uTools walks to one shell Pane and
  # zero content elements, and no amount of re-querying changes that), and a tree that is alive
  # but offers nothing at the named point or element (ZCode/DSH walk to hundreds of elements).
  # They get different refusal codes (decide.ps1), so this measurement runs only when the probe
  # actually ran -- never to decorate a target whose message door already decided the route.
  $uiaTreeEmpty = $false
  # THE DIAGNOSIS ONLY APPLIES TO A WINDOW THAT HAS NO OTHER DOOR. This condition used to be just
  # "the probe ran and found no pattern", which mislabels a whole class of target: name an element on a
  # WinForms window and `engine.ps1` suppresses its message door (a window message cannot address "the
  # control called X"), the UIA scan then finds nothing drivable, and the engine reported
  # `uia_tree_empty` -- "the application has accessibility switched off, relaunch it with
  # --force-renderer-accessibility". That advice is not merely useless for WinForms, it is WRONG about
  # the cause: the window demonstrably has a real door, we shut it ourselves. Measured 2026-11-23: the
  # WinForms positive control walks to three Panes carrying the controls' own names and automation ids
  # through the MSAA bridge (content=0, so `Test-WpmUiaTreeHasContent` says "no content"), while the
  # genuine a11y-off sample (uTools) and a bare desktop shell have the same shape -- so the tree alone
  # cannot separate them. The door CAN: a target we measured a door on must not be diagnosed as
  # accessibilty-off, whatever its tree looks like. Doors present => the honest code is `unreachable`
  # ("nothing addressable at that name"), which points at a next step that exists.
  if (-not $hasPattern -and ($pointResolved -or $scanProbed) -and ($doorKinds.Count -eq 0)) {
    $uiaTreeEmpty = -not (Test-WpmUiaTreeHasContent $Hwnd)
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
    -Action $Action -FactsMeasured $true -ElevatedTarget $elevated `
    -UiaTreeEmpty $uiaTreeEmpty -UiaProbeFailed ($uiaErr -ne '')

  return @{
    facts = $facts
    cls = $cls
    family = $fam
    childHandles = $childHandles
    doorHandles = $doorHandles
    doorKinds = @($doorKinds | Sort-Object -Unique)
    uiaElement = $uiaElement
    uiaErr = $uiaErr
    # Why there is no element, when there is none. Previously uiaErr was produced and then read by
    # nobody (grep found zero consumers), so a point that resolved outside the target and a target
    # whose tree cannot be walked at all reached the caller as the same sentence: 'no message door
    # and no usable UIA pattern'. Two different worlds, one string -- and the fixes differ.
    uiaReason = $uiaReason
    # The two booleans that decide.ps1 splits 'unreachable' on travel INSIDE $facts, built through
    # the typed constructor above -- deliberately NOT duplicated here. A second copy of a measured
    # value in the same return object is the two-copies-drift bug this repo keeps meeting; the
    # first live-instance run of this very change caught exactly that shape (facts said False
    # while the raw measurement said True, because the constructor call had not been extended).
    pointResolved = $pointResolved
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

# ==================================================================================================
# 0.6.0 INPUT RELIABILITY: the read-back primitive, expressed as the fact it is and not as a verdict.
# ==================================================================================================

function Read-WpmControlText {
  <#
    What the CONTROL says it holds, through WM_GETTEXT. Returns the control's own three numbers plus one
    derived flag, and the derivation is stated because it is the whole safety property of the feature:

      exposesText = NOT (chars == 0 AND length > 0)

    Measured 2026-11-23 on an ES_PASSWORD edit (findings 8.1): WM_GETTEXT returns an EMPTY string while
    WM_GETTEXTLENGTH returns the real length. That combination cannot mean "the field is empty" -- the
    control is reporting a length it refuses to spell out. Treating it as "empty, and therefore my write
    did not land" would be wrong twice over: it would report a mismatch that did not happen, and if the
    engine had tried to be cleverer and print what it read, a password field is exactly where printing a
    value stops being a diagnostic. So the read is reported as UNAVAILABLE, no text is carried anywhere,
    and the effect keeps the value the write itself earned.
  #>
  param([IntPtr]$Hwnd, [int]$TimeoutMs = 200)
  $length = -1
  try { $length = [WpmWin]::TextLength($Hwnd) } catch { }
  $r = [WpmWin]::ReadText($Hwnd, [uint32][Math]::Max(1, $TimeoutMs))
  $okRead = [bool]$r[0]
  $chars = [int]$r[1]
  $text = [string]$r[2]
  return @{
    ok = $okRead; chars = $chars; text = $text; length = $length
    exposesText = ($okRead -and -not ($chars -eq 0 -and $length -gt 0))
    truncated = ($okRead -and $length -gt 0 -and $chars -lt $length)
    reason = if (-not $okRead) { 'the timed read failed (target not answering within the budget)'
      } elseif ($chars -eq 0 -and $length -gt 0) { 'the control reports a length but no text (password-masked or equivalent)'
      } else { '' }
  }
}

# ==================================================================================================
# 0.7.0 DESKTOP CAPABILITIES: launch, clipboard, window. Three actions the product could not do
# before, and none of them is a door: they take no target's message queue, choose no channel, and
# produce no proof window -- so they live BESIDE Invoke-WpmAction rather than inside it. The door
# discipline (point ownership, the restore table, the proof window) is not widened by any of this.
# ==================================================================================================

function Start-WpmApp {
  <#
    Launch a program. The HOST half is what decides whether this may run at all (appLaunchAllowed and
    the exact-name whitelist, lib/index.js); by the time this function is reached the decision is made,
    and this file reports only what the OS did.

    Why the return is a pid and NOT a window handle: measured, `Process.Start` returns while the app is
    still loading and MainWindowHandle is 0 (1348 ms cold for notepad). A launch that claimed a window it
    does not have yet would send every follow-up action to hwnd=0, so the window is waited for
    separately, by Wait-WpmAppWindow, and reported honestly when it has not appeared.
  #>
  param([string]$Target, [string[]]$Arguments = @(), [string]$WorkingDirectory = '')
  if (-not $Target) { return @{ ok = $false; reason = 'launch needs a target: an executable path or a resolvable program name' } }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Target
    $psi.UseShellExecute = $true              # the documented way a shell start resolves .exe/app paths
    if ($Arguments -and $Arguments.Count -gt 0) {
      $psi.Arguments = ($Arguments -join ' ')
      # The arguments are joined into one command line here. That is what the OS takes; the AUDIT logs
      # them as given, because R1 in the plan says the whitelist cannot make parameters safe, only the
      # record can make a bad one reviewable.
    }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p) { return @{ ok = $false; reason = 'the OS started nothing for this target' } }
    return @{ ok = $true; pid = [int]$p.Id; name = [string]$p.ProcessName;
      fileName = [string]$p.MainModule.FileName; target = $Target }
  } catch {
    # Access denied, missing file, bad working directory. Reported as a failure of THIS action, with the
    # OS's own sentence attached -- not folded into an engine refusal code it does not own.
    return @{ ok = $false; reason = 'start failed: ' + $_.Exception.Message }
  }
}

function Wait-WpmAppWindow {
  <#
    Poll for the process's first real top-level window, up to `WaitMs`. Two answers, both honest:
      found    -> { ok=true; hwnd=...; waitedMs }
      not yet  -> { ok=true; hwnd=''; detail='window-not-yet'; waitedMs } -- NOT a failure. The program
                  did start; pretending otherwise would make a slow launch look like a dead one, and
                  pretending the window exists would send the next action to nothing.
  #>
  param([int]$ProcessId, [int]$WaitMs = 3000)
  $budget = [Math]::Max(0, [Math]::Min(30000, $WaitMs))
  $at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $deadline = $at + $budget
  while ($true) {
    $p = $null
    try { $p = Get-Process -Id $ProcessId -ErrorAction Stop } catch { $p = $null }
    if (-not $p) {
      return @{ ok = $false; hwnd = ''; reason = "process $ProcessId is gone"; waitedMs = [int]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $at) }
    }
    $h = [long]$p.MainWindowHandle
    # Refresh: MainWindowHandle is cached on the Process object, and the whole reason this loop exists
    # is that the first read is 0.
    if ($h -le 0) { try { $p.Refresh() } catch { }; $h = [long]$p.MainWindowHandle }
    if ($h -gt 0) {
      return @{ ok = $true; hwnd = $h.ToString(); waitedMs = [int]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $at);
        title = [string]$p.MainWindowTitle }
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($now -ge $deadline) {
      return @{ ok = $true; hwnd = ''; detail = 'window-not-yet'; waitedMs = [int]($now - $at);
        note = "the process is running but has published no top-level window within $budget ms; keep polling, or address it by pid"
      }
    }
    Start-Sleep -Milliseconds 50
  }
}

function Get-WpmClipboard {
  <#
    Read the SYSTEM clipboard. R8 in the plan is the reason this is written carefully: what is in the
    clipboard may be a password or a token the owner copied seconds ago. So:
      * text is capped at 64 KB and a longer payload is TRUNCATED AND SAYING so (`truncated=true`),
        rather than either silently cutting or dumping the whole thing into a model's context;
      * the audit records op/format/length, never the content (lib/index.js owns the audit line);
      * a non-text, non-image clipboard answers `unsupported-format` with the format names it did find
        -- an empty success would be indistinguishable from "the clipboard is empty".
    Requires STA, which the worker already runs under (`powershell.exe -STA`); measured in findings 5.2.
  #>
  param([string]$Format = 'text', [int]$MaxChars = 65536)
  Add-Type -AssemblyName System.Windows.Forms
  $fmt = if ($Format -eq 'image') { 'image' } else { 'text' }
  try {
    if ($fmt -eq 'text') {
      if (-not [System.Windows.Forms.Clipboard]::ContainsText()) {
        return @{ ok = $false; reason = 'the clipboard holds no text'; formats = (Get-WpmClipboardFormats) }
      }
      $t = [System.Windows.Forms.Clipboard]::GetText()
      if ($null -eq $t) { $t = '' }
      $cap = [Math]::Max(1, $MaxChars)
      $truncated = $t.Length -gt $cap
      return @{ ok = $true; format = 'text'; chars = [int]$t.Length; text = $(if ($truncated) { $t.Substring(0, $cap) } else { $t }); truncated = $truncated }
    }
    if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) {
      return @{ ok = $false; reason = 'the clipboard holds no image'; formats = (Get-WpmClipboardFormats) }
    }
    $img = [System.Windows.Forms.Clipboard]::GetImage()
    if (-not $img) { return @{ ok = $false; reason = 'the clipboard claimed an image and returned none' } }
    $dir = Join-Path (Get-WpmDataDir) 'clipboard'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $id = 'clip-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $file = Join-Path $dir ($id + '.png')
    $img.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $w = [int]$img.Width; $h = [int]$img.Height
    $img.Dispose()
    return @{ ok = $true; format = 'image'; file = $file; clipId = $id; width = $w; height = $h }
  } catch {
    # The clipboard is owned by whatever app last touched it and can be locked; that is a transient
    # state of the desktop, reported as a failure of this action with the OS's sentence attached.
    return @{ ok = $false; reason = 'clipboard read failed: ' + $_.Exception.Message }
  }
}

function Get-WpmClipboardFormats {
  # The format NAMES, so a refusal can say what IS there instead of only what is not.
  try {
    $names = @([System.Windows.Forms.Clipboard]::GetDataObject().GetFormats())
    return @($names | ForEach-Object { [string]$_ } | Select-Object -First 12)
  } catch { return @() }
}

function Set-WpmClipboard {
  <#
    Write the clipboard. `shotId` is accepted for an image so a screenshot can be pushed into the
    clipboard without the caller ever handling the pixels -- the same "the engine does the arithmetic"
    stance as space:"image" for a click. SetDataObject($true) flushes the data so it survives this
    process, which is the documented difference between a clipboard write and a clipboard promise.
  #>
  param([string]$Format = 'text', [string]$Text = '', [string]$ShotId = '')
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $fmt = if ($Format -eq 'image') { 'image' } else { 'text' }
  try {
    if ($fmt -eq 'text') {
      if (-not $Text) { return @{ ok = $false; reason = 'clipboard write needs text; an empty write is indistinguishable from a clipboard the owner already cleared' } }
      [System.Windows.Forms.Clipboard]::Clear()
      # SetDataObject($value, $true), NOT Flush(): `Flush` is a .NET Core API and this engine's floor is
      # Windows PowerShell 5.1 (= .NET Framework 4.x), where the call does not exist. The first version
      # of this branch threw "Clipboard does not contain a method named 'Flush'" -- a method that exists
      # in the documentation people read and not in the runtime the product targets. The second argument
      # is what makes the data survive this process, which is the whole behaviour being asked for.
      [System.Windows.Forms.Clipboard]::SetDataObject($Text, $true)
      $back = ''
      try { $back = [string][System.Windows.Forms.Clipboard]::GetText() } catch { }
      return @{ ok = $true; format = 'text'; chars = [int]$Text.Length; readbackChars = [int]$back.Length;
        readbackMatches = ($back -ceq $Text) }
    }
    if (-not $ShotId) { return @{ ok = $false; reason = 'clipboard image write needs a shotId (the screenshot to put there) or a file' } }
    if (-not $script:WpmShots.ContainsKey($ShotId)) {
      return @{ ok = $false; stale = $true; reason = "shotId '$ShotId' is not a screenshot this worker still holds" }
    }
    $file = [string]$script:WpmShots[$ShotId].file
    if (-not (Test-Path -LiteralPath $file)) { return @{ ok = $false; reason = "the shot's PNG is no longer on disk: $file" } }
    # The shot's own recorded size travels along, so the engine can compare what the clipboard reports
    # against what was asked. Without it the image write has no prediction to check and would have to
    # claim success from "the clipboard now holds an image", which is a weaker statement than the text
    # path can make.
    $askedW = [int]$script:WpmShots[$ShotId].imageWidth
    $askedH = [int]$script:WpmShots[$ShotId].imageHeight
    $bmp = [System.Drawing.Image]::FromFile($file)
    try {
      [System.Windows.Forms.Clipboard]::Clear()
      [System.Windows.Forms.Clipboard]::SetDataObject($bmp, $true)
    } finally { $bmp.Dispose() }
    $ok = $false; $w = 0; $h = 0
    try {
      if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        $w = [int]$img.Width; $h = [int]$img.Height; $img.Dispose(); $ok = $true
      }
    } catch { }
    return @{ ok = $ok; format = 'image'; shotId = $ShotId; file = $file; width = $askedW; height = $askedH;
      readbackWidth = $w; readbackHeight = $h }
  } catch {
    return @{ ok = $false; reason = 'clipboard write failed: ' + $_.Exception.Message }
  }
}

function Invoke-WpmWindowOp {
  <#
    One op on ONE window named by hwnd, and the verification is the OS's answer about the window, not
    the return value of the call. That distinction is the whole point of this function: ShowWindow and
    SetWindowPos return booleans about the CALL, and every action in this product that reported a call
    instead of a state has eventually turned out to be the lying kind.
      minimize -> IsIconic afterwards            (must be true)
      restore  -> IsIconic afterwards            (must be false)
      move     -> GetWindowRect afterwards       (left/top must match what was asked)
      resize   -> GetWindowRect afterwards       (width/height must match, within 2px)
      topmost  -> the WS_EX_TOPMOST bit, read back
    `topmost` is the promotion of `MakeTopmostNoActivate`, which shipped as a TEST-SUPPORT primitive
    (its comment says a model should not be able to topmost-raise arbitrary windows). 0.7.0 revisits
    that: it is now reachable, it never activates the window, and the result still reports the ex-style
    it read back -- see findings §5 for the reasoning that changed.

    WHAT THIS FUNCTION DELIBERATELY DOES NOT REPORT: the foreground. `restore` activates by definition
    (SW_RESTORE is documented to bring the window up), so "did the owner lose focus" is a question about
    the moment around this call rather than about the state after it -- and engine.ps1 reads
    GetForegroundWindow on both sides and reports the pair, where this function can only see one.
  #>
  param([IntPtr]$Hwnd, [string]$Op, [int]$X = 0, [int]$Y = 0, [int]$Width = 0, [int]$Height = 0)
  if (-not $Hwnd -or -not [WpmWin]::IsWindow($Hwnd)) {
    return @{ ok = $false; refusal = 'no_hwnd'; reason = 'the hwnd does not identify a live window' }
  }
  $before = New-Object 'WpmWin+RECT'
  [void][WpmWin]::GetWindowRect($Hwnd, [ref]$before)
  switch ($Op) {
    'minimize' {
      [void][WpmWin]::ShowWindow($Hwnd, [WpmWin]::SW_MINIMIZE)
      $iconic = [WpmWin]::IsIconic($Hwnd)
      return @{ ok = $iconic; op = $Op; iconic = $iconic;
        reason = $(if ($iconic) { '' } else { 'ShowWindow(SW_MINIMIZE) returned and the window is still not iconic' }) }
    }
    'restore' {
      [void][WpmWin]::ShowWindow($Hwnd, [WpmWin]::SW_RESTORE)
      $iconic = [WpmWin]::IsIconic($Hwnd)
      return @{ ok = (-not $iconic); op = $Op; iconic = $iconic;
        reason = $(if ($iconic) { 'the window is still iconic after SW_RESTORE' } else { '' }) }
    }
    'move' {
      # SWP_NOSIZE(1) | SWP_NOZORDER(4) | SWP_NOACTIVATE(10): a window move that stole the foreground
      # would be exactly the disturbance the rest of this product refuses to cause.
      $ok = [WpmWin]::SetWindowPos($Hwnd, [IntPtr]::Zero, $X, $Y, 0, 0, ([uint32]1 -bor [uint32]4 -bor [uint32]16))
      $r = New-Object 'WpmWin+RECT'
      [void][WpmWin]::GetWindowRect($Hwnd, [ref]$r)
      $moved = ($r.Left -eq $X -and $r.Top -eq $Y)
      return @{ ok = ($ok -and $moved); op = $Op; called = "$X,$Y"; rect = "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)";
        before = "$($before.Left),$($before.Top),$($before.Right),$($before.Bottom)";
        reason = $(if (-not $ok) { 'SetWindowPos was refused' } elseif (-not $moved) { 'the call returned and the window did not land where it was told' } else { '' }) }
    }
    'resize' {
      $w = [Math]::Max(1, $Width); $h = [Math]::Max(1, $Height)
      $ok = [WpmWin]::SetWindowPos($Hwnd, [IntPtr]::Zero, 0, 0, $w, $h, ([uint32]2 -bor [uint32]4 -bor [uint32]16))
      $r = New-Object 'WpmWin+RECT'
      [void][WpmWin]::GetWindowRect($Hwnd, [ref]$r)
      $cw = $r.Right - $r.Left; $ch = $r.Bottom - $r.Top
      # +-2 px: the window may clamp a size to its own minimum, and a 1px difference between the frame
      # the app asks for and the rect Windows reports is normal, not a lie worth failing the action over.
      $fits = ([Math]::Abs($cw - $w) -le 2) -and ([Math]::Abs($ch - $h) -le 2)
      return @{ ok = ($ok -and $fits); op = $Op; asked = "${w}x${h}"; size = "${cw}x${ch}";
        rect = "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)";
        reason = $(if (-not $ok) { 'SetWindowPos was refused' } elseif (-not $fits) { 'the window came back a different size than was asked (a clamp, not a no-op)' } else { '' }) }
    }
    'topmost' {
      $ok = [WpmWin]::MakeTopmostNoActivate($Hwnd)
      $ex = [WpmWin]::GetWindowLong($Hwnd, [WpmWin]::GWL_EXSTYLE)
      $isTop = ($ex -band [WpmWin]::WS_EX_TOPMOST) -ne 0
      return @{ ok = ($ok -and $isTop); op = $Op; exStyle = ('0x' + $ex.ToString('X'));
        topmost = $isTop; activated = 'no'
        reason = $(if (-not $isTop) { 'the WS_EX_TOPMOST bit is not set on the window after the call' } else { '' }) }
    }
    default {
      return @{ ok = $false; op = $Op; reason = "unknown window op '$Op'" }
    }
  }
}

# ==================================================================================================
# 0.5.0 READ PATHS: a frame the model can read, a picture whose coordinates are DATA, and a preview
# that answers in text. None of the three writes an input-queue entry or takes the focus.
# ==================================================================================================

function Get-WpmDataDir {
  # The same base the takeover latch uses (takeover.ps1 Get-WpmTakeoverLatchPath) and the host half
  # (lib/index.js abortLatchPath). One directory to open when something has to be inspected by hand.
  $base = $env:LOCALAPPDATA
  if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
  return (Join-Path $base 'wpm')
}

function Get-WpmShotsDir {
  $d = Join-Path (Get-WpmDataDir) 'shots'
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  return $d
}

function Get-WpmFrameRect {
  <#
    ONE frame rule, and the caller cannot silently get the wrong one.
    Returns @{ ok; frame='dwm'|'win32'|'none'; hr; left; top; right; bottom }.
    DWM(9 EXTENDED_FRAME_BOUNDS) is the ONLY source that agrees with the UIA children's coordinate
    space; GetWindowRect is the documented fallback for RDP/Basic-theme hosts where the DWM call
    returns a non-zero hr. Which one was used is a RETURNED FIELD, never a silent substitution.
  #>
  param([IntPtr]$Hwnd)
  $d = [WpmWin]::DwmFrame($Hwnd)
  if ($d[0] -eq 0 -and $d[3] -gt $d[1] -and $d[4] -gt $d[2]) {
    return @{ ok = $true; frame = 'dwm'; hr = 0
      left = [int]$d[1]; top = [int]$d[2]; right = [int]$d[3]; bottom = [int]$d[4] }
  }
  $w = [WpmWin]::WinRect($Hwnd)
  if ($w[0] -eq 1 -and $w[3] -gt $w[1] -and $w[4] -gt $w[2]) {
    return @{ ok = $true; frame = 'win32'; hr = [int]$d[0]
      left = [int]$w[1]; top = [int]$w[2]; right = [int]$w[3]; bottom = [int]$w[4] }
  }
  return @{ ok = $false; frame = 'none'; hr = [int]$d[0]; left = 0; top = 0; right = 0; bottom = 0 }
}

function Test-WpmFrameInsideRoot {
  <#
    The DECIDABLE frame check. "Every element rect is inside screenRect" was measured to be FALSE on
    real windows -- Chromium/Electron trees report virtualized content far outside the viewport
    (overhangs of 3px, 18px, 287px and 2720px measured here on 2026-11-23), so that rule refuses
    ordinary windows. What holds is narrower and still worth asserting: the frame we CAPTURED must lie
    inside the window's own rect as the accessibility tree reports it (the ROOT element's
    BoundingRectangle, which measures equal to GetWindowRect -- the shadow space). Measured insets on 8
    real windows: exactly 0,0,0,0 (borderless) or 8,8,8,8 (shadowed). A frame that pokes OUTSIDE the
    root means the frame came from somewhere else, and refusing there is what keeps a wrong frame from
    ever becoming a label.
  #>
  param([hashtable]$Frame, [hashtable]$RootRect, [int]$Tolerance = 2)
  $insetL = [int]$Frame.left - [int]$RootRect.left
  $insetT = [int]$Frame.top - [int]$RootRect.top
  $insetR = [int]$RootRect.right - [int]$Frame.right
  $insetB = [int]$RootRect.bottom - [int]$Frame.bottom
  $ok = ($insetL -ge -$Tolerance) -and ($insetT -ge -$Tolerance) -and
        ($insetR -ge -$Tolerance) -and ($insetB -ge -$Tolerance)
  return @{ ok = $ok; insetLeft = $insetL; insetTop = $insetT; insetRight = $insetR; insetBottom = $insetB }
}

function Get-WpmSnapshotTree {
  <#
    Walk the tree ONCE (FindAll(Descendants) + IsOffscreen), number what is visible, and hand back a
    frame the model can answer with. Measured: 816 descendants / 71 visible / 291ms on an Electron
    window, so TreeWalker (one cross-process COM round trip per node) is the wrong tool here and the
    300-element cap is deliberately loose.

    '0 element(s)' is a REAL answer on this desktop (Clash, Everything measured 0) and is reported as
    such; it deliberately does NOT reuse uia_tree_empty, whose meaning is "UI Automation is switched
    off in the application" and whose next step is relaunching the app.

    `interactableOnly` (default on) is the zero-cost first pass at a huge tree. `sinceSnapId` returns
    added/removed/changed instead of re-describing an unchanged table -- the measured cost of a
    multi-step flow is repeating the parts that did not move.
  #>
  param(
    [IntPtr]$Hwnd,
    [int]$MaxElements = 300,
    [bool]$InteractableOnly = $true,
    [string]$Intent = '',
    [string]$SinceSnapId = ''
  )
  $cap = [Math]::Max(1, [Math]::Min(5000, $MaxElements))

  # The diff base is resolved BEFORE the walk: an unknown sinceSnapId is a stale reference, not an
  # empty diff. Returning "no changes" for an id we never issued would be the most comfortable lie here.
  $base = $null
  if ($SinceSnapId) {
    foreach ($s in @($script:WpmSnapshots)) {
      if ($s -and $s.snapId -eq $SinceSnapId) { $base = $s; break }
    }
    if (-not $base) {
      return @{ ok = $false; stale = $true
        reason = "sinceSnapId '$SinceSnapId' is not a snapshot this worker still holds (it keeps the newest as a label base and the one before it as a diff base); take a new snapshot and diff against that id" }
    }
  }

  $frame = Get-WpmFrameRect $Hwnd
  if (-not $frame.ok) {
    return @{ ok = $false; stale = $false; frameCheck = 'unknown'
      reason = "no usable window frame: DwmGetWindowAttribute hr=$($frame.hr) and GetWindowRect both failed, so there is no rectangle to measure elements against" }
  }

  $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)

  # ---- THE DECIDABLE SELF-CHECK ------------------------------------------------------------------
  # The obvious invariant -- "every element rect is contained in screenRect" -- was MEASURED to be
  # false on real windows and is therefore NOT used: Chromium/Electron trees legitimately report
  # virtualized content far outside the viewport (overhangs measured 3px, 18px, 287px and 2720px on
  # this desktop, 2026-11-23), and a rule that refuses those snapshots refuses whole classes of
  # ordinary windows. What IS decidable and cheap is the relationship the two coordinate sources
  # state about the window itself: the ROOT element's rect (the tree's own claim, which measures equal
  # to GetWindowRect -- shadow space) must CONTAIN the frame we captured. Measured on 8 real windows:
  # it holds with insets of exactly 0px (borderless) or 8px/8px/8px/8px (shadowed), and a frame that
  # pokes outside the root means the frame came from somewhere else. The inset is REPORTED as data so
  # the shadow is visible instead of merely survived.
  $frameCheck = 'unknown'
  $insetL = 0; $insetT = 0; $insetR = 0; $insetB = 0
  try {
    $rb = $root.Current.BoundingRectangle
    $rootRect = @{
      left = [int][Math]::Round($rb.Left); top = [int][Math]::Round($rb.Top)
      right = [int][Math]::Round($rb.Right); bottom = [int][Math]::Round($rb.Bottom)
    }
    $inside = Test-WpmFrameInsideRoot -Frame $frame -RootRect $rootRect
    $insetL = [int]$inside.insetLeft; $insetT = [int]$inside.insetTop
    $insetR = [int]$inside.insetRight; $insetB = [int]$inside.insetBottom
    $frameCheck = if ($inside.ok) { 'pass' } else { 'fail' }
    if ($frameCheck -eq 'fail') {
      return @{ ok = $false; stale = $false; frame = $frame.frame; frameCheck = 'fail'
        reason = "frame self-check failed: the captured frame ($($frame.left),$($frame.top),$($frame.right),$($frame.bottom), source=$($frame.frame)) is not contained in the window's own rect ($($rootRect.left),$($rootRect.top),$($rootRect.right),$($rootRect.bottom)) that the accessibility tree reports. The two sources disagree about where this window is, so no label from this snapshot is safe to act on. Re-read action=windows and compare rect= with this frame" }
    }
  } catch {
    # An unreadable root rect cannot certify anything, and it must not be turned into a failure: the
    # snapshot itself may still be useful, so the check reports 'unknown' rather than 'pass'.
    $frameCheck = 'unknown'
  }

  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
  $total = $all.Count
  $pats = Get-WpmUiaCached
  $order = @('invoke', 'value', 'toggle', 'select', 'legacy')
  $rows = @()
  $truncated = $false
  $outsideFrame = 0

  for ($i = 0; $i -lt $total; $i++) {
    $el = $all[$i]
    $off = $false
    try { $off = [bool]$el.Current.IsOffscreen } catch { continue }
    if ($off) { continue }

    $ct = ''; $nm = ''; $aid = ''
    try { $ct = ([string]$el.Current.ControlType.ProgrammaticName) -replace '^ControlType\.', '' } catch { continue }
    try { $nm = [string]$el.Current.Name } catch { }
    try { $aid = [string]$el.Current.AutomationId } catch { }

    # Sub-element rects are in the DWM/real space (measured); the ROOT element is the one that reports
    # the shadow-inclusive rect, and FindAll(Descendants) never returns the root -- so nothing here
    # mixes the two spaces.
    $rc = @{ left = 0; top = 0; right = 0; bottom = 0 }
    try {
      $b = $el.Current.BoundingRectangle
      $rc = @{
        left = [int][Math]::Round($b.Left); top = [int][Math]::Round($b.Top)
        right = [int][Math]::Round($b.Right); bottom = [int][Math]::Round($b.Bottom)
      }
    } catch { }

    # A label exists to be POINTED AT inside the capture. An element with no overlap with the frame
    # cannot be clicked within it (the point-ownership assertion would refuse), so handing out a
    # number for it would hand out a trap. It is excluded and COUNTED, never silently dropped.
    $overlaps = ($rc.right -gt $frame.left) -and ($rc.left -lt $frame.right) -and
                ($rc.bottom -gt $frame.top) -and ($rc.top -lt $frame.bottom)
    if (-not $overlaps) { $outsideFrame++; continue }

    $kinds = @()
    foreach ($k in $order) {
      if (-not $pats.ContainsKey($k)) { continue }
      $obj = $null
      try { if ($el.TryGetCurrentPattern($pats[$k], [ref]$obj)) { } } catch { continue }
      if ($obj) { $kinds += $k }
    }
    if ($InteractableOnly -and $kinds.Count -eq 0) { continue }

    if ($rows.Count -ge $cap) { $truncated = $true; break }

    $rid = ''
    try { $rid = (@($el.GetRuntimeId()) -join '.') } catch { $rid = '' }

    $rows += @{
      label = ($rows.Count + 1)
      controlType = $ct
      name = $nm
      automationId = $aid
      runtimeId = $rid
      rect = $rc
      patterns = @($kinds)
    }
  }

  # ---- the delta, by UIA RuntimeId (measured stable across queries, 71/71) --------------------
  $delta = $null
  if ($base) {
    $oldByRid = @{}
    foreach ($r in @($base.elements)) { if ($r.runtimeId) { $oldByRid[$r.runtimeId] = $r } }
    $newByRid = @{}
    foreach ($r in $rows) { if ($r.runtimeId) { $newByRid[$r.runtimeId] = $r } }
    $added = @(); $removed = @(); $changed = @(); $same = 0
    foreach ($r in $rows) {
      if (-not $r.runtimeId) { continue }
      if (-not $oldByRid.ContainsKey($r.runtimeId)) { $added += $r; continue }
      $o = $oldByRid[$r.runtimeId]
      $why = @()
      if ([string]$o.name -ne [string]$r.name) { $why += 'name' }
      if ([string]$o.controlType -ne [string]$r.controlType) { $why += 'controlType' }
      if ([string]$o.automationId -ne [string]$r.automationId) { $why += 'automationId' }
      if (([int]$o.rect.left -ne [int]$r.rect.left) -or ([int]$o.rect.top -ne [int]$r.rect.top) -or
          ([int]$o.rect.right -ne [int]$r.rect.right) -or ([int]$o.rect.bottom -ne [int]$r.rect.bottom)) { $why += 'rect' }
      if ((@($o.patterns) -join ',') -ne (@($r.patterns) -join ',')) { $why += 'patterns' }
      if ($why.Count -gt 0) {
        $changed += @{ label = $r.label; controlType = $r.controlType; name = $r.name
          automationId = $r.automationId; rect = $r.rect; patterns = @($r.patterns); changed = $why }
      } else { $same++ }
    }
    foreach ($o in @($base.elements)) {
      if (-not $o.runtimeId) { continue }
      if (-not $newByRid.ContainsKey($o.runtimeId)) {
        $removed += @{ label = $o.label; controlType = $o.controlType; name = $o.name
          automationId = $o.automationId; rect = $o.rect; patterns = @($o.patterns) }
      }
    }
    $delta = @{ sinceSnapId = $base.snapId; added = @($added); removed = @($removed)
      changed = @($changed); unchanged = $same }
  }

  $script:WpmSnapSeq = $script:WpmSnapSeq + 1
  $snapId = 'snap-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '-' + $script:WpmSnapSeq
  $entry = @{
    snapId = $snapId
    hwnd = $Hwnd.ToInt64().ToString()
    frame = $frame.frame
    frameCheck = $frameCheck
    frameInset = @{ left = $insetL; top = $insetT; right = $insetR; bottom = $insetB }
    intent = $Intent
    createdAtUtcMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    total = $total
    count = $rows.Count
    outsideFrame = $outsideFrame
    truncated = $truncated
    elements = @($rows)
  }
  # Newest first. Capacity 2, for one reason each: [0] resolves LABEL references, [1] is the only
  # valid sinceSnapId. Dropping the older one is what makes a superseded snapId a reportable
  # stale_ref instead of a silent success against a frame the caller can no longer see.
  $prev = @($script:WpmSnapshots)
  $script:WpmSnapshots = @($entry) + @($prev | Select-Object -First 1)

  # The intent travels WITH the frame as a file too, so a deciding subagent (or a human reading the
  # directory afterwards) gets "what this frame was for" without the conversation around it. One file,
  # overwritten each snapshot: bounded by construction.
  try {
    $dataDir = Get-WpmDataDir
    if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
    $payload = $entry | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText((Join-Path $dataDir 'last-snapshot.json'), $payload,
      (New-Object System.Text.UTF8Encoding($false)))
  } catch { }

  return @{ ok = $true; stale = $false; snapId = $snapId; frame = $frame.frame; frameCheck = $frameCheck
    frameInset = @{ left = $insetL; top = $insetT; right = $insetR; bottom = $insetB }
    intent = $Intent; total = $total; count = $rows.Count; outsideFrame = $outsideFrame
    truncated = $truncated; elements = @($rows); delta = $delta }
}

function Resolve-WpmSnapshotLabel {
  <#
    Resolve a snapshot LABEL back to the ELEMENT (by UIA RuntimeId), so a labelled action keeps the
    silent UIA-pattern path and never degrades into a coordinate click. Every failure to resolve is a
    stale reference, not a guess: the frame the caller read is gone.
  #>
  param([IntPtr]$Hwnd, [int]$Label, [string]$SnapId)
  $snap = $null
  $all = @($script:WpmSnapshots)
  if ($all.Count -gt 0) { $snap = $all[0] }
  if (-not $snap) {
    return @{ ok = $false; stale = $true; reason = 'no snapshot has been taken by this worker; take one and act on its labels' }
  }
  if ($SnapId -and $SnapId -ne $snap.snapId) {
    return @{ ok = $false; stale = $true
      reason = "snapId '$SnapId' was superseded by '$($snap.snapId)'; a label only means something inside the frame that printed it, so take a new snapshot" }
  }
  if ([string]$snap.hwnd -ne $Hwnd.ToInt64().ToString()) {
    return @{ ok = $false; stale = $true
      reason = "the newest snapshot is of hwnd=$($snap.hwnd), not this target; take a snapshot of this window" }
  }
  $row = $null
  foreach ($r in @($snap.elements)) { if ([int]$r.label -eq $Label) { $row = $r; break } }
  if (-not $row) {
    return @{ ok = $false; stale = $true
      reason = "label $Label is not in snapshot $($snap.snapId) (it printed $($snap.count) element(s))" }
  }
  if (-not $row.runtimeId) {
    return @{ ok = $false; stale = $true
      reason = "label $Label carried no stable runtime id, so it cannot be re-found; take a new snapshot" }
  }
  $el = $null
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition)
    for ($i = 0; $i -lt $found.Count; $i++) {
      $cand = $found[$i]
      $rid = ''
      try { $rid = (@($cand.GetRuntimeId()) -join '.') } catch { continue }
      if ($rid -eq $row.runtimeId) { $el = $cand; break }
    }
  } catch {
    return @{ ok = $false; stale = $true; reason = 'the tree could not be re-walked: ' + $_.Exception.Message }
  }
  if (-not $el) {
    return @{ ok = $false; stale = $true
      reason = "the element behind label $Label is no longer in the tree; take a new snapshot" }
  }
  $pats = Get-WpmUiaCached
  $kind = 'none'
  foreach ($k in @('invoke', 'value', 'toggle', 'select', 'legacy')) {
    if (-not $pats.ContainsKey($k)) { continue }
    $obj = $null
    try { if ($el.TryGetCurrentPattern($pats[$k], [ref]$obj)) { } } catch { continue }
    if ($obj) { $kind = $k; break }
  }
  if ($kind -eq 'none') {
    return @{ ok = $false; stale = $true
      reason = "the element behind label $Label no longer exposes a usable UIA pattern; take a new snapshot" }
  }
  return @{ ok = $true; stale = $false; element = $el; patternKind = $kind; row = $row; snapId = $snap.snapId }
}

function Get-WpmScreenshot {
  <#
    CopyFromScreen over the DWM frame (or the virtual screen on explicit request) and return the
    MAPPING as data. Why the picture is not returned inline: a plugin cannot mint an inline image
    block without the host's attachment service (measured: ImageBlock needs an ImageAttachmentRef from
    an app.asar-only package), so the file is written and the caller reads it. What this action is
    really for is the second half: `scale`/`identity`/`screenRect` let a caller hand IMAGE coordinates
    back to click space:'image' and never multiply anything itself.

    scale = imagePixels / screenPixels. identity is true only when scale==1.0. Nothing is resampled
    unless maxWidth asked for it, because a resized image IS a different coordinate system.
  #>
  param([IntPtr]$Hwnd, [bool]$FullScreen = $false, [int]$MaxWidth = 0, [int]$Keep = 10)
  Add-Type -AssemblyName System.Drawing

  if ($FullScreen) {
    $vs = [WpmWin]::VirtualScreen()
    $frame = @{ ok = $true; frame = 'dwm'; hr = 0
      left = [int]$vs[0]; top = [int]$vs[1]; right = ([int]$vs[0] + [int]$vs[2]); bottom = ([int]$vs[1] + [int]$vs[3]) }
  } else {
    $frame = Get-WpmFrameRect $Hwnd
    if (-not $frame.ok) {
      return @{ ok = $false
        reason = "no usable window frame: DwmGetWindowAttribute hr=$($frame.hr) and GetWindowRect both failed" }
    }
  }

  $w = $frame.right - $frame.left
  $h = $frame.bottom - $frame.top
  if ($w -le 0 -or $h -le 0) { return @{ ok = $false; reason = "the captured rectangle is empty ($($w)x$($h))" } }

  $bmp = $null
  $resized = $null
  $hbmp = [IntPtr]::Zero
  # THE PATH IS REPORTED, NEVER SWAPPED SILENTLY. Same discipline as `frame`: 'dwm' versus 'win32' is a
  # coordinate fact, and 'bitblt' versus 'gdiplus' is a content fact (a 32bppRgb surface instead of
  # 32bppArgb, and any difference in what an occluded window paints). A caller comparing two screenshots
  # has to be able to see that the producer changed, so the field is mandatory in the result.
  $captureBackend = 'gdiplus'
  $captureNote = ''
  try {
    $capReason = ''
    try { $hbmp = [WpmWin]::CaptureBitBlt($frame.left, $frame.top, $w, $h, [ref]$capReason) }
    catch { $hbmp = [IntPtr]::Zero; $capReason = $_.Exception.Message }
    if ($hbmp -ne [IntPtr]::Zero) {
      try {
        $bmp = [System.Drawing.Image]::FromHbitmap($hbmp)
        $captureBackend = 'bitblt'
      } catch {
        # FromHbitmap can refuse (a format it cannot map). That is a capture failure, not a crash, and
        # the fallback below is the documented answer -- an exception here would turn a fast path into a
        # lost screenshot.
        $bmp = $null
        $capReason = 'FromHbitmap: ' + $_.Exception.Message
      } finally {
        [void][WpmWin]::FreeHbitmap($hbmp)
        $hbmp = [IntPtr]::Zero
      }
    }
    if (-not $bmp) {
      $captureNote = "bitblt-unavailable($capReason)"
      $bmp = New-Object System.Drawing.Bitmap($w, $h)
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      try { $g.CopyFromScreen($frame.left, $frame.top, 0, 0, (New-Object System.Drawing.Size($w, $h))) }
      finally { $g.Dispose() }
      $captureBackend = 'gdiplus'
    }

    $scale = 1.0
    $imgW = $w
    $imgH = $h
    $out = $bmp
    $cap = [Math]::Max(0, [Math]::Min(7680, $MaxWidth))
    if ($cap -gt 0 -and $w -gt $cap) {
      $imgW = $cap
      $imgH = [int][Math]::Max(1, [Math]::Round($h * ($cap / [double]$w)))
      $resized = New-Object System.Drawing.Bitmap($imgW, $imgH)
      $g2 = [System.Drawing.Graphics]::FromImage($resized)
      try {
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.DrawImage($bmp, 0, 0, $imgW, $imgH)
      } finally { $g2.Dispose() }
      $out = $resized
      $scale = [Math]::Round($imgW / [double]$w, 6)
    }

    $dir = Get-WpmShotsDir
    $script:WpmShotSeq = $script:WpmShotSeq + 1
    $shotId = 'shot-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '-' + $script:WpmShotSeq
    $file = Join-Path $dir ($shotId + '.png')
    $out.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = (Get-Item -LiteralPath $file).Length
    $keepN = [Math]::Max(1, [Math]::Min(200, $Keep))

    # Retention: newest `shotsKeep` survive, older PNGs in THIS directory are deleted. The registry is
    # pruned against the same list, so a shotId that was cleaned up resolves to stale_ref rather than
    # to a file that is no longer there.
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.png' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTimeUtc -Descending)
    for ($i = $keepN; $i -lt $files.Count; $i++) {
      try { Remove-Item -LiteralPath $files[$i].FullName -Force } catch { }
    }
    $script:WpmShots[$shotId] = @{
      shotId = $shotId; file = $file; scale = $scale; identity = ($scale -eq 1.0)
      left = [int]$frame.left; top = [int]$frame.top; right = [int]$frame.right; bottom = [int]$frame.bottom
      imageWidth = [int]$imgW; imageHeight = [int]$imgH; frame = $frame.frame
      captureBackend = $captureBackend
      createdAtUtcMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    # Drop registry entries for shots the retention pass just removed.
    $live = @{}
    for ($i = 0; $i -lt [Math]::Min($keepN, $files.Count); $i++) { $live[$files[$i].BaseName] = $true }
    foreach ($key in @($script:WpmShots.Keys)) {
      if (-not $live.ContainsKey($key)) { $script:WpmShots.Remove($key) }
    }

    return @{ ok = $true
      shotId = $shotId; file = $file
      screenRect = @{ left = [int]$frame.left; top = [int]$frame.top; right = [int]$frame.right; bottom = [int]$frame.bottom }
      imageSize = @{ width = [int]$imgW; height = [int]$imgH }
      scale = $scale; identity = ($scale -eq 1.0); frame = $frame.frame
      captureBackend = $captureBackend; captureNote = $captureNote
      dpiAware = [bool]$script:WpmDpiAware; bytes = [long]$bytes; shotsKeep = $keepN
      capturedAtUtcMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
  } finally {
    if ($hbmp -ne [IntPtr]::Zero) { [void][WpmWin]::FreeHbitmap($hbmp) }
    if ($resized) { $resized.Dispose() }
    if ($bmp) { $bmp.Dispose() }
  }
}

function Convert-WpmImagePoint {
  <#
    THE MULTIPLICATION THE MODEL MUST NOT DO. space:'image' + shotId -> a screen point, using the
    scale the screenshot itself reported. screenX = screenRect.left + round(imageX / scale), which is
    the inverse of scale = imagePixels/screenPixels; a shot that was never issued, or one the
    retention policy already deleted, answers ok=false so the caller can report stale_ref instead of
    reinterpreting image pixels as screen pixels.
  #>
  param([string]$ShotId, [int]$X, [int]$Y)
  if (-not $ShotId) { return @{ ok = $false; stale = $true; reason = 'space="image" needs a shotId: image coordinates only exist relative to a capture' } }
  if (-not $script:WpmShots.ContainsKey($ShotId)) {
    return @{ ok = $false; stale = $true
      reason = "shotId '$ShotId' is not a screenshot this worker still holds (the retention policy keeps the newest shotsKeep); take a new screenshot" }
  }
  $shot = $script:WpmShots[$ShotId]
  $scale = [double]$shot.scale
  if ($scale -le 0) { return @{ ok = $false; stale = $true; reason = "shotId '$ShotId' has a non-positive scale ($scale)" } }
  if ($X -lt 0 -or $Y -lt 0 -or $X -ge [int]$shot.imageWidth -or $Y -ge [int]$shot.imageHeight) {
    return @{ ok = $false; stale = $false
      reason = "image point ($X,$Y) is outside the captured image ($($shot.imageWidth)x$($shot.imageHeight)); an image coordinate must address a pixel that exists" }
  }
  $sx = [int]$shot.left + [int][Math]::Round($X / $scale)
  $sy = [int]$shot.top + [int][Math]::Round($Y / $scale)
  return @{ ok = $true; stale = $false; x = $sx; y = $sy; scale = $scale; shotId = $ShotId }
}

function Get-WpmPreviewAt {
  <#
    WHAT IS UNDER THAT POINT -- answered by the OS, as text. This is the confirmation step that makes
    an irreversible click reviewable without a picture: AutomationElement.FromPoint plus the
    ancestry proof the click path already uses (if the climb never meets the target root, the point
    belongs to another window and the answer is a refusal). No input queue entry, no focus change:
    the marker is drawn by the caller through overlay.ps1, which is a click-through request.
  #>
  param([IntPtr]$Hwnd, [int]$X, [int]$Y)
  $out = @{ ok = $true; outside = $false; atPoint = $false; name = ''
    controlType = ''; automationId = ''
    rect = @{ left = 0; top = 0; right = 0; bottom = 0 }
    reason = '' }
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    if (-not $root) {
      return @{ ok = $false; outside = $false; atPoint = $false; name = ''; controlType = ''
        automationId = ''; rect = @{ left = 0; top = 0; right = 0; bottom = 0 }
        reason = 'target window has no UI Automation element' }
    }
    $pt = New-Object System.Windows.Point([double]$X, [double]$Y)
    $hitEl = [System.Windows.Automation.AutomationElement]::FromPoint($pt)
    if (-not $hitEl) {
      $out.reason = 'nothing at that point is exposed to UI Automation'
      return $out
    }
    $out.atPoint = $true

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $el = $hitEl
    $sawRoot = $false
    $hop = 0
    while ($el -and $hop -lt 24) {
      if ($el -eq $root) { $sawRoot = $true; break }
      try { $el = $walker.GetParent($el) } catch { $el = $null }
      $hop++
    }
    if (-not $sawRoot) {
      return @{ ok = $false; outside = $true; atPoint = $true; name = ''; controlType = ''
        automationId = ''; rect = @{ left = 0; top = 0; right = 0; bottom = 0 }
        reason = 'the element under that point does not belong to the target window' }
    }

    try { $out.controlType = ([string]$hitEl.Current.ControlType.ProgrammaticName) -replace '^ControlType\.', '' } catch { }
    try { $out.name = [string]$hitEl.Current.Name } catch { }
    try { $out.automationId = [string]$hitEl.Current.AutomationId } catch { }
    try {
      $b = $hitEl.Current.BoundingRectangle
      $out.rect = @{
        left = [int][Math]::Round($b.Left); top = [int][Math]::Round($b.Top)
        right = [int][Math]::Round($b.Right); bottom = [int][Math]::Round($b.Bottom)
      }
    } catch { }
    return $out
  } catch {
    return @{ ok = $false; outside = $false; atPoint = $false; name = ''; controlType = ''
      automationId = ''; rect = @{ left = 0; top = 0; right = 0; bottom = 0 }
      reason = 'the point probe threw: ' + $_.Exception.Message }
  }
}
