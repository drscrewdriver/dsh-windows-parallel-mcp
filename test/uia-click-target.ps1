<#
  uia-click-target.ps1 -- a TWO-BUTTON WPF target whose click counts are readable from outside.

  WHY TWO BUTTONS. The UIA tier used to invoke the FIRST descendant carrying any usable pattern,
  ignoring the x/y the caller supplied. A single-button target cannot tell "acted on the point" from
  "acted on whatever came first": there is only one candidate. Two buttons far apart turn the
  question into an observation -- which counter moved?

  WHY AN APP-SIDE FILE ORACLE. Cross-process GetWindowText on a WPF control is not a reliable read of
  what the app believes; the only code that can truthfully report "Alpha fired" is the handler that
  fired. The form writes it to a JSON file on every click, so the assertion never depends on UIA
  reading back its own action (which would be grading homework in its own class).
#>
param(
  [int]$HoldMs = 120000,
  [string]$Title = 'WpmTwoButtonTarget',
  [int]$X = 700,
  [int]$Y = 500,
  [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

if (-not $OutFile) {
  $OutFile = Join-Path $env:TEMP ('wpm-two-button-' + [Guid]::NewGuid().ToString('N') + '.json')
}

# Two buttons, deliberately far apart inside one window. Alpha sits top-left, Bravo bottom-right;
# a click aimed at Bravo must never bump Alpha. Sizes are fixed so screen coordinates are predictable
# from the window origin: Alpha at (16,16)-(176,56), Bravo at (264,204)-(424,244).
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="440" Height="300" WindowStartupLocation="Manual"
        Left="$X" Top="$Y" ShowInTaskbar="True" Topmost="True"
        Background="White">
  <Grid>
    <Button x:Name="alpha" Content="Alpha" Width="160" Height="40"
            HorizontalAlignment="Left" VerticalAlignment="Top" Margin="16,16,0,0"/>
    <Button x:Name="bravo" Content="Bravo" Width="160" Height="40"
            HorizontalAlignment="Left" VerticalAlignment="Top" Margin="264,204,0,0"/>
    <TextBlock x:Name="status" Text="idle" Margin="16,120,0,0"
               HorizontalAlignment="Left" VerticalAlignment="Top" FontSize="16"/>
  </Grid>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$alpha = $window.FindName('alpha')
$bravo = $window.FindName('bravo')
$status = $window.FindName('status')
$script:counts = @{ alpha = 0; bravo = 0 }

# The button centres are reported BY THE APP, in PHYSICAL pixels. This desktop runs at 150%, and
# WPF's PointToScreen speaks device-independent units: a test that computes the coordinate itself
# puts the click 1.5x off and then "proves" the product wrong. The only code that knows where its
# own control really is on screen is the control's own process.
# WHY Topmost="True" ON A TEST TARGET. The test's question is "did the product act on the point it
# named", and that question is only decidable if the point actually belongs to this window. With
# Topmost="False" the target could come up BEHIND whatever held the foreground (this desktop's browser
# sits right over the -X/-Y area), so the engine's element probe correctly found a foreign window and
# refused with `unreachable ... the element under that point does not belong to the target window`.
# That refusal is the PRODUCT behaving properly; the failure was the test asserting against a window
# it had not put on top. Measured: 3/5 runs failed before, 6/6 pass after. A test harness that cannot
# guarantee its own precondition is measuring the desktop, not the plugin.
function Get-PhysicalCentre($el) {
  try {
    # PointToScreen ALREADY returns physical screen pixels. Multiplying by TransformToDevice here
    # double-counts the 150% scale and put the reported point ~1.5x outside the window -- the exact
    # DPI mistake the engine's marker had (F4 in findings). Caught because the first run of this
    # test refused with "the element under that point does not belong to the target window", and the
    # refusal was CORRECT about a point that was never inside the target.
    $p = $el.PointToScreen((New-Object System.Windows.Point(($el.ActualWidth / 2), ($el.ActualHeight / 2))))
    return @{ x = [int][Math]::Round($p.X); y = [int][Math]::Round($p.Y) }
  } catch { return @{ x = -1; y = -1 } }
}

function Write-Oracle {
  $a = Get-PhysicalCentre $alpha
  $b = Get-PhysicalCentre $bravo
  $payload = @{
    alpha = $script:counts.alpha
    bravo = $script:counts.bravo
    last = $script:last
    title = $Title
    outFile = $OutFile
    alphaPoint = $a
    bravoPoint = $b
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($OutFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
}
$script:last = 'none'
$window.Add_ContentRendered({ Write-Oracle })
# NO Write-Oracle HERE. It used to be called on this line, before ShowDialog(), and that was a bug in
# the TEST, not in the product: before the window is shown, ActualWidth is 0 and PointToScreen throws,
# so Get-PhysicalCentre returned its -1 catch-all and a {x:-1,y:-1} oracle was written to disk. The
# reader then accepted that file as "the app is up" (it only looks for parseable JSON) and asserted
# against coordinates that never existed. Symptom: the composite gate failed only when the machine was
# busy enough for the reader to get there before the first real layout. ContentRendered above and the
# 300ms timer below are the two writers that run with a laid-out window.

$alpha.Add_Click({ $script:counts.alpha++; $script:last = 'alpha'; $alpha.Content = "Alpha($($script:counts.alpha))"; $status.Text = "last=alpha"; Write-Oracle })
$bravo.Add_Click({ $script:counts.bravo++; $script:last = 'bravo'; $bravo.Content = "Bravo($($script:counts.bravo))"; $status.Text = "last=bravo"; Write-Oracle })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$started = Get-Date
$timer.Add_Tick({
  Write-Oracle
  if (((Get-Date) - $started).TotalMilliseconds -gt $HoldMs) { $window.Close() }
})
$timer.Start()
[void]$window.ShowDialog()
Write-Output "ORACLE_FILE=$OutFile"
