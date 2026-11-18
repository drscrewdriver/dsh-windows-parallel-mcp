# debug-pick.ps1 — why did the channel pick (or refuse) the element it chose?
#
# WHY THIS EXISTS. After the chrome filter went in, Chromium's uia-setvalue went from 8/8
# ok to 0/8 "no USABLE ValuePattern element (raw=5)". Either the filter is right and the
# earlier 8/8 was measuring a chrome element, or the filter is over-aggressive and killed
# the page's own input -- and Chromium/Electron is the largest interactive family on this
# desktop, so the coverage verdict depends on which. This prints every candidate with the
# reason it was kept or dropped, so the decision is audited rather than inferred from an
# aggregate.
param(
  [string]$TitlePart = 'WpmNeutr',
  [switch]$LaunchChromium,
  [switch]$LaunchCalc
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

if ($LaunchChromium) {
  # The same URL the neutrality experiment authors, so the tree here IS the tree there.
  $url = 'data:text/html,<title>WpmNeutr</title><body style="font:16px sans-serif"><h3>neutrality</h3><input id=k value=abc style="width:320px;font-size:22px">'
  Start-Process msedge -ArgumentList @('--new-window', '--no-first-run', "`"$url`"") | Out-Null
  $d = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $d) { Start-Sleep -Milliseconds 500; if ((& powershell -NoProfile -File (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $TitlePart 2>$null)) { break } }
}

function Find-Win([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DP {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@

$w = Find-Win $TitlePart
if (-not $w) { throw "no window matching '$TitlePart'" }
$hwnd = [IntPtr]$w.hwnd
"target hwnd=$hwnd title='$($w.title)' class='$($w.cls)'"
# Bring it forward so its own document tree is realized the way the experiment would see
# it, then report the state we are actually reading.
[void][DP]::ShowWindow($hwnd, 9); [void][DP]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 1200

$root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
"descendants: $($all.Count)"

# Same vocabularies as focus-neutrality.ps1 -- copied rather than shared so a change here
# cannot silently alter the experiment, and a disagreement between the two is visible.
$chromeClass = 'ApplicationFrameTitleBarWindow', 'WindowChrome', 'DwmWindowWrapper', 'TitleGripper', 'NonClient'
$chromeName = '最小化', '最大化', '还原', '窗口菜单', 'Minimize', 'Maximize', 'Restore', 'Window Menu'
$unsafe = '关闭', '退出', '删除', '移除', '放弃', '注销', '关机', '结束任务',
         'Close', 'Quit', 'Exit', 'Delete', 'Remove', 'Discard', 'Sign out', 'Shut down', 'End task', 'Force quit'

$tw = [System.Windows.Automation.TreeWalker]::ControlViewWalker

function Class-Chain($el) {
  $out = @(); $p = $el; $d = 0
  while ($p -and $d -lt 10) {
    try { $cn = [string]$p.Current.ClassName } catch { break }
    if ($cn) { $out += $cn } else { $out += '(no class)' }
    try { $p = $tw.GetParent($p) } catch { break }
    $d++
  }
  return $out -join ' < '
}

$rows = @()
for ($i = 0; $i -lt [Math]::Min($all.Count, 400); $i++) {
  $e = $all[$i]
  $hasV = $false; $hasI = $false
  try { if ($e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)) { $hasV = $true } } catch { }
  try { if ($e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)) { $hasI = $true } } catch { }
  if (-not ($hasV -or $hasI)) { continue }
  $ct = '?'; try { $ct = ($e.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { }
  $nm = ''; try { $nm = [string]$e.Current.Name } catch { }
  if ($nm.Length -gt 30) { $nm = $nm.Substring(0, 30) }
  $ro = '?'
  if ($hasV) { try { $ro = [string]$e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.IsReadOnly } catch { $ro = 'unreadable' } }
  $val = ''
  if ($hasV -and $ro -ne 'True') { try { $val = [string]$e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { } }
  if ($val.Length -gt 24) { $val = $val.Substring(0, 24) }
  $cls = Class-Chain $e
  $isChrome = $false
  foreach ($pat in $chromeClass) { if ($cls -and $cls.IndexOf($pat, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $isChrome = $true } }
  foreach ($wv in $chromeName) { if ($nm -and $nm.IndexOf($wv, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $isChrome = $true } }
  $isUnsafe = $false
  foreach ($wv in $unsafe) { if ($nm -and $nm.IndexOf($wv, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $isUnsafe = $true } }
  $rows += [pscustomobject]@{
    idx = $i; ct = $ct; name = $nm; V = $hasV; I = $hasI; ro = $ro; val = $val
    verdict = $(if ($isChrome) { 'DROP chrome' } elseif ($isUnsafe) { 'DROP unsafe' } elseif ($hasV -and $ro -eq 'True') { 'DROP readonly' } else { 'KEEP' })
    clsChain = $(if ($cls.Length -gt 90) { $cls.Substring(0, 90) } else { $cls })
  }
}

''
$rows | Format-Table -AutoSize idx, ct, name, V, I, ro, verdict, val | Out-String -Width 220
''
'kept ValuePattern candidates : ' + (@($rows | Where-Object { $_.V -and $_.verdict -eq 'KEEP' }).Count)
'kept Invoke candidates       : ' + (@($rows | Where-Object { $_.I -and $_.verdict -eq 'KEEP' }).Count)
'dropped as chrome            : ' + (@($rows | Where-Object { $_.verdict -eq 'DROP chrome' }).Count)
'dropped as unsafe            : ' + (@($rows | Where-Object { $_.verdict -eq 'DROP unsafe' }).Count)
'dropped as read-only         : ' + (@($rows | Where-Object { $_.verdict -eq 'DROP readonly' }).Count)
''
'--- full class chains of the KEEP/DROP decisions ---'
$rows | ForEach-Object { "{0,3} {1,-10} {2,-20} {3} :: {4}" -f $_.idx, $_.ct, $_.name, $_.verdict, $_.clsChain }
