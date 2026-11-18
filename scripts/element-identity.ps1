# element-identity.ps1 — what identity fields does an element actually carry?
#
# Why: matching a control by NAME is fragile in a way that silently changes results. Two
# failures in this repo came from it -- Calculator's digit buttons are named "One"/"七"
# rather than "1" (so a ^\d$ filter found no buttons and the run declared the family
# unreachable), and the neutrality experiment's destructive filter keyed on localized
# names. AutomationId is what the competing approach uses for exactly this reason. This
# dumps name / automationId / className / controlType for every element in a window so the
# identity vocabulary can be chosen from evidence instead of guessed.
param(
  [Parameter(Mandatory = $true)][string]$TitlePart,
  [int]$Max = 600,
  [switch]$InteractiveOnly
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$findOut = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
  (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $TitlePart 2>$null
if (-not $findOut) { throw "no visible window matches '$TitlePart'" }
$info = ($findOut | Select-Object -Last 1) | ConvertFrom-Json
$hwnd = [IntPtr]$info.hwnd
"window: hwnd=$hwnd title='$($info.title)' class='$($info.cls)' pid=$($info.procId)"

$root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
"descendants: $($all.Count) (listing up to $Max)"
''
$n = [Math]::Min($all.Count, $Max)
$rows = @()
for ($i = 0; $i -lt $n; $i++) {
  $e = $all[$i]
  $ct = ''; $nm = ''; $au = ''; $cl = ''
  try { $ct = ($e.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { }
  try { $nm = [string]$e.Current.Name } catch { }
  try { $au = [string]$e.Current.AutomationId } catch { }
  try { $cl = [string]$e.Current.ClassName } catch { }
  $pats = @()
  foreach ($pr in @(
      @{ n = 'V'; p = [System.Windows.Automation.ValuePatternIdentifiers]::Pattern },
      @{ n = 'I'; p = [System.Windows.Automation.InvokePatternIdentifiers]::Pattern },
      @{ n = 'T'; p = [System.Windows.Automation.TogglePatternIdentifiers]::Pattern },
      @{ n = 'R'; p = [System.Windows.Automation.RangeValuePatternIdentifiers]::Pattern }
    )) {
    $ref = $null; $got = $false
    try { $got = $e.TryGetCurrentPattern($pr.p, [ref]$ref) } catch { $got = $false }
    if ($got) { $pats += $pr.n }
  }
  if ($InteractiveOnly -and -not ($pats.Count)) { continue }
  if ($nm.Length -gt 34) { $nm = $nm.Substring(0, 34) }
  if ($au.Length -gt 26) { $au = $au.Substring(0, 26) }
  $rows += [pscustomobject]@{ i = $i; ct = $ct; autoId = $au; name = $nm; cls = $cl; pats = ($pats -join '') }
}
$rows | Format-Table -AutoSize i, ct, autoId, name, cls, pats | Out-String -Width 200
''
$withId = @($rows | Where-Object { $_.autoId }).Count
"idCount=$withId / $($rows.Count) rows carry an AutomationId"
$idClickable = @($rows | Where-Object { $_.autoId -and $_.pats -match 'I|V|T|R' })
''
'--- clickable/interactive elements WITH an AutomationId (the identity the engine should use) ---'
$idClickable | Select-Object -First 40 | Format-Table -AutoSize ct, autoId, name, pats | Out-String -Width 160
