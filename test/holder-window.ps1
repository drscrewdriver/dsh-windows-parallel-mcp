# holder-window.ps1 -- a minimal window that CAN take the foreground when asked, for the
# reconcile experiment's arm G. Created visible but never activated on its own; the driver
# activates it through the documented attach+SetForegroundWindow route (our own window, so no
# third-party focus is ever pulled) and disposes it by exit-file.
param(
  [int]$HoldMs = 25000,
  [string]$ExitFile = '',
  [string]$Title = 'WpmHolderG'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$window = [Windows.Markup.XamlReader]::Parse(@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="$Title" Width="220" Height="120" WindowStartupLocation="Manual"
        Left="60" Top="620" ShowInTaskbar="False">
  <TextBlock Text="holder" Margin="14" Foreground="#888"/>
</Window>
"@)
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$started = Get-Date
$timer.Add_Tick({
  if ($ExitFile -and (Test-Path -LiteralPath $ExitFile)) { $window.Close(); return }
  if (((Get-Date) - $started).TotalMilliseconds -gt $HoldMs) { $window.Close() }
})
$timer.Start()
$window.Add_ContentRendered({
  try {
    Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class WpmHolderShow{[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int cmd);}'
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    [void][WpmHolderShow]::ShowWindow($h, 8)
    Write-Output ("HWND=" + $h.ToInt64())
  } catch { }
})
$app = New-Object System.Windows.Application
$app.Run($window) | Out-Null
