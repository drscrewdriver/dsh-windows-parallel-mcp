# chromium-lazy-a11y.ps1 — is Chromium's page tree gated on a FLAG, or just slow to appear?
#
# WHY THIS DISTINCTION IS THE WHOLE VERDICT. The flag comparison found: plain launch => no
# page Document node in the UIA tree at all; --force-renderer-accessibility => the page and
# its input appear. That reads as "page content is unreachable in a browser the user already
# opened", which would gut the coverage claim for the desktop's largest interactive family.
# But Chromium does NOT require the flag for UIA clients: it turns renderer accessibility on
# DEMAND when a client first requests the tree, and building that tree is asynchronous -- the
# first request can legitimately return an empty subtree and the content shows up a second or
# two later. A single census cannot tell these apart, and guessing wrong in either direction
# is a product decision made on an artifact:
#   * if it is lazy activation, the engine just needs to re-query with a deadline, and the
#     browser family IS reachable without focus;
#   * if it truly needs the flag, page content in an already-open browser is unreachable and
#     the parallel claim shrinks to apps the engine launches itself.
# So: query on a schedule and report the timeline, not a snapshot.
param(
  [string]$TitlePart = 'WpmLazy',
  [int]$Polls = 10,
  [int]$EveryMs = 1500,
  [switch]$Launch,
  [string]$ProfileDir = ''
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

if ($Launch) {
  $url = "data:text/html,<title>$TitlePart</title><body><h3>lazy</h3><input id=k value=abc style='width:300px;font-size:22px'><button id=b>Press</button></body>"
  $a = @('--new-window', '--no-first-run')
  if ($ProfileDir) { $a += "--user-data-dir=$ProfileDir" }
  $a += "`"$url`""
  Start-Process msedge -ArgumentList $a | Out-Null
  $d = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $d -and -not (Find-Win $TitlePart)) { Start-Sleep -Milliseconds 500 }
}

$w = Find-Win $TitlePart
if (-not $w) { throw "no window matching '$TitlePart'" }
$hwnd = [IntPtr]$w.hwnd
"window: hwnd=$hwnd class='$($w.cls)' pid=$($w.procId) profile='$ProfileDir'"

# The first FromHandle/FindAll is itself the client request that triggers activation, so
# poll #1 is part of the measurement, not a warm-up to be discarded.
$t0 = Get-Date
# Peak values, not last-poll values. Each poll resets its counters, so judging on the
# final poll would read a single transient FindAll failure as "the page never appeared" --
# the claim this script exists to test. If the tree was seen at all, it was seen.
$maxDocs = 0; $maxEdits = 0; $maxWritable = 0
for ($i = 1; $i -le $Polls; $i++) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $docs = 0; $edits = 0; $total = 0; $writable = 0
  try {
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $total = $all.Count
    $n = [Math]::Min($all.Count, 4000)
    for ($j = 0; $j -lt $n; $j++) {
      $ct = ''
      try { $ct = ($all[$j].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
      if ($ct -eq 'Document') {
        $nm = ''
        try { $nm = [string]$all[$j].Current.Name } catch { }
        # Only count the DOCUMENT that is the page, identified by the title we authored.
        # A browser window contains documents for its own UI too, and counting those would
        # produce exactly the false positive this poll exists to rule out.
        if ($nm -like "*$TitlePart*") {
          $docs++
          try {
            $kids = $all[$j].FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $edits += @($kids | Where-Object { ($_.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') -eq 'Edit' }).Count
            $writable += @($kids | Where-Object {
              try { $vp = $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); ($null -ne $vp) -and -not $vp.Current.IsReadOnly } catch { $false }
            }).Count
          } catch { }
        }
      }
    }
  } catch {
    "poll $i : FindAll threw $($_.Exception.Message)"
  }
  $el = [int]((Get-Date) - $t0).TotalMilliseconds
  "poll {0,2}  t=+{1,5}ms  totalDescendants={2,4}  pageDocuments={3}  pageEdits={4}  pageWritable={5}" -f $i, $el, $total, $docs, $edits, $writable
  if ($docs -gt $maxDocs) { $maxDocs = $docs }
  if ($edits -gt $maxEdits) { $maxEdits = $edits }
  if ($writable -gt $maxWritable) { $maxWritable = $writable }
  if ($i -lt $Polls) { Start-Sleep -Milliseconds $EveryMs }
}

''
if ($maxDocs -gt 0 -and $maxWritable -gt 0) {
  'VERDICT: LAZY ACTIVATION. The page document and a writable control appear WITHOUT the flag ' +
  '(pageDocuments=' + $maxDocs + ' pageWritable=' + $maxWritable + '), so an engine only has to ' +
  're-query with a deadline. The browser family IS reachable via UIA without taking the foreground.'
} elseif ($maxDocs -gt 0 -and $maxWritable -eq 0) {
  'VERDICT: the page document appears WITHOUT the flag (pageDocuments=' + $maxDocs +
  ') but exposes NO writable control (pageWritable=0). Page reading works; page WRITING stays ' +
  'unreachable, since Chromium ignores WM_CHAR for the renderer.'
} else {
  'VERDICT: NO page document after ' + $Polls + ' polls / ' + [int]((Get-Date) - $t0).TotalSeconds +
  's WITHOUT the flag (pageDocuments=0). In this configuration page content is gated on a ' +
  'launch-time state the engine cannot impose on an already-open browser.'
}
