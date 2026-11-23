# overlay.ps1 -- the product's visible surface: an AI marker that never takes the foreground,
# and a global hotkey that pauses the engine server-side. (task_54)
#
# WHAT THIS IS FOR. Two README claims need a real surface:
#   * "AI cursor is a click-through topmost overlay, not a system cursor" (R2.4) -- the trio
#     WS_EX_TOPMOST + WS_EX_NOACTIVATE + WS_EX_TRANSPARENT must exist and be MEASURED: ex-style
#     read-back, GetForegroundWindow unchanged across Show(), WindowFromPoint passing through the
#     marker (test/overlay-test.ps1 does all three).
#   * "the owner pauses explicitly and the SERVER refuses" (R2.5) -- one global key from ANY window
#     flips the engine's own pause flag. The flag lives in [WpmCtl] (a static, process-wide holder),
#     not in a script variable: the hotkey fires on the overlay's thread while actions run on the
#     worker's main thread, and two copies of one switch is the bug pattern this repo keeps meeting.
#
# WHY A RUNSPACE AND NOT A RAW .NET THREAD. Measured, three times over, before this shape won:
#   * [System.Threading.Thread]::new($scriptblock) -- a PowerShell scriptblock is NOT a
#     ParameterizedThreadStart; the cast produces a delegate that dies at invoke time and the
#     thread runs NOTHING (reason stayed empty, hwnd stayed 0, exit code 2).
#   * SetApartmentState on a Thread object -- returns false here; the apartment never sticks.
#   * CreateRunspace([ApartmentState]) -- no such overload on PS 5.1.
# What works (verified in .tmp before it was deleted): InitialSessionState.CreateDefault2 ->
# CreateRunspace($iss) -> $rs.ApartmentState = STA -> Open. The runspace owns its pipeline thread,
# WPF shows a window on it, and types compiled by the main thread ([WpmCtl]/[WpmWin]) are
# process-wide and reachable. The body therefore lives in a here-string compiled INSIDE the
# runspace -- no cross-thread scriptblock capture at all, which kills the whole GetNewClosure
# hazard class in this file.
#
# THREADING RULE (unchanged): the WPF window is touched only on its own thread. The main thread
# goes through [WpmCtl]::Dispatcher.Invoke.

Set-StrictMode -Version 2.0

if (-not ('WpmCtl' -as [type])) {
  . (Join-Path $PSScriptRoot 'win.ps1')
}

# IDEMPOTENT INITIALISATION. This file is dot-sourced again on every `overlay`/`marker` request
# (worker.ps1 does that so a fresh process can answer them), and the first version reset the
# runspace/handle to $null at the top of every load. The overlay kept running -- the WPF thread
# does not care about our variables -- but the caller lost the handle it needs to EndInvoke, so
# Stop-WpmOverlay could not see the pipeline end and had to fall back to the hard bound. Measured
# cost before this guard: `marker` 1844ms and `overlay off` 2618ms over the real worker protocol
# (.tmp/worker-overlay.mjs), against a few ms for the same calls in one dot-sourced process.
if (-not (Get-Variable -Name WpmOvRunspace -Scope Script -ErrorAction SilentlyContinue)) {
  $script:WpmOvRunspace = $null
  $script:WpmOvPowerShell = $null
  $script:WpmOvHandle = $null
}
$script:WpmHotkeyId = 0xB001

# The documented chord comes first, then fallbacks -- because the documented one is not always
# available. Measured on this machine (scripts/hotkey-availability.ps1): Ctrl+Alt+Q is TAKEN by
# another app (Win32 1409, ERROR_HOTKEY_ALREADY_REGISTERED) while all seven other candidates are
# free. Shipping only Ctrl+Alt+Q means the pause switch silently does not exist on some desktops,
# and the alternative -- one global key quietly not working -- is the failure mode R2.5 forbids.
# Whatever registers is written to [WpmCtl]::HotkeyLabel and surfaced by wpm_status.
$script:WpmHotkeyChords = @(
  @{ label = 'Ctrl+Alt+Q';       mods = 0x0003; vk = 0x51 },   # MOD_CONTROL|MOD_ALT
  @{ label = 'Ctrl+Alt+W';       mods = 0x0003; vk = 0x57 },
  @{ label = 'Ctrl+Alt+P';       mods = 0x0003; vk = 0x50 },
  @{ label = 'Ctrl+Alt+Space';   mods = 0x0003; vk = 0x20 },
  @{ label = 'Ctrl+Shift+Q';     mods = 0x0006; vk = 0x51 },   # MOD_CONTROL|MOD_SHIFT
  @{ label = 'Ctrl+Alt+Shift+Q'; mods = 0x0007; vk = 0x51 }
)

$script:WpmOverlayBody = @'
param([int]$MarkerSize, [int]$HotkeyId, [object[]]$Chords)
try {
  Add-Type -AssemblyName PresentationFramework
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase

  $win = [System.Windows.Window]::new()
  $win.Title = 'WpmOverlay'
  $win.WindowStyle = [System.Windows.WindowStyle]::None
  $win.AllowsTransparency = $true
  $win.ShowActivated = $false     # WPF-side half of NOACTIVATE: Show() must not steal foreground
  $win.Focusable = $false
  $win.IsHitTestVisible = $false
  $win.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $win.Width = [double]$MarkerSize
  $win.Height = [double]$MarkerSize
  $win.Left = -2000.0
  $win.Top = -2000.0
  $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
  $win.ShowInTaskbar = $false
  $win.Topmost = $true
  # THE MARKER HAD A WHITE SQUARE BEHIND IT, and the cause was an omission, not a style: AllowsTransparency
  # makes the window's pixels able to show what is underneath, but a WPF Window's DEFAULT background is
  # SystemColors.WindowBrush (white), so the 22px window painted an opaque white tile and the ring sat
  # inside it. Only the ellipse is drawn; the rest of the surface must be explicitly transparent or it
  # keeps the default brush. (hud.ps1 always set its background, which is why the HUD never showed this.)
  $win.Background = [System.Windows.Media.Brushes]::Transparent
  $win.Opacity = 0.85

  $ring = [System.Windows.Shapes.Ellipse]::new()
  $ring.Width = [double]$MarkerSize
  $ring.Height = [double]$MarkerSize
  $ring.Stroke = [System.Windows.Media.Brushes]::DeepSkyBlue
  $ring.StrokeThickness = 2.0
  $ring.Fill = [System.Windows.Media.SolidColorBrush]::new(
    [System.Windows.Media.Color]::FromArgb(60, 0, 191, 255))
  $grid = [System.Windows.Controls.Grid]::new()
  [void]$grid.Children.Add($ring)
  $win.Content = $grid

  $win.Show()
  $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
  [WpmCtl]::OverlayHwnd = [int64]$hwnd

  # The trio, applied once the HWND exists. TOPMOST is also WPF-side, but the measured promise is
  # the ex-style value itself, so all four bits are set explicitly and read back by the test.
  $bits = [WpmWin]::WS_EX_TOPMOST -bor [WpmWin]::WS_EX_NOACTIVATE -bor
          [WpmWin]::WS_EX_TRANSPARENT -bor [WpmWin]::WS_EX_LAYERED
  [void][WpmWin]::AddExStyles($hwnd, $bits)

  # The marker's PHYSICAL size, read once from Win32. Placement is done with SetWindowPos (physical
  # units) because WPF's own coordinates are device independent and did not agree with this desktop
  # (measured: marker at (303,263) for a target of (470,410) at 150%). Reading the real rect once is
  # cheaper and more honest than assuming MarkerSize is the physical edge length.
  $rc0 = New-Object 'WpmWin+RECT'
  [void][WpmWin]::GetWindowRect([IntPtr]$hwnd, [ref]$rc0)
  $script:OvPhysW = [int]($rc0.Right - $rc0.Left)
  $script:OvPhysH = [int]($rc0.Bottom - $rc0.Top)
  if ($script:OvPhysW -le 0) { $script:OvPhysW = $MarkerSize }
  if ($script:OvPhysH -le 0) { $script:OvPhysH = $MarkerSize }

  $hkOk = $false
  $hkLabel = ''
  $tried = @()
  foreach ($c in $Chords) {
    $label = [string]$c.label
    $tried += $label
    if ([WpmWin]::RegisterHotKey($hwnd, $HotkeyId, [uint32]$c.mods, [uint32]$c.vk)) {
      $hkOk = $true
      $hkLabel = $label
      break
    }
  }
  [WpmCtl]::HotkeyOk = [bool]$hkOk
  [WpmCtl]::HotkeyLabel = $hkLabel
  if (-not $hkOk) {
    [WpmCtl]::Reason = 'RegisterHotKey false for every candidate (' + ($tried -join ', ') + '); the settings switch still pauses'
  } elseif ($hkLabel -ne 'Ctrl+Alt+Q') {
    # Reported, not hidden: the promise in the README is the first chord, and when the desktop
    # already owns it this is the only place the owner can learn which key actually works.
    [WpmCtl]::Reason = "Ctrl+Alt+Q is owned by another app (RegisterHotKey 1409); registered $hkLabel instead"
  }

  # WM_HOTKEY -> flip the ONE pause flag. The owner's switch: server-side refusal, not a hint.
  $src = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
  # No DIP matrix is kept here on purpose. Converting to device-independent units is exactly the
  # step that put the marker at (303,263) for a target of (470,410): this process's idea of the
  # scale and the window's actual rendering disagreed. Placement is SetWindowPos in physical pixels
  # (see the pump), so there is nothing to convert and no second coordinate system to get wrong.
  if ($src) {
    $hook = [System.Windows.Interop.HwndSourceHook] {
      param($h, $m, $wp, $lp, [ref]$handled)
      if ($m -eq [WpmWin]::WM_HOTKEY -and [int]$wp -eq $HotkeyId) {
        [WpmCtl]::Paused = -not [WpmCtl]::Paused
        $handled.Value = $true
        return [IntPtr]::Zero
      }
      $handled.Value = $false
      return [IntPtr]::Zero
    }
    [void]$src.AddHook($hook)
  }

  # THE MARKER IS DRIVEN FROM THIS THREAD, ON A PUMP -- not by cross-thread Invokes.
  #
  # Why: Set-WpmOverlayMarker used to marshal a PowerShell scriptblock onto this thread with
  # Dispatcher.Invoke. Measured (.tmp/ov-seg.log): that call took 1818ms and once never returned.
  # The delegate is a scriptblock and this thread is inside Dispatcher.Run(), so the engine has to
  # reach a runspace that is already busy -- a deadlock with a timeout, not a slow call. Writing
  # three static fields costs nothing; this pump (a DispatcherTimer, which runs on THIS thread the
  # same way the hotkey hook does) applies them at 16ms.
  #
  # Auto-hide is measured from the LAST placement, so the deadline is re-armed per request: a
  # free-running 1.5s timer kicks the marker off screen at an arbitrary phase, which can be the
  # same millisecond it was placed (measured in .tmp/ov-hide.log: -2000 within 400ms of placing).
  # That version passed a naive "is it hidden" glance while breaking the promise in the other
  # direction -- it never stayed visible long enough to be pointed at.
  $script:OvSeenSeq = [WpmCtl]::MarkerSeq
  $script:OvHideAt = [DateTime]::MinValue
  $pump = [System.Windows.Threading.DispatcherTimer]::new()
  $pump.Interval = [TimeSpan]::FromMilliseconds(16)
  $pump.Add_Tick({
    $w = [WpmCtl]::Window
    if (-not $w -or -not [WpmCtl]::OverlayOn) { return }
    $seq = [WpmCtl]::MarkerSeq
    if ($seq -ne $script:OvSeenSeq) {
      $script:OvSeenSeq = $seq
      if ([WpmCtl]::MarkerHide) {
        [void][WpmWin]::MoveNoActivate([IntPtr][WpmCtl]::OverlayHwnd, -2000, -2000, 1, 1)
        $script:OvHideAt = [DateTime]::MinValue
      } else {
        $mx = [WpmCtl]::MarkerX
        $my = [WpmCtl]::MarkerY
        if ($mx -ge 0 -and $my -ge 0) {
          $pw = [int]$script:OvPhysW
          $ph = [int]$script:OvPhysH
          [void][WpmWin]::MoveNoActivate([IntPtr][WpmCtl]::OverlayHwnd, $mx - [int][Math]::Floor($pw / 2), $my - [int][Math]::Floor($ph / 2), $pw, $ph)
          $script:OvHideAt = [DateTime]::UtcNow.AddMilliseconds(1500)
        }
      }
    } elseif ($script:OvHideAt -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $script:OvHideAt) {
      [void][WpmWin]::MoveNoActivate([IntPtr][WpmCtl]::OverlayHwnd, -2000, -2000, 1, 1)
      $script:OvHideAt = [DateTime]::MinValue
    }
  })
  $pump.Start()

  [WpmCtl]::Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
  [WpmCtl]::Window = $win
  [WpmCtl]::Timer = $pump
  [WpmCtl]::OverlayOn = $true

  # Block this runspace thread pumping the dispatcher until the window closes (Stop-WpmOverlay).
  [System.Windows.Threading.Dispatcher]::Run()
} catch {
  [WpmCtl]::Reason = $_.Exception.Message
} finally {
  [WpmCtl]::OverlayOn = $false
  [WpmCtl]::HotkeyOk = $false
  [WpmCtl]::HotkeyLabel = ''
  [WpmCtl]::Window = $null
  [WpmCtl]::Timer = $null
  [WpmCtl]::Dispatcher = $null
  [WpmCtl]::OverlayHwnd = 0
}
'@

function Start-WpmOverlay {
  param([int]$MarkerSize = 22)
  if ($script:WpmOvRunspace -and $script:WpmOvRunspace.RunspaceStateInfo.State -eq 'Opened') {
    return @{ started = $false; reason = 'already running' }
  }
  [WpmCtl]::Reason = ''
  $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
  $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
  $rs.ApartmentState = [System.Threading.ApartmentState]::STA
  $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::Default
  $rs.Open()
  if ($rs.RunspaceStateInfo.State -ne 'Opened') {
    return @{ started = $false; reason = "runspace failed to open: $($rs.RunspaceStateInfo)" }
  }
  $ps = [PowerShell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript($script:WpmOverlayBody).AddArgument($MarkerSize).AddArgument($script:WpmHotkeyId).AddArgument($script:WpmHotkeyChords)
  $script:WpmOvHandle = $ps.BeginInvoke()
  $script:WpmOvRunspace = $rs
  $script:WpmOvPowerShell = $ps
  return @{ started = $true; runspace = [string]$rs.Id }
}

function Get-WpmOverlayState {
  param([int]$WaitMs = 2500)
  # THE READINESS FLAG MUST BE THE FLAG THE VERDICT USES. The first version polled OverlayHwnd --
  # set right after Show(), BEFORE the ex-style trio is applied -- but reported `running = OverlayOn`,
  # set only after the trio, the hotkey and the pump are all up. Inside that window the state read
  # back a HALF-STYLED window (measured: exStyle=0x00080008 -- WPF's own TOPMOST|LAYERED, no
  # TRANSPARENT) and declared an initialising overlay "not running"; the caller's marker request was
  # then skipped for a click that had already answered, and the fire-and-forget path never retried
  # (measured in the gate: marker parked at (-2000,-2000) with one WARN, then silence forever).
  # So: wait for OverlayOn -- the same flag the verdict reports. A budget that merely EXPIRED is a
  # third state, not a crash: `starting` below, from the runspace handle, keeps "slow" and "dead for
  # a named reason" from sharing one message.
  $deadline = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $WaitMs
  while ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $deadline -and -not [WpmCtl]::OverlayOn) {
    Start-Sleep -Milliseconds 50
  }
  $hwnd = [WpmCtl]::OverlayHwnd
  $ex = 0
  if ($hwnd -ne 0) { $ex = [WpmWin]::GetWindowLong([IntPtr]$hwnd, [WpmWin]::GWL_EXSTYLE) }
  return @{
    running = [bool][WpmCtl]::OverlayOn
    # A timeout is not a crash, and the caller must be able to tell them apart. Before this, a
    # wait that expired mid-init produced `running=false` with an empty reason -- indistinguishable
    # from a body that threw. 'starting' names the third state: still alive, just not done.
    starting = (-not [WpmCtl]::OverlayOn) -and ($script:WpmOvHandle -ne $null) -and
               (-not $script:WpmOvHandle.AsyncWaitHandle.WaitOne(0))
    hwnd = [string]$hwnd
    hotkeyRegistered = [bool][WpmCtl]::HotkeyOk
    hotkeyLabel = [string][WpmCtl]::HotkeyLabel
    paused = [bool][WpmCtl]::Paused
    reason = [string][WpmCtl]::Reason
    exStyle = '0x{0:X8}' -f $ex
    topmost = [bool]($ex -band [WpmWin]::WS_EX_TOPMOST)
    noActivate = [bool]($ex -band [WpmWin]::WS_EX_NOACTIVATE)
    transparent = [bool]($ex -band [WpmWin]::WS_EX_TRANSPARENT)
    foregroundNow = [WpmWin]::Fg()
  }
}

function Set-WpmOverlayMarker {
  # A REQUEST, NOT AN ACTION. The fields are written here and applied by the overlay's own pump;
  # nothing is marshalled across threads. Returns as soon as the request is posted (sub-millisecond),
  # which is the property that matters: this is called after every successful action.
  param([int]$X, [int]$Y, [switch]$Hide)
  if (-not [WpmCtl]::OverlayOn -or [WpmCtl]::OverlayHwnd -eq 0) {
    return @{ ok = $false; reason = 'overlay not running' }
  }
  [WpmCtl]::MarkerX = $X
  [WpmCtl]::MarkerY = $Y
  [WpmCtl]::MarkerHide = [bool]$Hide
  [WpmCtl]::MarkerSeq = [WpmCtl]::MarkerSeq + 1
  return @{ ok = $true; x = $X; y = $Y; hidden = [bool]$Hide }
}

function Get-WpmOverlayMarker {
  # Read the marker's REAL on-screen rect with GetWindowRect -- a Win32 call that is safe from any
  # thread. The previous version read WPF's Window.Left through Dispatcher.Invoke (1818ms, see the
  # pump comment in the body) and, before that, read the property straight off the wrong thread,
  # which is a DispatcherObject.VerifyAccess violation rather than a measurement.
  $hwnd = [WpmCtl]::OverlayHwnd
  if ($hwnd -eq 0) {
    return @{ ok = $false; reason = 'overlay not running'; left = 0.0; top = 0.0; offscreen = $true }
  }
  $rc = New-Object 'WpmWin+RECT'
  if (-not [WpmWin]::GetWindowRect([IntPtr]$hwnd, [ref]$rc)) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    return @{ ok = $false; reason = "GetWindowRect failed win32=$err"; left = 0.0; top = 0.0; offscreen = $true }
  }
  $left = [double]$rc.Left
  return @{
    ok = $true
    reason = ''
    left = $left
    top = [double]$rc.Top
    width = [int]($rc.Right - $rc.Left)
    height = [int]($rc.Bottom - $rc.Top)
    offscreen = ($left -lt -1000.0)
  }
}

function Stop-WpmOverlay {
  # TEARDOWN IS A WINDOW MESSAGE, NOT A MARSHALLED SCRIPTBLOCK -- the same lesson as the pump.
  # First version: $d.Invoke(...) closing the window never returned (the runspace thread is parked
  # in Dispatcher.Run(); .tmp/ov-step.log shows the trace stopping right there). Second version
  # posted the same scriptblock with BeginInvoke, which returned immediately but took ~1.8s or more
  # to actually run, so `overlay off` measured 2618-3654ms over the worker protocol
  # (.tmp/worker-overlay.mjs). WM_CLOSE is handled by WPF itself: the window closes, Dispatcher.Run
  # returns, the pipeline ends. PostMessage returns immediately and needs no runspace at all.
  # RegisterHotKey is owned by the window, so destroying it unregisters the chord automatically.
  $hwnd = [WpmCtl]::OverlayHwnd
  $posted = $false
  if ($hwnd -ne 0) {
    try { $posted = [bool][WpmWin]::PostMessageW([IntPtr]$hwnd, [uint32][WpmWin]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) } catch { $posted = $false }
  }
  $completed = $false
  # WM_CLOSE only closes the WINDOW. Dispatcher.Run() (which is what the overlay thread is parked
  # in) keeps running until Shutdown is requested -- measured: with the message alone the pipeline
  # was still alive after 1000ms of waiting and only ended once InvokeShutdown was forced, for
  # 1542ms total. So: give the window a short grace period to close cleanly, then shut the
  # dispatcher down, which is the call that actually ends the thread.
  if ($script:WpmOvHandle) {
    $spin = 0
    while (-not $script:WpmOvHandle.IsCompleted -and $spin -lt 6) { Start-Sleep -Milliseconds 50; $spin++ }
    $completed = [bool]$script:WpmOvHandle.IsCompleted
  }
  if (-not $completed) {
    $d = [WpmCtl]::Dispatcher
    if ($d) { try { [void]$d.InvokeShutdown() } catch { } }
    $spin = 0
    while ($script:WpmOvHandle -and -not $script:WpmOvHandle.IsCompleted -and $spin -lt 20) { Start-Sleep -Milliseconds 25; $spin++ }
    $completed = [bool]($script:WpmOvHandle -and $script:WpmOvHandle.IsCompleted)
  }
  if ($script:WpmOvHandle) {
    try { $script:WpmOvPowerShell.EndInvoke($script:WpmOvHandle) | Out-Null } catch { }
  }
  if ($script:WpmOvPowerShell) { try { $script:WpmOvPowerShell.Dispose() } catch { }; $script:WpmOvPowerShell = $null }
  if ($script:WpmOvRunspace) { try { $script:WpmOvRunspace.Dispose() } catch { }; $script:WpmOvRunspace = $null }
  $script:WpmOvHandle = $null
  # The body's finally block owns the flags, but it only runs if the pipeline really ended. If the
  # bound expired we must not leave a lie in [WpmCtl]: clear the state here and report the fact.
  $st = Get-WpmOverlayState -WaitMs 200
  if (-not $completed) {
    [WpmCtl]::OverlayOn = $false
    [WpmCtl]::HotkeyOk = $false
    [WpmCtl]::HotkeyLabel = ''
    [WpmCtl]::Window = $null
    [WpmCtl]::Timer = $null
    [WpmCtl]::Dispatcher = $null
    [WpmCtl]::OverlayHwnd = [int64]0
    $st = Get-WpmOverlayState -WaitMs 200
    $st.reason = 'overlay pipeline did not end within the bound; state cleared by Stop-WpmOverlay'
  }
  return @{ stopped = $true; completed = $completed; posted = $posted; state = $st }
}
