# probe-terminal-doors.ps1 — does a TERMINAL have a message door? (G0 line 3's third class)
#
# WHY THIS EXISTS. The coverage requirement names three target classes: browser, terminal,
# file manager. Two of them were measured; the terminal was not, because none was open, and an
# evidence line that says "three classes" while measuring two is the kind of gap that survives
# review precisely because nobody checks what a ticked box omits.
#
# WHY THE ANSWER IS NOT PREDICTABLE FROM THE CENSUS. Windows Terminal is the terminal family,
# but it is also a XAML/Composition host, so it may behave like uap-framed (no classic children
# to message) rather than like conhost (which does have one). That distinction decides whether
# the narrow product scope includes terminals at all -- an agent that cannot type into a
# terminal quietly is an agent that cannot do most of what a developer would want from it.
#
# READ-ONLY against windows it did not create, and it creates exactly one window, which it
# closes at the end. No keystroke is ever sent to a terminal: a WM_CHAR that DID land would
# execute nothing here (the shell is idle at a prompt it was never given), but the risk is not
# worth it, so the door is tested with WM_GETTEXT-style reads and UIA property reads only.
param([string]$Title = 'WpmTermProbe', [int]$WaitMs = 20000)
$ErrorActionPreference = 'Stop'
foreach ($sw in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3') {
  try { [AppContext]::SetSwitch($sw, $false) } catch { }
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class TD {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EP c, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  static string C(IntPtr h) { var s = new StringBuilder(512); GetClassNameW(h, s, s.Capacity); return s.ToString(); }
  public static List<string> Children(IntPtr top) {
    var acc = new List<string>();
    EnumChildWindows(top, delegate (IntPtr h, IntPtr l) {
      acc.Add(h.ToInt64() + "\t" + C(h) + "\t" + IsWindowVisible(h));
      return true;
    }, IntPtr.Zero);
    return acc;
  }
  public static string Text(IntPtr h) {
    int n = GetWindowTextLength(h); var s = new StringBuilder(n + 4);
    GetWindowTextW(h, s, s.Capacity); return s.ToString();
  }
}
'@
function Find-Win([string]$m) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $m 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

# WT supports --title, so the window is identifiable and closable by us alone. A new window,
# not the user's, is the whole point: this probe owns what it measures.
$wt = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
if (-not (Test-Path -LiteralPath $wt)) { 'wt.exe not found; cannot measure the terminal class' ; exit 0 }
$p = Start-Process $wt -ArgumentList '--title', $Title, '--headless', 'new-tab', '--cwd', $env:TEMP, 'cmd.exe', '/c', 'exit' -PassThru -ErrorAction SilentlyContinue
if (-not $p) { 'wt failed to start'; exit 0 }
$w = $null
for ($i = 0; $i -lt [int]($WaitMs / 400) -and -not $w; $i++) { Start-Sleep -Milliseconds 400; $w = Find-Win $Title }
if (-not $w) {
  # --headless may not exist on this build; fall back to an ordinary new window.
  $p = Start-Process $wt -ArgumentList '--title', $Title, 'new-tab', '--cwd', $env:TEMP, 'cmd.exe', '/k', 'title' -PassThru
  for ($i = 0; $i -lt 50 -and -not $w; $i++) { Start-Sleep -Milliseconds 400; $w = Find-Win $Title }
}
if (-not $w) {
  "no terminal window appeared for title '$Title' (pid $($p.Id)). The terminal class is " +
  'UNMEASURED by this run -- which is not the same as measuring nothing, and is recorded as ' +
  'a gap rather than folded into a coverage figure.'
  exit 0
}
$h = [IntPtr]$w.hwnd
"terminal window: hwnd=$h proc=$($w.process) cls=$($w.cls) title='$($w.title)'"
$kids = @([TD]::Children($h))
"classic child HWNDs: $($kids.Count)"
foreach ($k in $kids) { "  $k" }
$edit = @($kids | Where-Object { (($_ -split '\t')[1]) -match '(?i)EDIT|RichEdit|TermControl|Console' })
"children whose class looks like a text surface: $($edit.Count)"
''
# UIA's view of the same window: does the text area exist as an element, and does it carry an
# address a message could be sent to?
try {
  $el = [System.Windows.Automation.AutomationElement]::FromHandle($h)
  $all = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  "UIA descendants: $($all.Count) (first 12)"
  $withHwnd = 0; $docs = 0
  for ($i = 0; $i -lt [Math]::Min($all.Count, 400); $i++) {
    $ct = ''
    try { $ct = ($all[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { }
    $nh = 0
    try { $nh = [int64]$all[$i].Current.NativeWindowHandle } catch { }
    if ($nh -ne 0) { $withHwnd++ }
    if ($ct -eq 'Document') { $docs++ }
    if ($i -lt 12) {
      $nm = ''
      try { $nm = [string]$all[$i].Current.Name } catch { }
      "  ct=$ct native=$nh name='$($nm.Substring(0,[Math]::Min(40,$nm.Length)))'"
    }
  }
  "UIA elements carrying an addressable HWND: $withHwnd   Document elements: $docs"
  $docText = @($all | ForEach-Object {
    try { if (($_.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') -eq 'Document') { $_ } } catch { }
  })
  if ($docText.Count) {
    $pat = ''
    try {
      $tx = $null
      if ($docText[0].TryGetCurrentPattern([System.Windows.Automation.TextPatternIdentifiers]::Pattern, [ref]$tx)) { $pat = 'TextPattern YES' } else { $pat = 'TextPattern no' }
    } catch { $pat = "TextPattern probe threw" }
    "  text surface pattern check: $pat"
    "  (TextPattern is the door a quiet terminal writer would need. Its presence or absence " +
    'is what decides whether terminal text is reachable without a foreground-raising channel.)'
  }
} catch { "UIA read threw: $($_.Exception.Message)" }
''
# Close OUR window. WM_CLOSE to a window this script created, and nothing else.
[void][TD]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 1200
$gone = $null -eq (Find-Win $Title)
"cleanup: WM_CLOSE sent to our own terminal window, gone=$gone"
if (-not $gone) { '  still present: leaving it, and saying so, rather than Stop-Process on a terminal' }
