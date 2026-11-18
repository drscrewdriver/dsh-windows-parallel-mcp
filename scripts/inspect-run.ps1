# inspect-run.ps1 — launch the WinForms positive control and dump its real UIA tree.
# Used to fix the matrix's element/pattern selection after the positive control failed:
# a control that is present but not found by the query is a bug in the query.
param([int]$HoldMs = 40000)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$wf = Join-Path $PSScriptRoot 'winforms-target.ps1'
$p = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $wf, '-HoldMs', "$HoldMs" -PassThru
$deadline = (Get-Date).AddSeconds(20)
$hwnd = 0
while ((Get-Date) -lt $deadline) {
  $pp = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
  if ($pp -and $pp.MainWindowHandle -ne 0) { $hwnd = [int64]$pp.MainWindowHandle; break }
  Start-Sleep -Milliseconds 300
}
if ($hwnd -eq 0) { Write-Output "FAIL no window handle from pid $($p.Id)"; exit 1 }
Write-Output "HWND=$hwnd"
Start-Sleep -Milliseconds 1200

$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd)
if (-not $root) { Write-Output 'FAIL no UIA root'; exit 1 }
Write-Output "ROOT name='$($root.Current.Name)' type=$($root.Current.ControlType.ProgrammaticName) native=$($root.Current.NativeWindowHandle)"

foreach ($scope in 'Children', 'Descendants') {
  $sc = [System.Windows.Automation.TreeScope]::$scope
  $all = $root.FindAll($sc, [System.Windows.Automation.Condition]::TrueCondition)
  Write-Output "SCOPE=$scope COUNT=$($all.Count)"
  $n = [Math]::Min($all.Count, 26)
  for ($i = 0; $i -lt $n; $i++) {
    $e = $all[$i]
    $ct = try { $e.Current.ControlType.ProgrammaticName } catch { '?' }
    $nm = try { $e.Current.Name } catch { '?' }
    $r = try { $e.Current.BoundingRectangle.ToString() } catch { '?' }
    $nat = try { $e.Current.NativeWindowHandle } catch { 0 }
    $pats = @(); try { foreach ($sp in $e.GetSupportedPatterns()) { $pats += ($sp.ProgrammaticName -replace 'Pattern$','') } } catch { }
    $val = ''
    try { $vp = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); if ($vp) { $val = "V='" + $vp.Current.Value + "' ro=" + [bool]$vp.Current.IsReadOnly } } catch { $val = 'V=err' }
    Write-Output ("[$i] $ct | name='$($nm.Substring(0,[Math]::Min(30,$nm.Length)))' | rect=$r | native=$nat | $($pats -join ',') | $val")
  }
}
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
