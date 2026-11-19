# uia-target.ps1 -- a WPF target with an app-side truth file and a modal dialog.
#
# WHY WPF AND NOT WINFORMS. WinForms surfaces its controls as child HWNDs, so the message tier can
# reach it and the bounded-flash path never runs. WPF controls are not windows at all: there is no
# child HWND to address, only UIA patterns, so a WPF target is the only way to exercise the tier
# that costs the owner a flash -- which is the tier R2' exists to make safe.
#
# WHY A STATE FILE. Cross-process read-back is blind (WM_GETTEXT returned 'abc' after an
# app-confirmed 'abcZ'), so an effect can only be attributed from the owning process. The file is
# written by this process every 250 ms and is the only accepted oracle: the engine's own return
# value is never counted as proof that something happened.
#
# WHY A MODAL DIALOG. R2'.6 says a window opened BY the target (same pid) must not be restored away
# from. This target can produce exactly that condition on demand, so the exemption can be measured
# instead of asserted.
param(
  [int]$HoldMs = 300000,
  [string]$Title = 'WpmUiaTarget',
  [string]$ExitFile = '',
  [string]$StateFile = '',
  [int]$Left = 900,
  [int]$Top = 260
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="470" Height="330" WindowStartupLocation="Manual"
        Left="$Left" Top="$Top" ShowInTaskbar="True" Topmost="False">
  <StackPanel Margin="16">
    <TextBox x:Name="wpmEdit" AutomationProperties.AutomationId="wpmEdit" Text="abc" Width="400" HorizontalAlignment="Left" FontSize="16"/>
    <Button x:Name="wpmPress" AutomationProperties.AutomationId="wpmPress" Content="Press" Width="130" HorizontalAlignment="Left" Margin="0,10,0,0"/>
    <Button x:Name="wpmOpen" AutomationProperties.AutomationId="wpmOpen" Content="Open" Width="130" HorizontalAlignment="Left" Margin="0,8,0,0"/>
    <TextBlock x:Name="wpmLog" Text="ready" Margin="0,12,0,0" FontSize="12" Foreground="#888"/>
  </StackPanel>
</Window>
"@
$window = [Windows.Markup.XamlReader]::Parse($xaml)
$edit = $window.FindName('wpmEdit')
$press = $window.FindName('wpmPress')
$open = $window.FindName('wpmOpen')
$log = $window.FindName('wpmLog')

$script:pressCount = 0
$script:openCount = 0
$script:dialogShown = 0

$press.Add_Click({
  $script:pressCount++
  # The visible caption is the cross-process oracle for 'the click landed': UIA reads Current.Name,
  # which is this string, so a click that did nothing leaves 'Press' and cannot be scored as success.
  $press.Content = "Press($($script:pressCount))"
  $log.Text = "press=$($script:pressCount) open=$($script:openCount)"
})

$open.Add_Click({
  $script:openCount++
  $script:dialogShown++
  $dlg = New-Object System.Windows.Window
  $dlg.Title = 'WpmDialogChild'
  $dlg.Width = 340; $dlg.Height = 180
  $dlg.WindowStartupLocation = 'CenterOwner'
  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Margin = '14'
  $tb = New-Object System.Windows.Controls.TextBox
  $tb.Name = 'dlgEdit'
  $tb.Text = 'dialog-text'
  $tb.FontSize = 15
  $tb.Margin = '0,0,0,10'
  $btn = New-Object System.Windows.Controls.Button
  $btn.Name = 'dlgClose'
  $btn.Content = 'Close'
  $btn.Width = 90
  $btn.HorizontalAlignment = 'Left'
  $btn.Add_Click({ $dlg.Close() })
  [void]$sp.Children.Add($tb)
  [void]$sp.Children.Add($btn)
  $dlg.Content = $sp
  # ShowDialog runs a nested message loop, so the state timer keeps ticking and the dialog is a real
  # modal owned window of this process -- exactly the same-pid condition R2'.6 must not steal from.
  [void]$dlg.ShowDialog()
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$started = Get-Date
$timer.Add_Tick({
  if ($ExitFile -and (Test-Path -LiteralPath $ExitFile)) { $window.Close(); return }
  if (((Get-Date) - $started).TotalMilliseconds -gt $HoldMs) { $window.Close(); return }
  if ($StateFile) {
    try {
      $line = "press=$($script:pressCount)`topen=$($script:openCount)`tedit=$($edit.Text)`tdlg=$($script:dialogShown)"
      Set-Content -LiteralPath $StateFile -Value $line -Force -ErrorAction Stop
      $script:stateErr = ''
    } catch {
      # Never swallow this. A silent oracle failure once made a healthy-looking window report
      # 'state file never appeared' with no clue that the cause was inside the app.
      $script:stateErr = $_.Exception.Message
      Write-Output ("STATE-ERR " + $script:stateErr)
    }
  }
})
$timer.Start()

$window.Add_ContentRendered({
  try {
    Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class WpmUiaShow{[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int cmd);}'
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    # SW_SHOWNA: visible but not activated, so launching the target cannot be mistaken for the
    # engine stealing focus, and the baseline foreground stays whatever the owner had.
    [void][WpmUiaShow]::ShowWindow($h, 8)
    Write-Output ("HWND=" + $h.ToInt64())
  } catch { }
})

$app = New-Object System.Windows.Application
$app.Run($window) | Out-Null
