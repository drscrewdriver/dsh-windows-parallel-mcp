# neutral-coverage-census.ps1 — what fraction of reachable targets have a NEUTRAL channel?
#
# WHY THIS IS THE PRODUCT-DECIDING NUMBER. The channel matrix (g0-verdict.md) convicted both
# UIA pattern channels of raising their window and cleared both window-message channels, at a
# control base rate of 0/6. So the engine must route through WM_CHAR / WM_SETTEXT and refuse
# pattern-only actions. But a message needs a window ADDRESS, and modern toolkits report
# NativeWindowHandle=0 on their UIA elements: in WinUI3/UWP/Chromium the controls exist
# without any HWND to send anything to. If almost nothing has an address, the correct engine
# is also a nearly useless one -- and "correct but nearly useless" must be shipped AS AN
# HONEST REFUSAL, not quietly patched by re-enabling the disruptive channel that got us here.
#
# PER VISIBLE TOP-LEVEL WINDOW ON THIS MACHINE RIGHT NOW, this reports:
#   * toolkit family, by window class (same classifier as toolkit-census.ps1, extended);
#   * classic child HWNDs, split clickable / writable -- the message doors;
#   * whether UIA's own elements carry a NativeWindowHandle, which is the app-side statement
#     of the same fact and the one the engine actually routes on.
# READ-ONLY. No click, no type, no resize, no close. It walks other people's windows, and
# that is safe precisely because it never sends anything to them; the tests that change state
# run only on windows this repo launched.
#
# MINIMIZED IS ITS OWN CLASS, NOT A COVERAGE FAILURE. The probe record shows a minimized
# window's UIA tree comes back EMPTY. Folding those into a denominator would report
# unreachability where the truth is "this window is asleep"; and cloaked windows (visible to
# EnumWindows, invisible to the user) are excluded outright, because counting them as
# reachable inflates every ratio below.
param(
  [int]$MaxChildren = 400,
  [int]$UiaSampleCount = 8,
  # Fixed by default: a coverage number that differs on every invocation cannot be cited,
  # so the sampling is reproducible unless deliberately re-seeded.
  [int]$SampleSeed = 20261119,
  [switch]$SkipPositiveControl
)
function Find-Wpc([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}
function Get-EditChildren([IntPtr]$parent) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class CHC {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EP c, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  public static List<string> Edits(IntPtr parent) {
    List<string> acc = new List<string>();
    EnumChildWindows(parent, delegate (IntPtr h, IntPtr l) {
      StringBuilder cn = new StringBuilder(512); GetClassNameW(h, cn, cn.Capacity);
      string c = cn.ToString();
      if (c.IndexOf("EDIT", StringComparison.OrdinalIgnoreCase) >= 0 ||
          c.IndexOf("RichEdit", StringComparison.OrdinalIgnoreCase) >= 0)
        acc.Add(h.ToInt64() + "\t" + c);
      return true;
    }, IntPtr.Zero);
    return acc;
  }
}
'@ -ErrorAction SilentlyContinue
  return @( [CHC]::Edits($parent) )
}

$ErrorActionPreference = 'Stop'
# The same AppContext switches the launched targets set, and for the same reason: under PS
# 5.1's legacy defaults, WinForms controls surface through the MSAA bridge instead of real
# UIA providers, and properties like NativeWindowHandle answer 0 for a control that provably
# has an HWND. This process reads other people's UIA trees but never created a WinForms
# window, so nothing here had set them -- which is the difference between this census
# reporting "0% of actionable elements are addressable" and reporting the truth.
foreach ($sw in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.2', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.3') {
  try { [AppContext]::SetSwitch($sw, $false) } catch { }
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class NCC {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP c, IntPtr l);
  // Real signature: EnumChildWindows(HWND hWndParent, WNDENUMPROC lpEnumFunc, LPARAM lParam).
  // Declaring it as (callback, parent) -- as the first draft did -- puts the delegate pointer
  // in the parent slot and makes the "child scan" enumerate the children of an address,
  // silently producing a door count that is neither zero nor meaningful. The API answers
  // FALSE for an invalid handle, so nothing here would even have thrown.
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EP lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  // dwmapi.dll. The first fix for this wrote "dwvapi.dll" from memory, and the check I ran
  // to confirm it produced an EMPTY rc value -- a call that never happened -- which I read as
  // confirmation. `ls C:\Windows\System32\` then showed dwmapi.dll exists and dwvapi.dll does
  // not. A guessed library name is worse than a guessed function name: the loader throws
  // DllNotFoundException once, and anything that treats that as "not cloaked" makes every
  // window look reachable. So the failure is caught and reported as unknown (-1), never as 0.
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);

  public class Row {
    public long hwnd; public string cls; public string title; public long pid;
    public string family; public bool iconic; public int cloak;
    public int children; public int visChildren; public int clickable; public int writable;
  }

  static string Cls(IntPtr h) { var s = new StringBuilder(512); GetClassNameW(h, s, s.Capacity); return s.ToString(); }
  static string Txt(IntPtr h) { var s = new StringBuilder(512); GetWindowTextW(h, s, s.Capacity); return s.ToString(); }

  static int Cloaked(IntPtr h) {
    int v;
    // DWMWA_CLOAKED = 14. >0 means invisible to the user even though IsWindowVisible still
    // says true (virtual desktops, suspended UWP). -1 means the API refused: unknown, and
    // unknown is NOT the same as visible.
    try {
      if (DwmGetWindowAttribute(h, 14, out v, 4) != 0) return -1;
    } catch { return -1; }
    return v;
  }

  static string Family(string cls, string proc) {
    if (cls == "Chrome_WidgetWin_1" || cls == "Chrome_WidgetWin_0")
      return (proc == "msedge" || proc == "chrome") ? "chromium-browser" : "electron/chromium-app";
    if (cls == "WinUIDesktopWin32WindowClass") return "winui3-desktop";
    if (cls == "Windows.UI.Core.CoreWindow") return "uwp-corewindow";
    if (cls == "ApplicationFrameWindow" || cls == "ApplicationFrameHost") return "uap-framed";
    if (cls == "CabinetWClass" || cls == "ExploreWClass") return "win32-shell";
    if (cls == "Notepad" || cls == "Pizenet_WindowClass") return "winui-notepad";
    if (cls.StartsWith("WindowsForms")) return "winforms";
    if (cls.StartsWith("wpf")) return "wpf-hwnd";
    if (cls == "CABINETWAX") return "explorer-view";
    if (cls.StartsWith("Sys")) return "win32-classic";
    if (cls.StartsWith("Tfrm") || cls.StartsWith("TF")) return "delphi";
    if (cls.StartsWith("wx")) return "wxwidgets";
    if (cls.StartsWith("Qt")) return "qt";
    if (cls == "FLUTTER0" || cls.StartsWith("FLUTTER")) return "flutter";
    if (cls.StartsWith("SDL")) return "sdl";
    if (cls.StartsWith("Gtk")) return "gtk";
    if (cls.IndexOf("XAML", StringComparison.OrdinalIgnoreCase) >= 0) return "xaml-island";
    if (cls == "TTkTopLevelWindow" || cls == "TkChild" || cls.StartsWith("Tk")) return "tk";
    if (cls == "MozillaWindowClass") return "gecko";
    if (cls == "PUROE" || cls == "Chrome_WidgetWin_2") return "chrome-internal";
    return "other:" + cls;
  }

  // Clickable and writable by CLASS, which is the honest test for "a window message could
  // address this". Deliberately conservative: a class not listed is not counted, so this
  // file understates door coverage rather than overstating it, and the understatement is
  // visible here rather than buried in a ratio.
  static bool Clickable(string c) {
    if (c.Equals("Button", StringComparison.OrdinalIgnoreCase)) return true;
    if (c.StartsWith("WindowsForms", StringComparison.OrdinalIgnoreCase) && c.Contains("BUTTON")) return true;
    if (c == "ToolbarWindow32" || c == "SysTreeView32" || c == "SysListView32" || c == "msctls_trackbar32") return true;
    if (c.StartsWith("TButton", StringComparison.OrdinalIgnoreCase) || c == "wxButton") return true;
    return false;
  }
  static bool Writable(string c) {
    if (c.Equals("EDIT", StringComparison.OrdinalIgnoreCase)) return true;
    if (c.StartsWith("WindowsForms", StringComparison.OrdinalIgnoreCase) &&
        (c.Contains(".EDIT") || c.Contains("RichEdit"))) return true;
    if (c.StartsWith("RichEdit", StringComparison.OrdinalIgnoreCase)) return true;
    if (c.Equals("COMBOBOX", StringComparison.OrdinalIgnoreCase)) return true;
    if (c.Equals("Scintilla", StringComparison.OrdinalIgnoreCase)) return true;
    if (c.StartsWith("TEdit", StringComparison.OrdinalIgnoreCase) || c == "wxTextCtrl") return true;
    return false;
  }

  public static List<Row> Scan(int maxChildren) {
    List<Row> acc = new List<Row>();
    EnumWindows(delegate (IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      string title = Txt(h);
      // A window with no title is not something the user can point at, and the earlier
      // census learned that including these makes the family table lie about the desktop.
      if (string.IsNullOrEmpty(title)) return true;
      string cls = Cls(h);
      uint pid; GetWindowThreadProcessId(h, out pid);
      Row r = new Row();
      r.hwnd = h.ToInt64(); r.cls = cls; r.title = title; r.pid = pid;
      r.iconic = IsIconic(h); r.cloak = Cloaked(h);
      r.family = Family(cls, "");
      List<string> kids = new List<string>();
      EnumChildWindows(h, delegate (IntPtr ch, IntPtr cl) {
        if (kids.Count >= maxChildren) return false;
        kids.Add(Cls(ch));
        return true;
      }, IntPtr.Zero);
      r.children = kids.Count;
      foreach (string kc in kids) {
        if (Clickable(kc)) r.clickable++;
        if (Writable(kc)) r.writable++;
      }
      acc.Add(r);
      return true;
    }, IntPtr.Zero);
    return acc;
  }

  // Process name is resolved by the caller through Get-Process: doing it in C# needs
  // Process.KnownProcesses or a toolhelp snapshot, and a wrong name here silently mislabels
  // every electron-vs-chromium row in the table.
  public static void SetProc(List<Row> rows, Dictionary<long, string> names) {
    foreach (Row r in rows) {
      string n;
      if (names.TryGetValue(r.pid, out n)) r.family = Family(r.cls, n);
    }
  }
}
'@

$ErrorActionPreference = 'Stop'
# Parentheses are mandatory on a static method call with a variable argument: `[NCC]::Scan
# $MaxChildren` parses as a method group followed by a stray token and dies at runtime, which
# is the third time this exact class of mistake appeared in this repo -- the parse gate now
# catches it in 400ms instead of after an experiment has been arranged around it.
$scanned = [NCC]::Scan($MaxChildren)
"top-level windows with a title and WS_VISIBLE: $($scanned.Count)"

$names = @{}
foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
  if (-not $names.ContainsKey([long]$p.Id)) { $names[[long]$p.Id] = $p.ProcessName.ToLowerInvariant() }
}
# The dictionary is keyed by pid, and passed as a real Dictionary -- PowerShell hashtables
# arrive at a typed C# parameter as object and throw, which is the kind of failure that
# happens AFTER the scan and wastes the whole enumeration.
$dict = New-Object 'System.Collections.Generic.Dictionary[long,string]'
foreach ($k in $names.Keys) { $dict[[long]$k] = [string]$names[$k] }
[NCC]::SetProc($scanned, $dict)

$cloaked = @($scanned | Where-Object { $_.cloak -gt 0 }).Count
$unknownCloak = @($scanned | Where-Object { $_.cloak -lt 0 }).Count
$live = @($scanned | Where-Object { $_.cloak -le 0 })
$minimized = @($live | Where-Object { $_.iconic }).Count
"cloaked and excluded: $cloaked   (DWM attribute unreadable, kept but flagged: $unknownCloak)"
"live windows: $($live.Count)   minimized among them: $minimized"
''

$byFam = @{}
foreach ($r in $live) {
  if (-not $byFam.ContainsKey($r.family)) {
    $byFam[$r.family] = @{ windows = 0; doors = 0; click = 0; write = 0; iconics = 0; children = 0 }
  }
  $f = $byFam[$r.family]
  $f.windows++
  if ($r.clickable + $r.writable -gt 0) { $f.doors++ }
  $f.click += $r.clickable
  $f.write += $r.writable
  $f.children += $r.children
  if ($r.iconic) { $f.iconics++ }
}
'{0,-24} {1,7} {2,8} {3,10} {4,9} {5,9} {6,9}' -f 'family', 'windows', 'w/door', 'iconic', 'clickables', 'writables', 'door%'
foreach ($k in ($byFam.Keys | Sort-Object { -$byFam[$_].windows })) {
  $f = $byFam[$k]
  $pct = if ($f.windows) { [Math]::Round(100 * $f.doors / $f.windows) } else { 0 }
  '{0,-24} {1,7} {2,8} {3,10} {4,9} {5,9} {6,8}%' -f $k, $f.windows, $f.doors, $f.iconics, $f.click, $f.write, $pct
}
$totW = 0; $totD = 0
foreach ($k in $byFam.Keys) { $totW += $byFam[$k].windows; $totD += $byFam[$k].doors }
''
"WINDOW-LEVEL: $totD of $totW live windows have at least one classic child HWND this engine could message (" + [Math]::Round(100 * $totD / [Math]::Max(1, $totW)) + '%)'
$doorWin = @($live | Where-Object { $_.clickable + $_.writable -gt 0 })
"  their doors: clickable=$(($doorWin | Measure-Object -Property clickable -Sum).Sum) writable=$(($doorWin | Measure-Object -Property writable -Sum).Sum)"
''
# The family share of WINDOWS WITHOUT doors is the number that decides the plan. Not the
# door count: one app can own 200 child HWNDs and still be a single app the user switches
# between, while a doorless WinUI3 app is a whole application the engine cannot touch.
$nodoor = @($live | Where-Object { $_.clickable + $_.writable -eq 0 })
$nodoorFam = @{}
foreach ($r in $nodoor) { if (-not $nodoorFam.ContainsKey($r.family)) { $nodoorFam[$r.family] = 0 }; $nodoorFam[$r.family]++ }
'doorless windows by family (these are the targets a neutral channel cannot reach):'
foreach ($k in ($nodoorFam.Keys | Sort-Object { -$nodoorFam[$_] })) { "  {0,-24} {1}" -f $k, $nodoorFam[$k] }
''
if ($UiaSampleCount -gt 0) {
  # POSITIVE CONTROL, RUN FIRST. The raw result of this census was 0 UIA actionable elements
  # carrying an HWND out of 172, across every family including WinForms -- and "the neutral
  # channel reaches nothing anywhere on this machine" is the strongest possible claim in this
  # file, which makes it the claim least deserving of belief without a control. A WinForms
  # TextBox demonstrably HAS an HWND (EnumChildWindows returned it and WM_SETTEXT addressed
  # it), so if reading NativeWindowHandle on that same element answers 0, the property read
  # is broken here and the 0% describes the instrument, not the desktop. This is also the
  # known shape of the PS 5.1 legacy-provider problem already hit once in this repo: the
  # AppContext switches have to be set before any UIA client call, and this process never set
  # them, only the launched targets did.
  if (-not $SkipPositiveControl) {
    $pcExit = Join-Path $env:TEMP ('wpm-pc-' + [guid]::NewGuid().ToString('N') + '.stop')
    $pcProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
      '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '45000', '-ExitFile', "`"$pcExit`"",
      '-Title', 'WpmHwndProbe', '-X', '1500', '-Y', '60' -PassThru
    $pcw = $null
    for ($i = 0; $i -lt 40 -and -not $pcw; $i++) {
      Start-Sleep -Milliseconds 400
      $pcw = Find-Wpc 'WpmHwndProbe'
    }
    if (-not $pcw) {
      'POSITIVE CONTROL FAILED TO START: the WinForms probe window never appeared. The ' +
      'element-level ratio below is therefore UNVERIFIED and must not be quoted.'
      $pcRatio = $null
    } else {
      $pcH = [IntPtr]$pcw.hwnd
      # The child HWND is taken from the classic tree, so control and handle are known-good
      # independent of UIA; UIA is then asked the same question about the same control.
      $pcKid = @(Get-EditChildren $pcH | Select-Object -First 1)
      $pcKidH = if ($pcKid) { [int64](($pcKid[0] -split '\t')[0]) } else { 0 }
      $pcEls = 0; $pcHwndEls = 0; $pcTypes = @{}
      try {
        $pce = [System.Windows.Automation.AutomationElement]::FromHandle($pcH)
        $pcs = $pce.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt [Math]::Min($pcs.Count, 100); $i++) {
          $ct = ''
          try { $ct = ($pcs[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
          if (-not $pcTypes.ContainsKey($ct)) { $pcTypes[$ct] = 0 }
          $pcTypes[$ct]++
          $h2 = 0
          try { $h2 = [int64]$pcs[$i].Current.NativeWindowHandle } catch { }
          # Counted over ALL descendants, not just the actionable control types: what this
          # control must prove is that THIS PROCESS CAN READ THE PROPERTY. And it produced a
          # second finding -- our own WinForms TextBox/Button/RichTextBox arrive as ControlType
          # Pane, because powershell.exe still uses the legacy MSAA bridge for them, so an
          # actionable-type filter alone would report zero actionable elements for the ONE
          # family where the message channel actually works. Coverage drawn from control types
          # would have excluded the engine's only working target.
          if ($h2 -ne 0) { $pcHwndEls++ }
          $pcEls++
        }
      } catch { "positive control UIA read threw: $($_.Exception.Message)" }
      $pcRatio = if ($pcEls) { $pcHwndEls / $pcEls } else { -1 }
      "POSITIVE CONTROL (our own WinForms window, a child HWND known to exist: $pcKidH): " +
      "UIA descendants=$pcEls carrying an HWND=$pcHwndEls  controlTypes=$(($pcTypes.Keys | Sort-Object) -join '/')"
      if ($pcRatio -eq 0) {
        '  => THE PROPERTY READ IS BROKEN IN THIS PROCESS. NativeWindowHandle answers 0 even ' +
        'for a control whose HWND was just enumerated and addressed. The 0% figure below ' +
        'describes this instrument, not this desktop, and is NOT a coverage result.'
      } elseif ($pcRatio -lt 0) {
        '  => CONTROL UNUSABLE: no actionable elements resolved. The figure below is unverified.'
      } else {
        '  => control passes: the read works here, so a 0% below is a finding about the ' +
        'desktop, not about the instrument.'
      }
      ''
      try { Set-Content -LiteralPath $pcExit -Value 'exit' -Force } catch { }
      Start-Sleep -Milliseconds 700
      try { Stop-Process -Id $pcProc.Id -Force -ErrorAction Stop } catch { }
    }
  }
  # UIA's own answer, sampled. The engine routes on UIA elements, so "this control has an
  # HWND" means specifically that the UIA element reports NativeWindowHandle != 0 -- the
  # classic tree and the UIA tree disagree in both directions, and a coverage figure drawn
  # from only one of them is a figure about a window manager, not about the engine.
  'UIA NativeWindowHandle sample (live, non-minimized windows; actionable = Button/Edit/' +
  'Hyperlink/ListItem/TabItem/ComboBox):'
  $pool = @($live | Where-Object { -not $_.iconic })
  # DEDUPED BY FAMILY+TITLE. The first version sampled windows at random, and a desktop with
  # five Calculator windows and one Notepad is not five chances to learn about Calculator --
  # the 12-draw sample came back as Calculator x5, Notepad x4, which made the element ratio a
  # statement about whichever app happened to have the most windows open when the script ran.
  # One representative per distinct (family, title) is what "how addressable is this family"
  # actually requires; the count of windows per family is reported separately above.
  $uniq = @($pool | Group-Object { $_.family + '||' + $_.title } | ForEach-Object { $_.Group[0] })
  'distinct (family, title) groups available: ' + $uniq.Count
  $cand = @($uniq | Get-Random -SetSeed $SampleSeed -Count ([Math]::Min($UiaSampleCount, $uniq.Count)))
  "  (sampling seed=${SampleSeed}: the figure below is reproducible across runs on an unchanged " +
  'desktop; without a seed, the same command prints a different coverage percentage each time, ' +
  'and a number that cannot be re-obtained is not evidence)'
  $sumEls = 0; $sumAct = 0; $sumHwnd = 0; $okRows = 0
  $famAgg = @{}
  foreach ($s in $cand) {
    try {
      $el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$s.hwnd)
      $all = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      $n = 0; $act = 0; $actWithHwnd = 0
      for ($i = 0; $i -lt [Math]::Min($all.Count, 150); $i++) {
        $n++
        $ct = ''
        try { $ct = ($all[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
        if ($ct -notin 'Button', 'Edit', 'Hyperlink', 'ListItem', 'TabItem', 'ComboBox') { continue }
        $act++
        # Count HWND-carrying ONLY among the actionable elements. The first draft accumulated
        # withHwnd over the whole element set, then divided by the actionable count -- a ratio
        # of two different denominators whose value depends on how many non-actionable Panes a
        # window happens to expose. The question the engine asks is "of the controls I would act
        # ON, how many have a message address", which is a single conditional count.
        $hnd = 0
        try { $hnd = [int64]$all[$i].Current.NativeWindowHandle } catch { }
        if ($hnd -ne 0) { $actWithHwnd++ }
      }
      $okRows++
      '  {0,-38} {1,-20} els={2,4} actionable={3,3} actWithHwnd={4,4}' -f $s.title.Substring(0, [Math]::Min(36, $s.title.Length)), $s.family, $n, $act, $actWithHwnd
      $sumEls += $n; $sumAct += $act; $sumHwnd += $actWithHwnd
      if (-not $famAgg.ContainsKey($s.family)) { $famAgg[$s.family] = @{ act = 0; hwnd = 0; wins = 0 } }
      $famAgg[$s.family].act += $act; $famAgg[$s.family].hwnd += $actWithHwnd; $famAgg[$s.family].wins++
    } catch { "  '$($s.title)' UIA read threw: $($_.Exception.Message.Substring(0, [Math]::Min(60, $_.Exception.Message.Length)))" }
  }
  "  sampled windows: $okRows   UIA actionable elements: $sumAct   of which carrying an HWND: $sumHwnd"
  if ($sumAct) { '  ACTIONABLE-ELEMENT door ratio (UIA side): ' + [Math]::Round(100 * $sumHwnd / $sumAct) + '%' }
  ''
  '  per-family actionable addressability (sampled windows only):'
  foreach ($fk in ($famAgg.Keys | Sort-Object { -$famAgg[$_].act })) {
    $fa = $famAgg[$fk]
    $pp = if ($fa.act) { [Math]::Round(100 * $fa.hwnd / $fa.act) } else { 0 }
    '    {0,-24} windows={1,2} actionable={2,4} withHwnd={3,4}  {4}%' -f $fk, $fa.wins, $fa.act, $fa.hwnd, $pp
  }
  ''
  '  Note the two ratios above are not the same question: WINDOW-level asks whether anything in'
  '  an app can be messaged, ELEMENT-level asks whether the specific control the agent wants is'
  '  addressable. The engine decides per action, so the element-level ratio is the operative'
  '  one for coverage -- and it is computed on a random sample of windows, not a curated list,'
  '  because a curated list is how a coverage figure becomes marketing.'
}
