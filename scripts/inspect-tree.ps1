# inspect-tree.ps1 — dump the UIA subtree of a recorded target (diagnostic aid).
# Used to design the reach matrix honestly: which control types exist, which patterns
# they support, what their values read as, and what their rects look like in UIA units
# versus the native child-window rects. Read-only; injects nothing.
param(
  [Parameter(Mandatory = $true)][string]$Hwnd,
  [int]$Max = 40
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([int64]$Hwnd))
if (-not $root) { throw "no UIA root for $Hwnd" }

$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
"TOTAL=$($all.Count)"
for ($i = 0; $i -lt $all.Count -and $i -lt $Max; $i++) {
  $e = $all[$i]
  $ct = try { $e.Current.ControlType.ProgrammaticName } catch { '?' }
  $nm = try { $e.Current.Name } catch { '?' }
  $r = try { $e.Current.BoundingRectangle.ToString() } catch { '?' }
  $pats = @()
  try { foreach ($sp in $e.GetSupportedPatterns()) { $pats += $sp.ProgrammaticName } } catch { }
  $val = ''
  try {
    $vp = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($vp) { $val = "value='" + $vp.Current.Value + "' ro=" + [bool]$vp.Current.IsReadOnly }
  } catch { }
  $hwndV = try { $e.Current.NativeWindowHandle } catch { 0 }
  "$i | $ct | name='$($nm.Substring(0,[Math]::Min(40,$nm.Length)))' | rect=$r | native=$hwndV | $val | patterns=$($pats -join ',')"
}
