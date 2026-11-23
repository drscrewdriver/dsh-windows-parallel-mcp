# probe-hittest-children.ps1 -- P0 probe for R3: can a WPF window be click-through on empty space
# while keeping a real, clickable button? (spec.md §3 task_4 / findings §G6)
#
# TWO MECHANISMS ARE TESTED, because the first one was measured to fail:
#   1. HwndSource hook returning HTTRANSPARENT -- the hook RECEIVES WM_NCHITTEST (counted), but its
#      return value does not reach the window's hit-testing: SendMessage(WM_NCHITTEST) still answers
#      HTCLIENT. Recorded as a measured dead end, not as a preference.
#   2. A WNDPROC subclass (SetWindowLongPtrW) that answers HTTRANSPARENT for points outside the
#      button's rect and defers to the previous proc everywhere else. This is what the HUD will use.
#
# The probe prints both answers plus WindowFromPoint at both points, so "passes the click through"
# is a syscall observation rather than a claim about how the window looks.
Set-StrictMode -Version 2.0
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

if (-not ('WpmHitProbe' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WpmHitProbe {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);

    public const uint WM_NCHITTEST = 0x0084;
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOPMOST = 0x00000008;
    public const int WS_EX_NOACTIVATE = 0x08000000;

    public static IntPtr HitTest(IntPtr h, int x, int y) {
        IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
        return SendMessage(h, WM_NCHITTEST, IntPtr.Zero, lp);
    }
    public static IntPtr WindowFromPointXY(int x, int y) {
        POINT p; p.X = x; p.Y = y;
        return WindowFromPoint(p);
    }
    public static IntPtr RootOf(IntPtr h) { return GetAncestor(h, 2); }
}

// The mechanism the HUD will actually ship: answer HTTRANSPARENT outside the live control zone and
// defer to WPF everywhere else. CallWindowProc keeps WPF's own hit-testing intact inside the zone.
public static class WpmHitSub {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int idx, IntPtr proc);
    [DllImport("user32.dll")] public static extern IntPtr CallWindowProc(IntPtr prev, IntPtr h, uint m, IntPtr w, IntPtr l);

    static IntPtr prev = IntPtr.Zero;
    static RECT zone;
    static WndProc keepAlive;
    public static int HitCount = 0;
    public static int TransparentCount = 0;

    public static bool Install(IntPtr h, int left, int top, int right, int bottom) {
        zone = new RECT(); zone.Left = left; zone.Top = top; zone.Right = right; zone.Bottom = bottom;
        keepAlive = new WndProc(Proc);
        prev = SetWindowLongPtr(h, -4, Marshal.GetFunctionPointerForDelegate(keepAlive));
        return prev != IntPtr.Zero;
    }
    public static void SetZone(int left, int top, int right, int bottom) {
        zone = new RECT(); zone.Left = left; zone.Top = top; zone.Right = right; zone.Bottom = bottom;
    }
    static IntPtr Proc(IntPtr h, uint m, IntPtr w, IntPtr l) {
        if (m == 0x0084) {
            HitCount++;
            long packed = (long)l;
            int x = (short)(packed & 0xFFFF);
            int y = (short)((packed >> 16) & 0xFFFF);
            if (!(x >= zone.Left && x <= zone.Right && y >= zone.Top && y <= zone.Bottom)) {
                TransparentCount++;
                return new IntPtr(-1);
            }
        }
        return CallWindowProc(prev, h, m, w, l);
    }
}
'@
}

$script:probeResult = @{ ok = $false }
$script:buttonRect = $null

$win = New-Object System.Windows.Window
$win.Title = 'wpm-hittest-probe'
$win.WindowStyle = 'None'
$win.ShowActivated = $false
$win.Focusable = $false
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.Width = 420; $win.Height = 140
$win.Left = 260; $win.Top = 260
$win.Background = [System.Windows.Media.Brushes]::Black
$win.Opacity = 0.9

$grid = New-Object System.Windows.Controls.Grid
$btn = New-Object System.Windows.Controls.Button
$btn.Content = 'STOP'
$btn.Width = 110; $btn.Height = 44
$btn.HorizontalAlignment = 'Right'
$btn.VerticalAlignment = 'Bottom'
$btn.Margin = '0,0,16,16'
[void]$grid.Children.Add($btn)
$win.Content = $grid
$win.Show()
$hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle

$win.Dispatcher.Invoke([Action]{
    $pt = $btn.PointToScreen((New-Object System.Windows.Point(5, 5)))
    $script:buttonRect = @{ Left = [int]$pt.X; Top = [int]$pt.Y; Right = [int]($pt.X + $btn.ActualWidth); Bottom = [int]($pt.Y + $btn.ActualHeight) }
})
Start-Sleep -Milliseconds 300

$installed = [WpmHitSub]::Install($hwnd, $script:buttonRect.Left, $script:buttonRect.Top, $script:buttonRect.Right, $script:buttonRect.Bottom)

$r = New-Object 'WpmHitProbe+RECT'
[void][WpmHitProbe]::GetWindowRect($hwnd, [ref]$r)
$bx = [int](($script:buttonRect.Left + $script:buttonRect.Right) / 2)
$by = [int](($script:buttonRect.Top + $script:buttonRect.Bottom) / 2)
$ex = [WpmHitProbe]::GetWindowLong($hwnd, [WpmHitProbe]::GWL_EXSTYLE)

# Empty area of our own window: must answer HTTRANSPARENT and WindowFromPoint must NOT be us.
$emptyX = $r.Left + 20; $emptyY = $r.Top + 20
$emptyMsg = [WpmHitProbe]::HitTest($hwnd, $emptyX, $emptyY).ToInt32()
$emptyWindow = [WpmHitProbe]::WindowFromPointXY($emptyX, $emptyY)
# The button: must answer HTCLIENT and belong to us (WPF's own child handling continues).
$btnMsg = [WpmHitProbe]::HitTest($hwnd, $bx, $by).ToInt32()
$btnWindow = [WpmHitProbe]::WindowFromPointXY($bx, $by)

$script:probeResult = @{
    ok = $true
    subclassInstalled = [bool]$installed
    hwnd = [int64]$hwnd
    exStyle = ('0x{0:X8}' -f $ex)
    topmost = [bool]($ex -band [WpmHitProbe]::WS_EX_TOPMOST)
    noActivate = [bool]($ex -band [WpmHitProbe]::WS_EX_NOACTIVATE)
    rect = "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
    buttonRect = $script:buttonRect
    emptyPoint = "$emptyX,$emptyY"
    emptyHitTestCode = $emptyMsg
    emptyHitTestIsTransparent = ($emptyMsg -eq -1)
    emptyWindowFromPoint = if ($emptyWindow -eq $hwnd) { 'self' } else { [int64]$emptyWindow }
    buttonPoint = "$bx,$by"
    buttonHitTestCode = $btnMsg
    buttonHitTestIsClient = ($btnMsg -eq 1)
    buttonWindowFromPoint = if ($btnWindow -eq $hwnd) { 'self' } else { [int64]$btnWindow }
    subclassHitCount = [WpmHitSub]::HitCount
    subclassTransparentCount = [WpmHitSub]::TransparentCount
}

$win.Close()
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
$script:probeResult | ConvertTo-Json -Compress -Depth 6
exit 0
