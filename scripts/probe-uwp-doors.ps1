# probe-uwp-doors.ps1 -- does a UWP / WinUI3 window have ANY non-physical input path?
#
# WHY THIS EXISTS. The desktop census recorded "setting/calculator: descendants=0" and concluded
# the XAML families are unreachable, while calc-display-oracle.ps1 had already driven Calculator
# with UIA Invoke and verified the effect on the app's own display readout. Both cannot be true.
# The candidate reconciliation: the census measured ONE hwnd, and a UWP app is not one hwnd --
# there is an ApplicationFrameWindow owned by ApplicationFrameHost.exe and the app's own
# Windows.UI.Core.CoreWindow. Measuring a window is not measuring an app. That is the same
# instrument-error shape as the rest of this repo's history.
#
# READ-ONLY. Nothing here sends input: no WM_CHAR, no Invoke, no focus change. It enumerates
# windows, then asks UIA and legacy MSAA what they can see. Doors tested:
#   A. UIA on the frame window (ApplicationFrameWindow) -- what the census did
#   B. UIA on every child window (the CoreWindow content lives here)
#   C. legacy MSAA (IAccessible) on the frame and on each child
# A door is OPEN only if it exposes at least one element supporting a pattern the engine could
# actually use (Invoke / Value / Toggle / Select / LegacyIAccessible / Text / ExpandCollapse /
# SelectionItem / RangeValue). "0 descendants" from one door is NOT a verdict about the app.
param(
  [string]$TitlePart = '',
  [string]$LaunchUri = '',
  [switch]$Activate,
  # WinUI3 / XAML hosts do not title themselves predictably (Terminal's title is the active tab),
  # so a class filter is the only stable handle on that family. Empty = ignore class.
  [string]$WindowClass = '',
  # NOTE: [char] + [char] in PowerShell adds the CODEPOINTS (an int), it does not concatenate.
  # That bug made the Chinese title pattern a number, which matched nothing useful and let the
  # probe walk the whole desktop. -join is the correct way to build a non-ASCII literal here,
  # and it avoids relying on the file's encoding being read as UTF-8 by Windows PowerShell 5.1.
  [string[]]$TitleParts = @('Calculator', (-join @([char]0x8BA1, [char]0x7B97, [char]0x5668))),
  [int]$MaxDescendants = 600,
  [int]$WaitSeconds = 20
)
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
public static class UD {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EP c, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP c, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr h, uint id, ref Guid iid,
    [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
  // A cloaked or minimized UWP window has NO accessibility tree: reading it while suspended
  // measures the suspension, not the app.
  public static int Cloaked(long h) { int v = -1; try { DwmGetWindowAttribute(new IntPtr(h), 14, out v, 4); } catch { } return v; }
  public static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassNameW(h, s, s.Capacity); return s.ToString(); }
  public static string Txt(IntPtr h) { var s = new StringBuilder(512); GetWindowTextW(h, s, s.Capacity); return s.ToString(); }
  public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  // Visible top-level windows (owned or not) whose title matches, PLUS any ApplicationFrameWindow
  // whose title matches -- the frame is what the census sampled, the CoreWindow is the content.
  public static List<string> FindTops(string[] parts, string wantClass) {
    var found = new List<string>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      string cls = Cls(h);
      if (wantClass.Length > 0 && cls.IndexOf(wantClass, StringComparison.OrdinalIgnoreCase) < 0) return true;
      string t = Txt(h);
      if (wantClass.Length > 0) { found.Add(h.ToInt64() + "|" + cls + "|" + Pid(h) + "|" + t); return true; }
      foreach (var p in parts) {
        if (p.Length > 0 && t.IndexOf(p, StringComparison.OrdinalIgnoreCase) >= 0) {
          found.Add(h.ToInt64() + "|" + Cls(h) + "|" + Pid(h) + "|" + t);
          break;
        }
      }
      return true; }, IntPtr.Zero);
    return found;
  }
  public static List<long> Children(long top) {
    var list = new List<long>();
    EnumChildWindows(new IntPtr(top), (h, l) => { list.Add(h.ToInt64()); return true; }, IntPtr.Zero);
    return list;
  }
  public static object Msaa(long h) {
    var iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
    object o;
    int hr = AccessibleObjectFromWindow(new IntPtr(h), 0xFFFFFFFC, ref iid, out o);
    if (hr != 0) return null;
    return o;
  }
}
'@

function Get-UiaReport([long]$h) {
  $r = [ordered]@{ hwnd = "$h"; cls = [UD]::Cls([IntPtr]$h); descendants = 0; patterns = 0; usable = 0; actions = 0; text = 0; sample = @(); error = '' }
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$h)
    if (-not $el) { $r.error = 'FromHandle returned null'; return $r }
    $all = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition)
    $r.descendants = $all.Count
    $names = New-Object System.Collections.ArrayList
    $n = [Math]::Min($all.Count, $MaxDescendants)
    for ($i = 0; $i -lt $n; $i++) {
      $e = $all.Item($i)
      $ps = $e.GetSupportedPatterns()
      $r.patterns += $ps.Count
      if (@($ps | Where-Object { $_.ProgrammaticName -match 'TextPattern' }).Count -gt 0) { $r.text++ }
      foreach ($p in $ps) {
        # 'Select' as a regex also matches SelectionPattern / SelectionItemPattern, and Text is a
        # READ pattern -- counting them as "usable" inflated the first version of this probe.
        # Only patterns that can DELIVER an action count; Text is tracked separately.
        if ($p.ProgrammaticName -match 'InvokePattern|ValuePattern|TogglePattern|SelectionItemPattern|ExpandCollapsePattern|RangeValuePattern|LegacyIAccessiblePattern') {
          $r.actions++
        }
        if ($p.ProgrammaticName -match 'Invoke|Value|Toggle|Select|LegacyIAccessible|Text|ExpandCollapse|RangeValue') {
          $r.usable++
          if ($names.Count -lt 8) {
            $nm = ''; try { $nm = $e.Current.Name } catch { }
            $ct = ''; try { $ct = $e.Current.ControlType.ProgrammaticName } catch { }
            [void]$names.Add((($ct -replace 'ControlType\.','') + '/' + ($p.ProgrammaticName -replace 'PatternIdentifiers\.','') -replace 'Pattern$','') + '/' + $nm)
          }
          break
        }
      }
    }
    $r.sample = @($names)
  } catch { $r.error = $_.Exception.Message }
  return $r
}

function Get-MsaaReport([long]$h) {
  $r = [ordered]@{ hwnd = "$h"; cls = [UD]::Cls([IntPtr]$h); accChildCount = -1; sample = @(); error = '' }
  try {
    $o = [UD]::Msaa($h)
    if (-not $o) { $r.error = 'AccessibleObjectFromWindow failed'; return $r }
    # Call through IDispatch: casting to Accessibility.IAccessible fails because the RCW carries
    # no type library, and that cast failure is an instrument bug, not evidence about the target.
    $r.accChildCount = [int]$o.accChildCount
    $names = New-Object System.Collections.ArrayList
    $n = [Math]::Min($r.accChildCount, 8)
    for ($i = 0; $i -lt $n; $i++) {
      try { $nm = $o.get_accName($i); if ($nm -and $names.Count -lt 8) { [void]$names.Add([string]$nm) } } catch { }
    }
    $r.sample = @($names)
  } catch { $r.error = $_.Exception.Message }
  return $r
}

if ($TitlePart) { $TitleParts = @($TitlePart) }
# NOTE: '-split [char]124' is a REGEX split, so '|' means ALTERNATION and the string is cut
# into single characters. That silently made every hwnd parse as the first digit and every door
# read all-zero -- another "suspect the instrument" case. String.Split() is the literal split.
function Get-HwndOf([string]$desc) { return [long]$desc.Split([char]124)[0] }

$out = [ordered]@{ searchedFor = ($TitleParts -join ' | '); launched = $false; tops = @(); doors = @(); verdict = '' }

# THE THING THIS PROBE LEARNED THE HARD WAY. A UWP app that is minimized or DWM-cloaked has its
# whole accessibility tree COLLAPSED to zero descendants -- not "slow to appear", not "a11y off".
# Calculator measured 0/0/0 suspended and 51 descendants the instant it was restored. The first
# version of this probe read the suspended state and produced an "UNREACHABLE" verdict, which is
# the exact instrument error this repo keeps repeating: a measurement that reads all-zero should
# make you suspect the instrument first. So: activate, wait for the cloak to clear, THEN measure.
$tops = [UD]::FindTops($TitleParts, $WindowClass)
if ($tops.Count -eq 0 -and $LaunchUri) {
  Start-Process $LaunchUri | Out-Null
  $out.launched = $true
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $tops = [UD]::FindTops($TitleParts, $WindowClass)
    if ($tops.Count -gt 0) { break }
  }
}
if ($tops.Count -eq 0) { $out.verdict = 'TARGET-NOT-FOUND (nothing visible matches)'; $out | ConvertTo-Json -Depth 6; exit }

$out.tops = @($tops)
# ORDER MATTERS AND IT WAS WRONG ONCE. This block must run AFTER $tops is enumerated, and the
# list must be re-read afterwards: activating a suspended app destroys and recreates its
# CoreWindow, so hwnds captured before activation are stale. The first version of this probe
# measured the cloaked window and reported UNREACHABLE -- the instrument, not the app.
$cloakInfo = @()
if ($Activate -and $tops.Count -gt 0) {
  $h0 = Get-HwndOf $tops[0]
  [void][UD]::ShowWindow([IntPtr]$h0, 9)
  [void][UD]::SetForegroundWindow([IntPtr]$h0)
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    if ([UD]::Cloaked($h0) -eq 0 -and -not [UD]::IsIconic([IntPtr]$h0)) { break }
    [void][UD]::ShowWindow([IntPtr]$h0, 9)
    [void][UD]::SetForegroundWindow([IntPtr]$h0)
    Start-Sleep -Milliseconds 300
  }
  Start-Sleep -Milliseconds 500
  $tops = [UD]::FindTops($TitleParts, $WindowClass)   # stale hwnds dropped here
  $out.tops = @($tops)
}
foreach ($desc in $tops) {
  $h = Get-HwndOf $desc
  $cloakInfo += ("hwnd " + $h + " cloaked=" + [UD]::Cloaked($h) + " iconic=" + [UD]::IsIconic([IntPtr]$h))
}
$out.cloak = $cloakInfo

$out.tops = @($tops)
foreach ($desc in $tops) {
  $h = Get-HwndOf $desc
  $uia = Get-UiaReport $h
  $out.doors += [ordered]@{ door = 'A: UIA on top-level'; hwnd = "$h"; cls = $uia.cls; descendants = $uia.descendants; usable = $uia.usable; actions = $uia.actions; text = $uia.text; error = $uia.error; sample = $uia.sample }
  $ms = Get-MsaaReport $h
  $out.doors += [ordered]@{ door = 'C: MSAA on top-level'; hwnd = "$h"; cls = $ms.cls; accChildCount = $ms.accChildCount; error = $ms.error; sample = $ms.sample }
  foreach ($c in ([UD]::Children($h) | Select-Object -First 12)) {
    $cu = Get-UiaReport $c
    if ($cu.descendants -gt 0 -or $cu.usable -gt 0 -or $cu.error) {
      $out.doors += [ordered]@{ door = 'B: UIA on child'; hwnd = "$c"; cls = $cu.cls; descendants = $cu.descendants; usable = $cu.usable; actions = $cu.actions; text = $cu.text; error = $cu.error; sample = $cu.sample }
    } else {
      $out.doors += [ordered]@{ door = 'B: UIA on child'; hwnd = "$c"; cls = $cu.cls; descendants = 0; usable = 0; error = $cu.error }
    }
    $cm = Get-MsaaReport $c
    if ($cm.accChildCount -gt 0 -or $cm.error) {
      $out.doors += [ordered]@{ door = 'C: MSAA on child'; hwnd = "$c"; cls = $cm.cls; accChildCount = $cm.accChildCount; error = $cm.error; sample = $cm.sample }
    }
  }
}

$open = @($out.doors | Where-Object { ($null -ne $_.usable -and $_.usable -gt 0) -or ($null -ne $_.accChildCount -and $_.accChildCount -gt 0) })
$out.verdict = if ($open.Count -gt 0) { 'REACHABLE -- ' + $open.Count + ' door(s) expose usable content' } else { 'UNREACHABLE -- no door exposes anything' }

Write-Host ('searched for : ' + $out.searchedFor)
Write-Host ('launched     : ' + $out.launched)
foreach ($c in $out.cloak) { Write-Host ('  ' + $c) }
Write-Host 'matched top-level windows:'
foreach ($t in $out.tops) { Write-Host ('  ' + $t) }
Write-Host ''
Write-Host ('{0,-22} {1,-38} {2,5} {3,4} {4,5} {5,4} {6,5}  {7}' -f 'door', 'class', 'desc', 'act', 'text', 'msaa', '', 'note')
foreach ($d in $out.doors) {
  $msaa = if ($null -ne $d.accChildCount) { $d.accChildCount } else { '-' }
  $desc = if ($null -ne $d.descendants) { $d.descendants } else { '-' }
  $act  = if ($null -ne $d.actions) { $d.actions } else { '-' }
  $txt  = if ($null -ne $d.text) { $d.text } else { '-' }
  $note = if ($d.error) { 'ERR: ' + $d.error.Substring(0, [Math]::Min(60, $d.error.Length)) } elseif ($d.sample.Count -gt 0) { ($d.sample | Select-Object -First 3) -join ' ; ' } else { '' }
  Write-Host ('{0,-22} {1,-38} {2,5} {3,4} {4,5} {5,5}  {6}' -f $d.door, $d.cls, $desc, $act, $txt, $msaa, $note)
}
Write-Host ''
Write-Host ('VERDICT: ' + $out.verdict)