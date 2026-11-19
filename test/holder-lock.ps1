# holder-lock.ps1 -- a window WE own that can hold the foreground lock on the driver's behalf.
#
# WHY THIS EXISTS. H0 of the first lock run measured the obvious construction failing: a background
# process calling LockSetForegroundWindow gets FALSE. The documented precondition is that the
# CALLER is the foreground process. So the lock has to be taken by a process that briefly IS the
# foreground -- and the only window this project may put in the foreground is one it created. This
# holder therefore runs a flag protocol:
#
#   driver writes  <flag>.lock     -> holder (currently foreground) calls LSFW_LOCK, records result
#   driver writes  <flag>.unlock   -> holder calls LSFW_UNLOCK, records result, exits
#
# Every step's return value is written to the report file, because a lock or unlock that silently
# failed would make the whole experiment measure nothing while believing it locked.
#
# THE SEQUENCE THE DRIVER FOLLOWS (measured in the experiment, not assumed):
#   1. holder takes the foreground via the shipped attach+SetForegroundWindow route
#   2. holder locks while it is foreground (the documented precondition, satisfied honestly)
#   3. holder hands the foreground BACK to the owner -- the open question is whether a lock held by
#      a no-longer-foreground process still suppresses other processes; that is precisely H1
#   4. driver runs the actions under lock
#   5. driver requests unlock; holder unlocks (H3: allowed even though holder is no longer
#      foreground? measured) and exits
param(
  [int]$HoldMs = 120000,
  [string]$FlagBase = '',
  [string]$ReportFile = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class WpmHolderLock {
    [DllImport("user32.dll")] public static extern bool LockSetForegroundWindow(uint uLockCode);
}
'@
$window = [Windows.Markup.XamlReader]::Parse(@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="WpmHolderLock" Width="220" Height="110" WindowStartupLocation="Manual"
        Left="60" Top="620" ShowInTaskbar="False">
  <TextBlock Text="lock holder" Margin="14" Foreground="#888"/>
</Window>
"@)

function Set-Report([string]$k, [string]$v) {
  if ($ReportFile) { Add-Content -LiteralPath $ReportFile -Value "$k=$v" -Force -ErrorAction SilentlyContinue }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$started = Get-Date
$script:locked = $false
$timer.Add_Tick({
  if (((Get-Date) - $started).TotalMilliseconds -gt $HoldMs) { $window.Close(); return }
  if ($FlagBase) {
    if (-not $script:locked -and (Test-Path -LiteralPath "$FlagBase.lock")) {
      $ok = [WpmHolderLock]::LockSetForegroundWindow(1)
      Set-Report 'lock' "$ok"
      $script:locked = $ok
      try { Remove-Item -LiteralPath "$FlagBase.lock" -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($script:locked -and (Test-Path -LiteralPath "$FlagBase.unlock")) {
      $ok = [WpmHolderLock]::LockSetForegroundWindow(2)
      Set-Report 'unlock' "$ok"
      try { Remove-Item -LiteralPath "$FlagBase.unlock" -Force -ErrorAction SilentlyContinue } catch { }
      $window.Close()
    }
  }
})
$timer.Start()
$window.Add_ContentRendered({
  try {
    Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class WpmHLShow{[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int cmd);}'
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    [void][WpmHLShow]::ShowWindow($h, 8)
    Write-Output ("HWND=" + $h.ToInt64())
  } catch { }
})
$app = New-Object System.Windows.Application
$app.Run($window) | Out-Null
