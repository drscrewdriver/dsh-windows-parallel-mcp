# uia-tree-content.ps1 -- the instrument behind the "empty tree is a switch, not a delay" claim.
#
# WHY THIS EXISTS. 0.1.5's census left one question open: is an a11y-off window's tree "slow"
# (lazy renderer accessibility that a re-query with a deadline would catch) or "off" (nothing
# to wait for)? A single snapshot cannot tell those apart, and guessing wrong in either
# direction is a product decision made on an artifact: if lazy, the engine needs retry logic;
# if gated on a launch-time state, the engine must refuse with uia_tree_empty and never poll.
# So this re-reads the SAME window in place three times (+0/+700/+1500 ms) and reports both
# counters that matter, per read.
#
# THE TWO COUNTERS, AND WHY COUNT ALONE LIES. raw descendants (TrueCondition, census-compatible)
# is what the 23-window census published -- but a Chromium window with renderer accessibility
# off still exposes ONE shell element (the Chrome_RenderWidgetHostHWND pane, "Chrome Legacy
# Window"), so the same uTools window measured raw=0 at census time and raw=1 later the same
# day, depending on its own state. The stable boundary is the CONTENT count: elements whose
# control type is anything but structural chrome (Pane/Group/Image/Text/Thumb/Separator/
# TitleBar). This shell list is THE SAME LIST the engine's Test-WpmUiaTreeHasContent walks
# (src/engine/win.ps1) -- one ruler, so a number quoted from this script is the number the
# engine decided on.
#
# READ-ONLY: it walks other people's windows and never sends anything to them.
param(
  [string]$TitlePart = '',
  [string]$Hwnd = '',
  [int[]]$GapsMs = @(0, 700, 1500),
  [int]$MaxElements = 200
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
# find-window.ps1 is invoked as a child process (see refusals-test.ps1 for why it is not dot-sourced).
function Find-UtcWin([string]$part) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $part 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

$w = $null
if ($Hwnd) {
  $w = @{ hwnd = $Hwnd; title = ''; cls = ''; procId = '' }
} elseif ($TitlePart) {
  $w = Find-UtcWin $TitlePart
}
if (-not $w) { throw "no window: pass -TitlePart or -Hwnd" }
$h = [IntPtr][int64]$w.hwnd

$shellTypes = @('Pane', 'Group', 'Image', 'Text', 'Thumb', 'Separator', 'TitleBar')
$lastRaw = -1
$lastContent = -1
$t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$first = $true
foreach ($gap in $GapsMs) {
  if (-not $first) {
    $target = $t0 + $gap
    while ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $target) { Start-Sleep -Milliseconds 20 }
  }
  $first = $false
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $t0
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $raw = $all.Count
    $content = 0
    $n = [Math]::Min($raw, $MaxElements)
    for ($i = 0; $i -lt $n; $i++) {
      $t = ''
      try { $t = $all[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '' } catch { continue }
      if ($shellTypes -notcontains $t) { $content++ }
    }
    "t=+{0,5}ms  rawDescendants={1,4}  contentElements={2,4}" -f $now, $raw, $content
    $lastRaw = $raw; $lastContent = $content
  } catch {
    "t=+{0,5}ms  probe threw: {1}" -f $now, $_.Exception.Message
    $lastContent = -1
  }
}
''
if ($lastContent -gt 0) {
  'VERDICT: the tree carries content elements (content=' + $lastContent + ', raw=' + $lastRaw + '). ' +
  'This is NOT an a11y-off window; an unreachable verdict on it is about points/patterns, not emptiness.'
} elseif ($lastContent -eq 0) {
  'VERDICT: zero content elements on every read over ' + ($GapsMs[-1]) + 'ms. The tree is shell only: ' +
  'the application has not enabled UI Automation. Re-querying has nothing to find -- the engine refuses ' +
  'with uia_tree_empty and does NOT retry; the switch is launch-time (--force-renderer-accessibility).'
} else {
  'VERDICT: INCONCLUSIVE -- the probe threw before it could count. No claim about the tree is licensed.'
}
