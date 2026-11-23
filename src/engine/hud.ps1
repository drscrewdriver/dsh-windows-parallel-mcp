# hud.ps1 -- the R3 safety surface: a three-phase window that says what the engine is doing with the
# owner's mouse/keyboard/focus, offers a real stop button, and owns the global abort chord. (spec.md §2)
#
# WHY THIS IS A HARD PREREQUISITE RATHER THAN A NICETY. R3 lets the engine move the real cursor and type
# into the foreground window. Both are invisible cost the owner pays; a takeover without a surface would
# mean the pointer moves and text appears with no way to tell "an agent did that" from "the machine did
# something". So: no HUD, no takeover -- enforced twice (engine refuses before any primitive call;
# scripts/check-takeover-path.mjs G3 asserts the call order is structural).
#
# ARCHITECTURE IS BORROWED, DELIBERATELY: an STA runspace + WPF + a DispatcherTimer pump that reads and
# writes ONLY [WpmCtl] fields. overlay.ps1 measured why (overlay.ps1:163-176): a cross-thread
# Dispatcher.Invoke of a PowerShell scriptblock cost 1818ms and sometimes never returned, because the
# pump thread is already inside Dispatcher.Run(). Three volatile fields cost nothing.
#
# TWO MEASURED DETAILS THAT CHANGED THE DESIGN (findings §G6, scripts/probe-hittest-children.ps1):
#   * the HwndSource hook DOES receive WM_NCHITTEST but its return value does not reach hit-testing
#     (empty point still answered HTCLIENT). So click-through is done with a WNDPROC subclass instead:
#     HTTRANSPARENT outside the button's rect, CallWindowProc inside it. Measured after the change:
#     empty point -> -1 and WindowFromPoint no longer returns this window; button point -> 1.
#   * WS_EX_NOACTIVATE + ShowActivated=false is what keeps the HUD from stealing the foreground while
#     the button stays clickable (measured: GetForegroundWindow unchanged across Show()).
#
# NO WATCHDOG, NO AUTO-CLOSE LOOP. The engine owns the lifecycle: it starts the HUD for one action and
# stops it in its own finally block. A window that decided on its own to shut down mid-action would be a
# second owner of the abort decision, which is exactly the bug the pause-flag comments elsewhere warn
# about.

Set-StrictMode -Version 2.0

if (-not ('WpmCtl' -as [type])) {
  . (Join-Path $PSScriptRoot 'win.ps1')
}

if (-not (Get-Variable -Name WpmHudRunspace -Scope Script -ErrorAction SilentlyContinue)) {
  $script:WpmHudRunspace = $null
  $script:WpmHudPowerShell = $null
  $script:WpmHudHandle = $null
}
$script:WpmHudHotkeyId = 0xB002

# Ctrl+Alt+Q is the PAUSE key and is already owned on this desktop; the abort chord needs its own space.
# The candidate table exists for the same reason overlay.ps1 has one: whatever registers is reported, so
# the owner reads the key that actually works instead of the one the docs promise.
$script:WpmAbortChords = @(
  @{ label = 'Ctrl+Alt+X';       mods = 0x0003; vk = 0x58 },
  @{ label = 'Ctrl+Alt+Z';       mods = 0x0003; vk = 0x5A },
  @{ label = 'Ctrl+Alt+C';       mods = 0x0003; vk = 0x43 },
  @{ label = 'Ctrl+Alt+V';       mods = 0x0003; vk = 0x56 },
  @{ label = 'Ctrl+Alt+B';       mods = 0x0003; vk = 0x42 },
  @{ label = 'Ctrl+Alt+N';       mods = 0x0003; vk = 0x4E },
  @{ label = 'Ctrl+Shift+X';     mods = 0x0006; vk = 0x58 },
  @{ label = 'Ctrl+Alt+Shift+X'; mods = 0x0007; vk = 0x58 }
)

if (-not ('WpmHud' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WpmHud
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    public delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);

    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int idx, IntPtr proc);
    [DllImport("user32.dll")] public static extern IntPtr CallWindowProc(IntPtr prev, IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    public const uint WM_NCHITTEST = 0x0084;
    public const int HTTRANSPARENT = -1;
    public const int SM_CXSCREEN = 0;
    public const int SM_CYSCREEN = 1;

    static IntPtr prev = IntPtr.Zero;
    static RECT zone;
    static WndProc keepAlive;
    public static int HitCount = 0;

    // Click-through outside the control zone, WPF's own hit-testing inside it. Installed AFTER Show()
    // so the button's physical rect is already known.
    public static bool InstallHitZone(IntPtr h, int left, int top, int right, int bottom) {
        zone = new RECT(); zone.Left = left; zone.Top = top; zone.Right = right; zone.Bottom = bottom;
        keepAlive = new WndProc(Proc);
        prev = SetWindowLongPtr(h, -4, Marshal.GetFunctionPointerForDelegate(keepAlive));
        return prev != IntPtr.Zero;
    }
    static IntPtr Proc(IntPtr h, uint m, IntPtr w, IntPtr l) {
        if (m == WM_NCHITTEST) {
            HitCount++;
            long packed = (long)l;
            int x = (short)(packed & 0xFFFF);
            int y = (short)((packed >> 16) & 0xFFFF);
            if (!(x >= zone.Left && x <= zone.Right && y >= zone.Top && y <= zone.Bottom)) return new IntPtr(HTTRANSPARENT);
        }
        return CallWindowProc(prev, h, m, w, l);
    }
    public static IntPtr HitTest(IntPtr h, int x, int y) {
        IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
        return SendMessage(h, WM_NCHITTEST, IntPtr.Zero, lp);
    }
    public static IntPtr WindowAt(int x, int y) { POINT p; p.X = x; p.Y = y; return WindowFromPoint(p); }
}
'@
}

$script:WpmHudBody = @'
param([string]$Action, [int]$MaxMs, [int]$ArmMs, [int]$HotkeyId, [object[]]$Chords)
try {
  Add-Type -AssemblyName PresentationFramework
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase

  $win = [System.Windows.Window]::new()
  $win.Title = 'WpmHud'
  $win.WindowStyle = [System.Windows.WindowStyle]::None
  $win.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $win.ShowActivated = $false        # WPF half of NOACTIVATE: Show() must not steal the foreground
  $win.ShowInTaskbar = $false
  $win.Topmost = $true
  $win.Width = 470.0
  $win.Height = 104.0
  $win.Left = -3000.0
  $win.Top = -3000.0
  $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
  # The surface colour is a PHASE SIGNAL, not decoration (see the pump). It starts on the arming tint so a
  # window that somehow never gets a pump tick is still telling the truth about what it is waiting for.
  $win.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(58, 44, 12))
  $win.Opacity = 0.94

  # THREE COLUMNS: a 5px accent bar, the text, the button. The bar is the second channel for the phase
  # colour, because a tinted background alone is easy to miss when the window is 470x104 at the screen edge
  # and the owner is looking at the target window rather than at the HUD.
  $grid = [System.Windows.Controls.Grid]::new()
  $grid.Margin = [System.Windows.Thickness]::new(0.0, 0.0, 14.0, 0.0)
  $colBar = [System.Windows.Controls.ColumnDefinition]::new()
  $colBar.Width = [System.Windows.GridLength]::new(5.0)
  $colA = [System.Windows.Controls.ColumnDefinition]::new()
  $colA.Width = [System.Windows.GridLength]::new(1.0, [System.Windows.GridUnitType]::Star)
  $colB = [System.Windows.Controls.ColumnDefinition]::new()
  $colB.Width = [System.Windows.GridLength]::Auto
  [void]$grid.ColumnDefinitions.Add($colBar)
  [void]$grid.ColumnDefinitions.Add($colA)
  [void]$grid.ColumnDefinitions.Add($colB)

  $bar = [System.Windows.Controls.Border]::new()
  $bar.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(240, 173, 24))
  [System.Windows.Controls.Grid]::SetColumn($bar, 0)
  [void]$grid.Children.Add($bar)

  $tb = [System.Windows.Controls.TextBlock]::new()
  $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $tb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $tb.Foreground = [System.Windows.Media.Brushes]::White
  $tb.FontSize = 13.0
  $tb.Text = 'WPM'
  $tb.Margin = [System.Windows.Thickness]::new(14.0, 10.0, 10.0, 10.0)
  [System.Windows.Controls.Grid]::SetColumn($tb, 1)
  [void]$grid.Children.Add($tb)

  $btn = [System.Windows.Controls.Button]::new()
  $btn.Content = '中止'
  $btn.Width = 92.0
  $btn.Height = 40.0
  $btn.FontSize = 13.0
  $btn.Focusable = $false
  $btn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $btn.Margin = [System.Windows.Thickness]::new(0.0, 0.0, 0.0, 0.0)
  [System.Windows.Controls.Grid]::SetColumn($btn, 2)
  [void]$grid.Children.Add($btn)

  $win.Content = $grid
  $win.Show()
  $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
  [WpmCtl]::HudHwnd = [int64]$hwnd

  # Topmost + no-activate, explicitly (the measured promise is the ex-style read-back, not the look).
  $bits = [WpmWin]::WS_EX_TOPMOST -bor [WpmWin]::WS_EX_NOACTIVATE
  [void][WpmWin]::AddExStyles($hwnd, $bits)

  # Physical placement bottom-right. WPF's Left/Top are device independent and did not agree with this
  # desktop at 150% (overlay.ps1 recorded marker at (303,263) for a target of (470,410)), so placement
  # is SetWindowPos in physical pixels after reading the real rect once.
  $rc0 = New-Object 'WpmWin+RECT'
  [void][WpmWin]::GetWindowRect([IntPtr]$hwnd, [ref]$rc0)
  $pw = [int]($rc0.Right - $rc0.Left); $ph = [int]($rc0.Bottom - $rc0.Top)
  if ($pw -le 0) { $pw = 470 }
  if ($ph -le 0) { $ph = 104 }
  $screenW = [WpmHud]::GetSystemMetrics([WpmHud]::SM_CXSCREEN)
  $screenH = [WpmHud]::GetSystemMetrics([WpmHud]::SM_CYSCREEN)
  [void][WpmWin]::MoveNoActivate([IntPtr]$hwnd, ($screenW - $pw - 24), ($screenH - $ph - 64), $pw, $ph)

  # Click-through outside the button. Measured in scripts/probe-hittest-children.ps1.
  $bp = $btn.PointToScreen([System.Windows.Point]::new(0.0, 0.0))
  $bw = [int]$btn.ActualWidth; $bh = [int]$btn.ActualHeight
  if ($bw -le 0) { $bw = 92 }
  if ($bh -le 0) { $bh = 40 }
  $hitOk = [WpmHud]::InstallHitZone([IntPtr]$hwnd, [int]$bp.X, [int]$bp.Y, [int]($bp.X + $bw), [int]($bp.Y + $bh))

  $hkOk = $false
  $hkLabel = ''
  foreach ($c in $Chords) {
    if ([WpmWin]::RegisterHotKey($hwnd, $HotkeyId, [uint32]$c.mods, [uint32]$c.vk)) {
      $hkOk = $true; $hkLabel = [string]$c.label; break
    }
  }
  [WpmCtl]::AbortChordOk = [bool]$hkOk
  [WpmCtl]::AbortChordLabel = $hkLabel

  $src = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
  if ($src) {
    $hkId = $HotkeyId
    $hook = [System.Windows.Interop.HwndSourceHook] {
      param($h, $m, $wp, $lp, [ref]$handled)
      if ($m -eq [WpmWin]::WM_HOTKEY -and [int]$wp -eq $hkId) {
        [WpmCtl]::TakeoverAbort = $true
        $handled.Value = $true
        return [IntPtr]::Zero
      }
      $handled.Value = $false
      return [IntPtr]::Zero
    }
    [void]$src.AddHook($hook)
  }

  $btn.Add_Click({ [WpmCtl]::TakeoverAbort = $true })

  # THE PUMP. 50ms, reads fields, writes pixels. Nothing is marshalled from another thread.
  $lastPhase = ''
  $pump = [System.Windows.Threading.DispatcherTimer]::new()
  $pump.Interval = [TimeSpan]::FromMilliseconds(50)
  $pump.Add_Tick({
    $phase = [string][WpmCtl]::HudPhase
    $act = [string][WpmCtl]::HudAction
    $elapsed = [int][WpmCtl]::HudElapsedMs
    $max = [int][WpmCtl]::HudMaxMs
    $injected = [int][WpmCtl]::InjectedChars
    $chord = [string][WpmCtl]::AbortChordLabel
    $secs = [Math]::Round($elapsed / 1000.0, 1)
    $maxSecs = [Math]::Round($max / 1000.0, 1)
    # THE THREE PHASES MUST BE TELLABLE APART FROM ACROSS THE ROOM, not just by reading the words.
    # The owner's attention is on the target window while an agent borrows their pointer, so the phase is
    # encoded TWICE: the whole surface tint, and a 5px accent bar (a tint alone is easy to miss at the
    # screen edge). Colours are chosen for meaning rather than prettiness -- amber = not yet, red = now,
    # green = over -- and the accent stays the most saturated element so it reads at a glance.
    if ($phase -eq 'arming') {
      # AMBER: about to borrow. Nothing has moved yet; this is the cancellable window.
      $win.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(58, 44, 12))
      $bar.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(240, 173, 24))
      $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(255, 216, 138))
      $chordLine = if ($chord) { '中断键 ' + $chord + ' 可取消' } else { '中断键不可用，请点按钮' }
      $tb.Text = '即将使用你的鼠标/键盘/焦点 · ' + $act + [char]0x000A + $chordLine
      $btn.Content = '取消'
      $btn.IsEnabled = $true
    } elseif ($phase -eq 'active') {
      # RED: the pointer/focus are actually held. The one state that costs the owner something right now.
      $win.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(58, 18, 18))
      $bar.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(232, 64, 64))
      $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(255, 190, 190))
      $tb.Text = '占用中 · ' + $act + [char]0x000A + ('已用 ' + $secs.ToString() + 's / 上限 ' + $maxSecs.ToString() + 's') + [char]0x000A + ('已注入 ' + $injected.ToString() + ' 字')
      $btn.Content = '停止'
      $btn.IsEnabled = $true
    } else {
      # GREEN: returned. A completed state that says "nothing is being held" without needing to be read.
      $win.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(14, 46, 30))
      $bar.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(52, 199, 123))
      $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(178, 240, 205))
      $tb.Text = '已归还：光标已复位'
      $btn.Content = '完成'
      $btn.IsEnabled = $false
    }
    $lastPhase = $phase
  })
  $pump.Start()

  [WpmCtl]::Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
  [WpmCtl]::Window = $win
  [WpmCtl]::Timer = $pump
  [WpmCtl]::HudOn = $true
  [WpmCtl]::Reason = if ($hitOk) { '' } else { 'WNDPROC subclass failed; the HUD is hit-testable everywhere (degraded)' }

  [System.Windows.Threading.Dispatcher]::Run()
} catch {
  [WpmCtl]::Reason = $_.Exception.Message
} finally {
  [WpmCtl]::HudOn = $false
  [WpmCtl]::HudPhase = ''
  [WpmCtl]::HudHwnd = [int64]0
  [WpmCtl]::AbortChordOk = $false
  [WpmCtl]::AbortChordLabel = ''
  [WpmCtl]::Window = $null
  [WpmCtl]::Timer = $null
  [WpmCtl]::Dispatcher = $null
}
'@

function Start-WpmHud {
  param([string]$Action = 'action', [int]$MaxMs = 10000, [int]$ArmMs = 800, [int]$WaitMs = 3000)
  if ($script:WpmHudRunspace -and $script:WpmHudRunspace.RunspaceStateInfo.State -eq 'Opened') {
    return @{ started = $false; ready = [bool][WpmCtl]::HudOn; reason = 'already running' }
  }
  [WpmCtl]::Reason = ''
  [WpmCtl]::HudPhase = 'arming'
  [WpmCtl]::HudAction = $Action
  [WpmCtl]::HudMaxMs = $MaxMs
  [WpmCtl]::HudElapsedMs = 0
  [WpmCtl]::InjectedChars = 0
  $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
  $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
  $rs.ApartmentState = [System.Threading.ApartmentState]::STA
  $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::Default
  $rs.Open()
  if ($rs.RunspaceStateInfo.State -ne 'Opened') {
    return @{ started = $false; ready = $false; reason = "runspace failed to open: $($rs.RunspaceStateInfo)" }
  }
  $ps = [PowerShell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript($script:WpmHudBody).AddArgument($Action).AddArgument($MaxMs).AddArgument($ArmMs).AddArgument($script:WpmHudHotkeyId).AddArgument($script:WpmAbortChords)
  $script:WpmHudHandle = $ps.BeginInvoke()
  $script:WpmHudRunspace = $rs
  $script:WpmHudPowerShell = $ps
  $st = Get-WpmHudState -WaitMs $WaitMs
  return @{ started = [bool]$st.running; ready = [bool]$st.running; reason = [string]$st.reason; state = $st }
}

function Get-WpmHudState {
  # Wait for HudOn -- the same flag the readiness verdict uses. A budget that expired mid-init is
  # 'starting', not 'dead': the caller can tell a slow start from a body that threw (overlay.ps1:250-262).
  param([int]$WaitMs = 2500)
  $deadline = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $WaitMs
  while ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $deadline -and -not [WpmCtl]::HudOn) {
    Start-Sleep -Milliseconds 50
  }
  $hwnd = [WpmCtl]::HudHwnd
  $ex = 0
  if ($hwnd -ne 0) { $ex = [WpmWin]::GetWindowLong([IntPtr]$hwnd, [WpmWin]::GWL_EXSTYLE) }
  return @{
    running = [bool][WpmCtl]::HudOn
    starting = (-not [WpmCtl]::HudOn) -and ($script:WpmHudHandle -ne $null) -and (-not $script:WpmHudHandle.AsyncWaitHandle.WaitOne(0))
    hwnd = [string]$hwnd
    phase = [string][WpmCtl]::HudPhase
    abortChordRegistered = [bool][WpmCtl]::AbortChordOk
    abortChordLabel = [string][WpmCtl]::AbortChordLabel
    injectedChars = [int][WpmCtl]::InjectedChars
    abortRequested = [bool][WpmCtl]::TakeoverAbort
    reason = [string][WpmCtl]::Reason
    exStyle = '0x{0:X8}' -f $ex
    topmost = [bool]($ex -band [WpmWin]::WS_EX_TOPMOST)
    noActivate = [bool]($ex -band [WpmWin]::WS_EX_NOACTIVATE)
    transparent = [bool]($ex -band [WpmWin]::WS_EX_TRANSPARENT)
    foregroundNow = [WpmWin]::Fg()
  }
}

function Test-WpmHudReady {
  return [bool]([WpmCtl]::HudOn -and [WpmCtl]::HudHwnd -ne 0)
}

function Set-WpmHudPhase {
  # A REQUEST, not an action: three field writes, applied by the HUD's own pump. Called on every phase
  # change and every 50ms while active (for the elapsed clock).
  param([ValidateSet('arming', 'active', 'done')][string]$Phase, [string]$Action = '', [int]$MaxMs = -1, [int]$ElapsedMs = -1)
  [WpmCtl]::HudPhase = $Phase
  if ($Action) { [WpmCtl]::HudAction = $Action }
  if ($MaxMs -ge 0) { [WpmCtl]::HudMaxMs = $MaxMs }
  if ($ElapsedMs -ge 0) { [WpmCtl]::HudElapsedMs = $ElapsedMs }
  return @{ phase = $Phase; hudOn = [bool][WpmCtl]::HudOn }
}

function Stop-WpmHud {
  param([int]$WaitMs = 2500)
  $hwnd = [WpmCtl]::HudHwnd
  $posted = $false
  if ($hwnd -ne 0) {
    try { $posted = [bool][WpmWin]::PostMessageW([IntPtr]$hwnd, [uint32][WpmWin]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) } catch { $posted = $false }
  }
  $completed = $false
  if ($script:WpmHudHandle) {
    $spin = 0
    while (-not $script:WpmHudHandle.IsCompleted -and $spin -lt 6) { Start-Sleep -Milliseconds 50; $spin++ }
    $completed = [bool]$script:WpmHudHandle.IsCompleted
  }
  if (-not $completed) {
    $d = [WpmCtl]::Dispatcher
    if ($d) { try { [void]$d.InvokeShutdown() } catch { } }
    $spin = 0
    while ($script:WpmHudHandle -and -not $script:WpmHudHandle.IsCompleted -and $spin -lt 20) { Start-Sleep -Milliseconds 25; $spin++ }
    $completed = [bool]($script:WpmHudHandle -and $script:WpmHudHandle.IsCompleted)
  }
  if ($script:WpmHudHandle) { try { $script:WpmHudPowerShell.EndInvoke($script:WpmHudHandle) | Out-Null } catch { } }
  if ($script:WpmHudPowerShell) { try { $script:WpmHudPowerShell.Dispose() } catch { }; $script:WpmHudPowerShell = $null }
  if ($script:WpmHudRunspace) { try { $script:WpmHudRunspace.Dispose() } catch { }; $script:WpmHudRunspace = $null }
  $script:WpmHudHandle = $null
  $st = Get-WpmHudState -WaitMs 150
  if (-not $completed) {
    [WpmCtl]::HudOn = $false
    [WpmCtl]::HudPhase = ''
    [WpmCtl]::HudHwnd = [int64]0
    [WpmCtl]::AbortChordOk = $false
    [WpmCtl]::AbortChordLabel = ''
    [WpmCtl]::Window = $null
    [WpmCtl]::Timer = $null
    [WpmCtl]::Dispatcher = $null
    $st = Get-WpmHudState -WaitMs 100
    $st.reason = 'hud pipeline did not end within the bound; state cleared by Stop-WpmHud'
  }
  return @{ stopped = $true; completed = $completed; posted = $posted; state = $st }
}
