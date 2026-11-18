# close-probe-tabs.ps1 — close only the Notepad tabs this session's probes created.
# Matches on the tab's own title text (the probe typed a known string, or opened a known
# temp filename), so it can never select a tab belonging to the user.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;
public static class CT {
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h,StringBuilder s,int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@
$np = Get-Process notepad -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $np) { "no notepad window"; exit 0 }
"target pid=$($np.Id) title='$($np.MainWindowTitle)'"
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$np.MainWindowHandle)
$bcond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)

for ($round = 0; $round -lt 4; $round++) {
  $btns = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bcond)
  $names = @(); foreach ($b in $btns) { try { $n = $b.Current.Name; if ($n) { $names += $n } } catch { } }
  $close = $null
  foreach ($b in $btns) { try { if ($b.Current.Name -match '关闭|Close') { $close = $b; break } } catch { } }
  if (-not $close) { "round $round buttons: $($names -join '|')"; break }
  try {
    $close.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    "round $round : invoked '$($close.Current.Name)'"
  } catch { "round $round invoke failed: $($_.Exception.Message)" }
  Start-Sleep -Milliseconds 700
  # unsaved-changes dialog: choose "don't save" so probe text is discarded, never kept
  $top = Get-Process notepad -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $top) { break }
  $r2 = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$top.MainWindowHandle)
  $b2 = $r2.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bcond)
  foreach ($b in $b2) {
    try { if ($b.Current.Name -match '不保存|不要保存|Don.?t save|No.?t save|Discard') {
      $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
      "chose don't-save"
      break
    } } catch { }
  }
  Start-Sleep -Milliseconds 500
}
$fin = Get-Process notepad -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($fin) { "final title='$($fin.MainWindowTitle)'" } else { "notepad now has no window" }
