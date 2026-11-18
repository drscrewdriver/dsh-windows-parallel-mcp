# chromium-page-write-neutrality.ps1 — does writing a PAGE input via UIA take focus?
#
# WHY THIS RUN EXISTS. An earlier neutrality run recorded "chromium uia-setvalue ok 8/8,
# tookFocus 8/8", which was the strongest single piece of evidence against R2 on the
# browser family. The element-pick debug then showed that the only writable ValuePattern
# the whole-window scan could find was the OMNIBOX -- browser UI, not the page. So that
# number measured "writing the address bar steals focus" (plausibly true, and irrelevant),
# not the claim under test.
#
# Meanwhile the lazy-activation probe proved the page subtree DOES become reachable, about
# 1.5-2s after a client first requests it, with no launch flag. So the honest question is
# narrow: when the engine writes the page's own <input> through ValuePattern.SetValue --
# after waiting for the tree -- does the foreground window or keyboard focus move?
#
# Per-action attribution against a read-only control round, same discipline as the main
# experiment. Edge is launched on a throwaway %TEMP% profile so the user's browser is never
# the thing being poked.
param(
  [int]$Rounds = 6,
  [string]$ProfileDir = '',
  [string]$TitlePart = 'WpmPageN',
  # 'cached' reuses the element found before the first write; 'refind' resolves the page
  # Edit again on every round. See the loop: which handle is used determines whether a
  # no-effect is a probe artifact or a property of Chromium.
  [ValidateSet('cached', 'refind')][string]$Mode = 'refind',
  # Reuse an Edge that is already running on this profile instead of launching a new one.
  # A fresh browser launch takes the foreground legitimately, and that hand-off is the one
  # thing a foreground-attribution run cannot afford to have inside its own window.
  [switch]$Reuse
)
$ErrorActionPreference = 'Stop'
if (-not $ProfileDir) { throw 'ProfileDir is required: this script must only ever touch an Edge it launched itself' }
if ($ProfileDir -notmatch 'wpm-') { throw "refusing to use '$ProfileDir': no 'wpm-' probe marker" }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PN {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags; public IntPtr hwndActive; public IntPtr hwndFocus;
    public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret;
    public RECTrc rcCaret;
  }
  [StructLayout(LayoutKind.Sequential)] public struct RECTrc { public int l, t, r, b; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint id, ref GUITHREADINFO gti);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public int cbSize; public uint dwTime; }
  [DllImport("kernel32.dll")] public static extern uint GetTickCount();
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);

  public static long TickMs() { return (long)GetTickCount(); }
  public static long AgeMs() {
    // cbSize must be Marshal.SizeOf, not a hand-written number: LASTINPUTINFO is 8 bytes,
    // and 12 makes GetLastInputInfo return FALSE -- an attribution source reading -1 while
    // looking like a legitimate measurement.
    LASTINPUTINFO li = new LASTINPUTINFO(); li.cbSize = Marshal.SizeOf(typeof(LASTINPUTINFO));
    if (!GetLastInputInfo(ref li)) return -1;
    return (long)GetTickCount() - (long)li.dwTime;
  }
  public static string Cursor() { POINT p; GetCursorPos(out p); return p.x + "," + p.y; }
  public static string Fg() { return GetForegroundWindow().ToInt64().ToString(); }
  public static string Focus() {
    IntPtr fg = GetForegroundWindow();
    uint tid = GetWindowThreadProcessId(fg, IntPtr.Zero);
    GUITHREADINFO gti = new GUITHREADINFO(); gti.cbSize = Marshal.SizeOf(gti);
    if (!GetGUIThreadInfo(tid, ref gti)) return fg.ToInt64() + "/ERR";
    return fg.ToInt64() + "/" + gti.hwndFocus.ToInt64();
  }
}
'@

function Find-Win([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

# Locate the page's own Edit: the Document whose Name is the page title, then an Edit
# inside it. Never the omnibox -- an element found by "first Edit in the window" is a
# browser control, and writing it is not the claim under test.
function Get-PageInput([IntPtr]$hwnd, [string]$docName, [int]$deadlineMs) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $deadlineMs) {
    try {
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
      $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      $n = [Math]::Min($all.Count, 4000)
      for ($i = 0; $i -lt $n; $i++) {
        $ct = ''
        try { $ct = ($all[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
        if ($ct -ne 'Document') { continue }
        $nm = ''
        try { $nm = [string]$all[$i].Current.Name } catch { }
        if ($nm -notlike "*$docName*") { continue }
        $kids = $null
        try { $kids = $all[$i].FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) } catch { }
        if (-not $kids) { continue }
        $kn = [Math]::Min($kids.Count, 500)
        for ($j = 0; $j -lt $kn; $j++) {
          $kct = ''
          try { $kct = ($kids[$j].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
          if ($kct -ne 'Edit') { continue }
          $vp = $null
          try { if (-not $kids[$j].TryGetCurrentPattern([System.Windows.Automation.ValuePatternIdentifiers]::Pattern, [ref]$vp)) { continue } } catch { continue }
          return @{ el = $kids[$j]; vp = $vp; ms = $sw.ElapsedMilliseconds }
        }
      }
    } catch { }
    Start-Sleep -Milliseconds 400
  }
  return $null
}

$url = "data:text/html,<title>$TitlePart</title><body><h3>page write neutrality</h3><input id=k value=abc style='width:320px;font-size:24px'></body>"
$launched = $false
$existing = Find-Win $TitlePart
if ($Reuse -and $existing) {
  $w = $existing
  "reusing an Edge window already running on this profile (no launch, so no foreground hand-off inside the measured window)"
} else {
  Start-Process msedge -ArgumentList @('--new-window', '--no-first-run', "--user-data-dir=$ProfileDir", "`"$url`"") | Out-Null
  $launched = $true
  $w = $null
  for ($i = 0; $i -lt 60 -and -not $w; $i++) { Start-Sleep -Milliseconds 500; $w = Find-Win $TitlePart }
  if (-not $w) { throw 'probe Edge window never appeared' }
}
$hwnd = [IntPtr]$w.hwnd
"window: hwnd=$hwnd class='$($w.cls)' pid=$($w.procId) mode=$Mode"

$pin = Get-PageInput $hwnd $TitlePart 20000
if (-not $pin) {
  'VERDICT: the page input never became reachable within 20s on a throwaway-profile Edge.'
  exit 2
}
"page Edit found after $($pin.ms)ms of polling (lazy activation, no flag)"

# Settle: the launch took the foreground legitimately; wait until nothing we do next can
# be confused with that.
Start-Sleep -Milliseconds 2500
$ownFg = [PN]::Fg()
"foreground before measurement: $ownFg (target is $hwnd, iconic=$([PN]::IsIconic($hwnd)))"

function Get-ChromeProbes([IntPtr]$h) {
  # Window title + omnibox value, captured before and after every write. Without them a
  # write that landed in browser chrome instead of the page would be reported as 'no
  # effect' -- and that is precisely the error the reachability matrix made once, when
  # WM_SETTEXT edited a window TITLE and got scored as a content write. Any change here
  # while the page value stayed put means the channel works but addresses the wrong thing.
  $out = @{ title = ''; omnibox = '' }
  try {
    $r = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    $out.title = [string]$r.Current.Name
    $all = $r.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $n = [Math]::Min($all.Count, 4000)
    for ($i = 0; $i -lt $n; $i++) {
      $nm = ''
      try { $nm = [string]$all[$i].Current.Name } catch { continue }
      if ($nm -match '地址和搜索栏|Address and search|Address Bar') {
        try {
          $vp = $all[$i].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
          if ($vp) { $out.omnibox = [string]$vp.Current.Value }
        } catch { }
        break
      }
    }
  } catch { }
  return $out
}

$rows = @()
for ($r = 1; $r -le $Rounds; $r++) {
  # CONTROL: read the same element's value. Any movement here is environmental.
  $c0 = [PN]::TickMs(); $cf0 = [PN]::Focus(); $cc0 = [PN]::Cursor()
  $null = $pin.vp.Current.Value
  $c1 = [PN]::TickMs(); $cf1 = [PN]::Focus(); $cc1 = [PN]::Cursor()
  $rows += [pscustomobject]@{ round = $r; kind = 'control-read'; ms = $c1 - $c0; fg0 = $cf0; fg1 = $cf1; cur0 = $cc0; cur1 = $cc1; changed = ($cf0 -ne $cf1) }
  Start-Sleep -Milliseconds 700

  # ACT: write the page input's value -- the engine's primary write channel.
  # WHICH HANDLE IS USED IS THE EXPERIMENT, not an implementation detail, so it is a mode:
  #   cached : the element found once, before any write, then reused every round -- what a
  #            long-lived worker pool would realistically do.
  #   refind : the element resolved fresh immediately before each write.
  # The distinction decides how a no-effect is read. If a cached reference goes stale when
  # Chromium rebuilds its accessibility tree, "0/6 effects" is an ARTIFACT of this probe. If
  # a freshly resolved element also refuses to change, then ValuePattern.SetValue is a
  # SILENT NO-OP on page content -- a reachability finding about the largest interactive
  # family on the desktop, not a bug report about the instrument. Both modes are therefore
  # run; neither result alone is interpretable.
  # Effect is verified by shape, not merely by inequality: WM_SETTEXT once edited a window's
  # TITLE and the reachability matrix scored it as a content write, which would have
  # fabricated a reachability rate. Reading back exactly the string we wrote is the only
  # effect test that an unrelated change elsewhere in the window cannot satisfy.
  if ($Mode -eq 'refind') {
    $pinNow = Get-PageInput $hwnd $TitlePart 6000
    if (-not $pinNow) {
      $rows += [pscustomobject]@{ round = $r; kind = 'page-setvalue'; ms = 0; fg0 = [PN]::Focus(); fg1 = [PN]::Focus()
        cur0 = [PN]::Cursor(); cur1 = [PN]::Cursor(); changed = $false; effect = $false
        error = 'page Edit not re-findable this round (tree rebuilt or page gone)' }
      Start-Sleep -Milliseconds 700
      continue
    }
  } else {
    $pinNow = $pin
  }
  $before = $null; try { $before = [string]$pinNow.vp.Current.Value } catch { }
  $cb = Get-ChromeProbes $hwnd
  $a0 = [PN]::TickMs(); $af0 = [PN]::Focus(); $ac0 = [PN]::Cursor()
  $err = $null
  try { $pinNow.vp.SetValue([string]$before + 'Q') } catch { $err = $_.Exception.Message }
  Start-Sleep -Milliseconds 300
  $after = $null; try { $after = [string]$pinNow.vp.Current.Value } catch { $after = 'readback-failed' }
  $a1 = [PN]::TickMs(); $af1 = [PN]::Focus(); $ac1 = [PN]::Cursor()
  $ca = Get-ChromeProbes $hwnd
  $eff = ($null -ne $after -and $after -eq ([string]$before + 'Q'))
  # Landed-elsewhere is its own outcome. If the page value did not change but the window
  # title or the omnibox did, the channel is NOT inert -- it is mis-addressed, and calling
  # that 'no effect' would understate what the engine can reach while hiding that it wrote
  # to something the user owns.
  $landed = (-not $eff) -and (($ca.title -ne $cb.title) -or ($ca.omnibox -ne $cb.omnibox))
  $rows += [pscustomobject]@{ round = $r; kind = 'page-setvalue'; ms = $a1 - $a0; fg0 = $af0; fg1 = $af1; cur0 = $ac0; cur1 = $ac1; changed = ($af0 -ne $af1) }
  try { $pinNow.vp.SetValue([string]$before) } catch { }
  $rows[-1] | Add-Member -NotePropertyName effect -NotePropertyValue $eff -Force
  $rows[-1] | Add-Member -NotePropertyName before -NotePropertyValue $before -Force
  $rows[-1] | Add-Member -NotePropertyName after -NotePropertyValue $after -Force
  if ($err) { $rows[-1] | Add-Member -NotePropertyName error -NotePropertyValue $err -Force }
  Start-Sleep -Milliseconds 700
}

$ctrlMoved = @($rows | Where-Object { $_.kind -eq 'control-read' -and $_.changed }).Count
$actMoved = @($rows | Where-Object { $_.kind -eq 'page-setvalue' -and $_.changed }).Count
$actOk = @($rows | Where-Object { $_.kind -eq 'page-setvalue' -and $_.effect }).Count
$actTookTargetFocus = @($rows | Where-Object {
  $_.kind -eq 'page-setvalue' -and $_.changed -and (($_.fg1 -split '/')[0] -eq $hwnd.ToString())
}).Count

$summary = [ordered]@{
  generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  window = @{ hwnd = $hwnd; pid = $w.procId; profile = $ProfileDir }
  lazyActivationMs = $pin.ms
  rounds = $Rounds
  controlReads = $Rounds
  controlFocusMoved = $ctrlMoved
  pageWrites = $Rounds
  pageWritesWithEffect = $actOk
  pageWriteFocusMoved = $actMoved
  pageWriteTookForeground = $actTookTargetFocus
  rows = @($rows | ForEach-Object { @{
    round = $_.round; kind = $_.kind; ms = $_.ms; fg0 = $_.fg0; fg1 = $_.fg1
    focusChanged = $_.changed; effect = $_.effect; error = $_.error
  } })
}
$out = Join-Path $env:TEMP 'wpm-pagewrite-summary.json'
$json = $summary | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($out, $json, (New-Object System.Text.UTF8Encoding($false)))
''
$summary.GetEnumerator() | Where-Object { $_.Key -ne 'rows' } | ForEach-Object { "{0,-24} {1}" -f $_.Key, $_.Value }
''
if ($actOk -lt $Rounds) {
  "VERDICT: INCOMPLETE -- only $actOk/$Rounds page writes had an observable effect; neutrality of a channel that did not work is not evidence."
} elseif ($actMoved -eq 0) {
  "VERDICT: writing the page's own input via ValuePattern.SetValue moved focus 0/$Rounds times while the control round also moved 0/$ctrlMoved. On this Chromium, the R2 write channel reaches page content AND is focus-neutral -- provided the engine waits for lazy a11y activation."
} else {
  "VERDICT: page SetValue moved focus $actMoved/$Rounds times (took foreground $actTookTargetFocus). For modern web content the UIA write channel is NOT focus-neutral, and control-group noise was $ctrlMoved/$Rounds."
}
"SUMMARYFILE=$out"

# Cleanup is part of the instrument, not an afterthought: these experiments run under a
# shell wrapper that reaps the command's process tree at exit, so an Edge left here would
# either be killed mid-write or linger on the user's desktop. The profile directory is the
# ownership proof, so only processes launched with it are stopped.
& powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
  (Join-Path $PSScriptRoot 'close-edge-profile.ps1') -ProfileDir $ProfileDir 2>&1 |
  ForEach-Object { "cleanup: $_" }
