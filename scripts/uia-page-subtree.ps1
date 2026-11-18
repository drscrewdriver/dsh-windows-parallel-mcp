# uia-page-subtree.ps1 — dump the DOCUMENT subtree of a Chromium window, separately.
#
# WHY SEPARATELY. The whole-window scan in debug-pick.ps1 found five Edit elements, all of
# which are BROWSER chrome (OmniboxViewViews, SearchBoxLocationBarView, a sidebar
# Textfield) -- none inside the page document. That reframes an earlier result: when the
# neutrality experiment reported "chromium uia-setvalue ok, value changed 8/8", the element
# it wrote to was probably the address bar, not the <input> in the page it was supposed to
# be testing. A channel measured against the wrong element is not a channel measured at
# all, and a focus-steal attributed to page injection would have been a focus-steal
# attributed to the wrong thing.
#
# So: find the Document element by name, walk ONLY inside it, and report what the page
# actually exposes.
param(
  [string]$TitlePart = 'WpmNeutr',
  [string]$DocName = 'WpmNeutr',
  [int]$MaxScan = 4000,
  # Bounded wait for the window. The driver that launches a browser cannot know when the
  # page exists, and a second timeout in the driver would be a second place for the same
  # decision to be wrong -- so the wait lives here, next to the thing it waits for.
  [int]$WaitSec = 0
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Find-Win([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

$w = Find-Win $TitlePart
if (-not $w -and $WaitSec -gt 0) {
  $deadline = (Get-Date).AddSeconds($WaitSec)
  while ((Get-Date) -lt $deadline -and -not $w) {
    Start-Sleep -Milliseconds 600
    $w = Find-Win $TitlePart
  }
}
if (-not $w) { throw "no window matching '$TitlePart'" }
$hwnd = [IntPtr]$w.hwnd
"window: hwnd=$hwnd title='$($w.title)' class='$($w.cls)' pid=$($w.procId)"

$root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$total = $all.Count
"total descendants in window: $total (scanning up to $MaxScan)"

# Step 1: locate the document element(s). The page is a Document whose Name is the page
# title; a window with tabs may have several documents, so all are reported.
$docs = @()
$n = [Math]::Min($total, $MaxScan)
for ($i = 0; $i -lt $n; $i++) {
  $ct = ''
  try { $ct = ($all[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
  if ($ct -ne 'Document') { continue }
  $nm = ''
  try { $nm = [string]$all[$i].Current.Name } catch { }
  $docs += @{ idx = $i; el = $all[$i]; name = $nm }
}
"documents found: $($docs.Count)"
$docs | ForEach-Object { "   idx=$($_.idx) name='$($_.name)'" }

if (-not $docs.Count) {
  'NO DOCUMENT ELEMENT. Either the page never loaded, or UIA cannot see it in this state.'
  exit 2
}

# Step 2: walk inside the matching document only.
$target = $docs | Where-Object { $_.name -like "*$DocName*" } | Select-Object -First 1
if (-not $target) { $target = $docs[0] }
"using document idx=$($target.idx) name='$($target.name)'"

# Two independent ways of enumerating the page subtree, because the choice of VIEW is
# itself a possible source of a false "the page exposes nothing":
#   FindAll(Descendants, TrueCondition) is view-agnostic and is the strongest evidence.
#   TreeWalker per view is what an engine implementation would actually do.
$direct = $null
try { $direct = $target.el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) } catch { }
$directCount = if ($null -eq $direct) { -1 } else { $direct.Count }
''
"document.FindAll(Descendants, TrueCondition) => $directCount elements"

foreach ($viewName in 'RawViewWalker', 'ControlViewWalker', 'ContentViewWalker') {
  $view = [System.Windows.Automation.TreeWalker]::$viewName
  $c = $null
  try { $c = $view.GetFirstChild($target.el) } catch { }
  $firstDesc = ''
  if ($c) { try { $firstDesc = ($c.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') + ' / ' + [string]$c.Current.Name } catch { $firstDesc = '(unreadable)' } }
  else { $firstDesc = '(none)' }
  "{0,-20} firstChildOfDocument = {1}" -f $viewName, $firstDesc
}
''

$walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
$stack = New-Object System.Collections.Generic.Stack[object]
$stack.Push(@{ el = $target.el; depth = 0 })
$seen = 0
$out = @()
while ($stack.Count -gt 0 -and $seen -lt 300) {
  $it = $stack.Pop()
  $el = $it.el; $depth = $it.depth
  $seen++
  $kids = @()
  try {
    $c = $walker.GetFirstChild($el)
    while ($c) { $kids += $c; $c = $walker.GetNextSibling($c) }
  } catch { }
  for ($i = $kids.Count - 1; $i -ge 0; $i--) { $stack.Push(@{ el = $kids[$i]; depth = $depth + 1 }) }

  $pats = @()
  foreach ($pair in @(
      @{ n = 'Value'; p = [System.Windows.Automation.ValuePatternIdentifiers]::Pattern },
      @{ n = 'Invoke'; p = [System.Windows.Automation.InvokePatternIdentifiers]::Pattern },
      @{ n = 'Toggle'; p = [System.Windows.Automation.TogglePatternIdentifiers]::Pattern },
      @{ n = 'Text'; p = [System.Windows.Automation.TextPatternIdentifiers]::Pattern }
    )) {
    $ref = $null
    $got = $false
    try { $got = $el.TryGetCurrentPattern($pair.p, [ref]$ref) } catch { $got = $false }
    if ($got) { $pats += $pair.n }
  }
  $ct = ''; try { $ct = ($el.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { }
  $nm = ''; try { $nm = [string]$el.Current.Name } catch { }
  if ($nm.Length -gt 30) { $nm = $nm.Substring(0, 30) }
  $au = ''; try { $au = [string]$el.Current.AutomationId } catch { }
  $val = ''; $ro = ''
  if ($pats -contains 'Value') {
    try {
      $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
      $val = [string]$vp.Current.Value; $ro = [string]$vp.Current.IsReadOnly
    } catch { }
  }
  $out += [pscustomobject]@{ d = $depth; ct = $ct; autoId = $au; name = $nm; ro = $ro; val = $val; pats = ($pats -join ',') }
}

''
"in-document elements visited: $seen"
$out | Format-Table -AutoSize d, ct, autoId, name, ro, val, pats | Out-String -Width 200
''
$edits = @($out | Where-Object { $_.ct -match 'Edit|Document' })
"page elements carrying Value: " + (@($out | Where-Object { $_.pats -match 'Value' }).Count)
"page Edit elements: $($edits.Count)"
$writable = @($out | Where-Object { $_.pats -match 'Value' -and $_.ro -ne 'True' })
if ($writable.Count) {
  '=> the page IS reachable by UIA SetValue. First writable: ' + ($writable[0] | ConvertTo-Json -Compress)
} else {
  '=> NO writable ValuePattern inside the page document. Whatever the window-level scan ' +
  'found, it was browser UI, not page content.'
}
