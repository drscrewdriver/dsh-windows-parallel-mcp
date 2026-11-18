# probe-winform-patterns.ps1 — does WinForms expose UIA patterns to this client at all?
#
# WHY: channel-raise-matrix reported InvokePattern=FALSE / ValuePattern=FALSE on our own
# WinForms children even with every legacy-accessibility AppContext switch set in the driver,
# and the elements were matched by exact NativeWindowHandle, so the address matching is not
# the explanation. `TryGetCurrentPattern` returning false is not evidence by itself -- it is
# one call's answer. AutomationElement.Current.SupportedPatterns is what UIA says the element
# implements, so this prints that, plus ControlType, for each child.
#
# WHY IT MATTERS FOR THE PLAN: if WinForms exposes message doors but no UIA patterns, and
# UWP/Chromium expose UIA patterns but no message doors, then the two kinds of door are
# complementary and mutually exclusive -- which means there is no target family where the
# engine can both find a control through UIA and act on it quietly. That is a much sharper
# statement of the G0 verdict than "coverage is 30%", and it is only true if this probe says so.
param([int]$HoldMs = 40000)
$ErrorActionPreference = 'Stop'
foreach ($sw in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.2', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.3') {
  try { [AppContext]::SetSwitch($sw, $false) } catch { }
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$P = Join-Path $PSScriptRoot 'find-window.ps1'
function Find-Win([string]$m) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $P -TitlePart $m 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}
$exit = Join-Path $env:TEMP ('wpm-pp-' + [guid]::NewGuid().ToString('N') + '.stop')
$proc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', "$HoldMs", '-ExitFile', "`"$exit`"",
  '-Title', 'WpmPatternProbe', '-X', '1000', '-Y', '430' -PassThru
$w = $null
for ($i = 0; $i -lt 40 -and -not $w; $i++) { Start-Sleep -Milliseconds 400; $w = Find-Win 'WpmPatternProbe' }
if (-not $w) { throw 'target never appeared' }
$h = [IntPtr]$w.hwnd
"target hwnd=$h pid=$($w.procId)"
$root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
"descendants: $($all.Count)"
for ($i = 0; $i -lt $all.Count; $i++) {
  $el = $all[$i]
  $ct = ''; $nm = ''; $nh = 0; $pats = ''
  try { $ct = ($el.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { }
  try { $nm = [string]$el.Current.Name } catch { }
  try { $nh = [int64]$el.Current.NativeWindowHandle } catch { }
  try {
    $sp = $el.Current.SupportedPatterns
    $pats = (@($sp | ForEach-Object { $_.ProgrammaticName -replace 'PatternIdentifiers\.Pattern$', '' }) -join ',')
  } catch { $pats = "SupportedPatterns threw: $($_.Exception.Message)" }
  "  [$i] ct=$ct native=$nh name='$nm' patterns=$pats"
}
# And the same question for the FRAME, since a pattern on the frame is not a pattern on the control.
$fc = ''
try { $fc = (@($root.Current.SupportedPatterns | ForEach-Object { $_.ProgrammaticName -replace 'PatternIdentifiers\.Pattern$', '' }) -join ',') } catch { }
"  frame: ct=$(([string]$root.Current.ControlType.ProgrammaticName)) patterns=$fc"
try { Set-Content -LiteralPath $exit -Value 'exit' -Force } catch { }
Start-Sleep -Milliseconds 900
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
