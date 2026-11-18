# uia-tree-dump.ps1 — read-only UIA subtree dump for one window.
#
# WHY. When a channel reports "no ValuePattern element" there are two very different
# causes, and the coverage verdict depends on telling them apart:
#   (1) the target genuinely exposes no such pattern  -> a reachability gap, real;
#   (2) our walk never reached the element that has it -> a probe bug, and quoting the
#       gap would understate coverage.
# A UWP/XAML frame window is the sharp case: the top-level ApplicationFrameWindow is not
# where the content lives -- the interactive tree hangs off a nested
# Windows.UI.Core.CoreWindow -- so a walk that stops at the frame's own elements finds
# "nothing" on the desktop's largest family.
#
# Read-only: navigation and property reads only. No patterns are invoked.
param(
  [string]$TitlePart = 'Calculator',
  [int]$MaxElements = 400,
  [switch]$FullTree
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# Locate the window through the same EnumWindows path every other tool uses.
$findOut = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
  (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $TitlePart 2>$null
if (-not $findOut) { throw "no visible window matches '$TitlePart'" }
$info = ($findOut | Select-Object -Last 1) | ConvertFrom-Json
$hwnd = [IntPtr]$info.hwnd
"window: hwnd=$hwnd title='$($info.title)' class='$($info.cls)' pid=$($info.procId)"

$root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
if (-not $root) { throw 'UIA FromHandle returned nothing' }
"root: type=$($root.Current.ControlType.ProgrammaticName) name='$($root.Current.Name)' class='$($root.Current.ClassName)' native=$($root.Current.NativeWindowHandle)"

$patNames = @{
  Value = [System.Windows.Automation.ValuePatternIdentifiers]::Pattern
  Invoke = [System.Windows.Automation.InvokePatternIdentifiers]::Pattern
  Text = [System.Windows.Automation.TextPatternIdentifiers]::Pattern
  Toggle = [System.Windows.Automation.TogglePatternIdentifiers]::Pattern
  RangeValue = [System.Windows.Automation.RangeValuePatternIdentifiers]::Pattern
  Scroll = [System.Windows.Automation.ScrollPatternIdentifiers]::Pattern
  SelectionItem = [System.Windows.Automation.SelectionItemPatternIdentifiers]::Pattern
  # LegacyIAccessible has no *PatternIdentifiers type in UIAutomationClient (it is only
  # reachable through the raw COM interfaces), so referencing it threw TypeNotFound before
  # a single element was walked. Dropping it keeps the census to the seven patterns the
  # managed client actually exposes.
}

# Pattern probing is inlined in the walk below. It is NOT factored into a helper: the
# first draft used TryGetCurrentPattern through a local function with a [ref] argument,
# and [ref] to a local inside a function binds to the function's own variable, so the
# probe always reported the pattern absent -- a silent 0%% coverage reading on a family
# that is fully UIA-accessible. Inlined, the [ref] binds to the walk's own scope.

$walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
$stack = New-Object System.Collections.Generic.Stack[object]
$stack.Push(@{ el = $root; depth = 0 })
$seen = 0
$rows = @()
$patCount = @{}
while ($stack.Count -gt 0 -and $seen -lt $MaxElements) {
  $item = $pop = $stack.Pop()
  $el = $item.el; $depth = $item.depth
  $seen++

  # Deterministic order: push children in reverse so the first child is popped first.
  $kids = @()
  try {
    $c = $walker.GetFirstChild($el)
    while ($c) { $kids += $c; $c = $walker.GetNextSibling($c) }
  } catch { }
  for ($i = $kids.Count - 1; $i -ge 0; $i--) { $stack.Push(@{ el = $kids[$i]; depth = $depth + 1 }) }

  $pats = @()
  foreach ($k in ($patNames.Keys | Sort-Object)) {
    $ref = $null
    $got = $false
    try { $got = $el.TryGetCurrentPattern($patNames[$k], [ref]$ref) } catch { $got = $false }
    if ($got) { $pats += $k; if (-not $patCount.ContainsKey($k)) { $patCount[$k] = 0 }; $patCount[$k]++ }
  }
  $ct = ''
  try { $ct = $el.Current.ControlType.ProgrammaticName -replace '^.*\.', '' } catch { }
  $nm = ''
  try { $nm = $el.Current.Name } catch { }
  if ($nm.Length -gt 40) { $nm = $nm.Substring(0, 40) }
  $cl = ''
  try { $cl = $el.Current.ClassName } catch { }
  $native = 0
  try { $native = $el.Current.NativeWindowHandle } catch { }
  $isOff = $false
  try { $isOff = -not $el.Current.IsOffscreen } catch { }

  $rows += [pscustomobject]@{
    depth = $depth; type = $ct; name = $nm; cls = $cl; native = $native
    patterns = ($pats -join ',')
  }
}

"elements visited: $seen"
''
'=== pattern census (how many elements expose each pattern) ==='
if ($patCount.Count) { $patCount.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "  {0,-18} {1}" -f $_.Key, $_.Value } }
else { '  NONE -- no pattern anywhere in the walked subtree' }
''
'=== elements carrying Value or Invoke (the writable/clickable doors) ==='
$doors = @($rows | Where-Object { $_.patterns -match 'Value|Invoke' })
if ($doors.Count) { $doors | Select-Object -First 25 | Format-Table -AutoSize | Out-String -Width 200 }
else { '  none found within the first ' + $seen + ' elements' }
''
'=== first ' + [Math]::Min(40, $rows.Count) + ' rows of the tree ==='
$rows | Select-Object -First 40 | Format-Table -AutoSize | Out-String -Width 200
