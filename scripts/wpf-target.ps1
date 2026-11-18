# wpf-target.ps1 — UIA-native positive control for the neutrality experiment.
#
# WHY A SECOND CONTROL. WinForms under PS 5.1 surfaces its controls through the MSAA bridge
# as pattern-less Panes even with the legacy-accessibility AppContext switches off, so a
# WinForms target can test the message channels but cannot test the UIA channels at all.
# WPF implements native UIA providers, so a WPF TextBox/Button is the smallest thing that
# proves "Find-PatternElements and SetValue work in this session" rather than "the app is
# opaque". Without that, every UIA 'absent' in the matrix is unattributable.
param(
  [int]$HoldMs = 120000,
  [string]$Title = 'WpmWpfTarget',
  [string]$ExitFile = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WpmWpfTarget" Width="440" Height="300" WindowStartupLocation="Manual"
        Left="80" Top="80" ShowInTaskbar="True" Topmost="False">
  <StackPanel Margin="16">
    <TextBox x:Name="wbEdit" Text="abc" Width="360" HorizontalAlignment="Left" FontSize="18"/>
    <Button x:Name="wbBtn" Content="Press" Width="140" HorizontalAlignment="Left" Margin="0,12"/>
  </StackPanel>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Parse($xaml)
$edit = $window.FindName('wbEdit')
$btn = $window.FindName('wbBtn')
$clicks = 0
$btn.Add_Click({
  $script:clicks++
  # The counter lives in the button's Name so UIA's Current.Name changes on click: an
  # Invoke has to be verified against observable state, not against "no exception".
  $btn.Content = "Press($($script:clicks))"
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$started = Get-Date
$timer.Add_Tick({
  if ($ExitFile -and (Test-Path -LiteralPath $ExitFile)) { $window.Close() }
  if (((Get-Date) - $started).TotalMilliseconds -gt $HoldMs) { $window.Close() }
})
$timer.Start()

$window.Add_ContentRendered({
  Write-Output ("HWND=" + (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle.ToInt64())
})

# Application.Run is an INSTANCE method: `[Windows.Application]::Run(...)` fails to bind.
# WPF also refuses a second Application in a process, so construct one and keep it.
$app = New-Object System.Windows.Application
$app.Run($window) | Out-Null
