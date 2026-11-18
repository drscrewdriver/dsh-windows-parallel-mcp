# chromium-write-oracle.ps1 — can the UIA Value channel write a CHROMIUM PAGE input, and
# does writing it disturb the desktop?
#
# WHY A DOM-SIDE ORACLE. Two earlier runs of this measurement were both invalid, in the
# same way from two different directions:
#   * the first resolved "the first Edit in the window" and wrote to it. The value it read
#     back was 'abcQ' padded with spaces to about 60 columns -- that is Chromium's OMNIBOX,
#     browser UI, not page content. The channel demonstrably works on the omnibox; whether
#     it reaches a page's <input> was never tested.
#   * the second wrote through a cached page-element reference and read the element's own
#     ValuePattern.Value, getting null on both sides. That makes the effect test and the
#     thing under test the same object: if Chromium does not surface page text through the
#     Value property, "no effect" is unprovable from inside the provider whose behaviour is
#     in question.
# The oracle fixes the second problem: the page polls its own DOM value into a <div>, and
# UIA exposes that div's text as the element's Name. A change there means the RENDERER saw
# a new value -- a chain that cannot be faked by the pattern's read path.
#
# A POSITIVE CONTROL RUNS FIRST, AND GATES THE VERDICT. The page's own button sets the
# input's value from JS. If the oracle does not report that, the oracle is broken and
# nothing in this run says anything about Chromium. Without this, "the write channel is
# inert" and "my probe cannot see the page" produce identical numbers.
#
# FOCUS ATTRIBUTION IS ONLY MEANINGFUL IF THE TARGET IS NOT ALREADY FOREGROUND, so a second
# window we own holds the foreground for the measured rounds, and that is verified rather
# than assumed -- the same trap the background test had to step around twice.
param(
  [int]$Rounds = 5,
  [string]$ProfileDir = '',
  [string]$TitlePart = 'WpmOracle'
)
$ErrorActionPreference = 'Stop'
if (-not $ProfileDir) { throw 'ProfileDir is required: only an Edge this script launched may be touched' }
if ($ProfileDir -notmatch 'wpm-') { throw "refusing to use '$ProfileDir': no 'wpm-' probe marker" }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OR {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags; public IntPtr hwndActive; public IntPtr hwndFocus;
    public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret;
    public RECTrr rc;
  }
  [StructLayout(LayoutKind.Sequential)] public struct RECTrr { public int l, t, r, b; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint id, ref GUITHREADINFO gti);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  public static string Cursor() { POINT p; GetCursorPos(out p); return p.x + "," + p.y; }
  public static string Fg() { return GetForegroundWindow().ToInt64().ToString(); }
  public static string Focus() {
    IntPtr fg = GetForegroundWindow();
    uint tid = GetWindowThreadProcessId(fg, IntPtr.Zero);
    GUITHREADINFO g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    if (!GetGUIThreadInfo(tid, ref g)) return fg.ToInt64() + "/ERR";
    return fg.ToInt64() + "/" + g.hwndFocus.ToInt64();
  }
}
'@

function Find-Win([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

# The page owns the oracle: it polls its own input value into #out, whose text UIA exposes
# as the element's Name. Authored as a temp file loaded over file://, NOT a data: URL: the
# script needs both kinds of quote and '=' characters, and inlining it on a command line
# means nested quoting through Start-Process -> msedge -> the HTML attribute parser, where a
# broken handler fails SILENTLY -- the oracle would just never update and every round would
# read "the write did not work". A file has no quoting layer to lose a handler in.
$pageDir = Join-Path $env:TEMP 'wpm-oracle-page'
if (-not (Test-Path -LiteralPath $pageDir)) { New-Item -ItemType Directory -Path $pageDir -Force | Out-Null }
$html = @'
<!doctype html><html><head><meta charset="utf-8"><title>WpmOracle</title></head>
<body style="font:20px sans-serif">
<h3>oracle</h3>
<input id="k" value="abc">
<button id="b">js-set-value</button>
<div id="out">V=abc</div>
<script>
  var k = document.getElementById('k'), out = document.getElementById('out');
  function sync() { out.textContent = 'V=' + k.value; }
  k.addEventListener('input', sync);
  document.getElementById('b').addEventListener('click', function () {
    k.value = 'CLICKED'; sync();
  });
  // The oracle POLLS rather than relying on an event, because the question is whether the
  // renderer's value changed -- and which event a programmatic write synthesizes is exactly
  // the kind of detail that must not decide the measurement.
  setInterval(sync, 120);
  sync();
</script>
</body></html>
'@
$html = $html.Replace('<title>WpmOracle</title>', "<title>$TitlePart</title>")
[System.IO.File]::WriteAllText((Join-Path $pageDir 'page.html'), $html, (New-Object System.Text.UTF8Encoding($false)))
$p = (Join-Path $pageDir 'page.html') -replace '\\', '/'
$url = 'file:///' + $p

Start-Process msedge -ArgumentList @('--new-window', '--no-first-run', "--user-data-dir=$ProfileDir", "`"$url`"") | Out-Null
$w = $null
for ($i = 0; $i -lt 60 -and -not $w; $i++) { Start-Sleep -Milliseconds 500; $w = Find-Win $TitlePart }
if (-not $w) { throw 'probe Edge window never appeared' }
$hwnd = [IntPtr]$w.hwnd
"target window: hwnd=$hwnd pid=$($w.procId) url=$url"

# ---------------------------------------------------------------------------------
# page-scoped element resolution
#
# THE SCOPING IS THE FINDING'S PRECONDITION, not tidiness. Elements are enumerated as
# descendants of the page's OWN Document node, matched by the title this script authored.
# Searching the window and taking "the first Edit" is what produced the omnibox write: a
# browser window's UIA tree contains address bars, search boxes and sidebars before any page
# content, and every one of them is writable, so an unscoped search reports success against
# the wrong target while the page never changes.
function Get-PageNodes([IntPtr]$h, [string]$doc, [int]$ms) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) {
    try {
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
      $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      $n = [Math]::Min($all.Count, 4000)
      $docEl = $null
      for ($i = 0; $i -lt $n; $i++) {
        $ct = ''
        try { $ct = ($all[$i].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
        if ($ct -ne 'Document') { continue }
        $nm = ''
        try { $nm = [string]$all[$i].Current.Name } catch { }
        # The page title, not merely "a Document": browser UI has its own documents, and
        # matching any Document would reintroduce the bug this scoping exists to prevent.
        if ($nm -like "*$doc*") { $docEl = $all[$i]; break }
      }
      if (-not $docEl) { Start-Sleep -Milliseconds 400; continue }
      $kids = $docEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      $kn = [Math]::Min($kids.Count, 500)
      $edit = $null; $oracle = ''; $button = $null
      for ($j = 0; $j -lt $kn; $j++) {
        $ct = ''
        try { $ct = ($kids[$j].Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') } catch { continue }
        $nm = ''
        try { $nm = [string]$kids[$j].Current.Name } catch { }
        if (-not $edit -and $ct -eq 'Edit') {
          $vp = $null
          try {
            if ($kids[$j].TryGetCurrentPattern([System.Windows.Automation.ValuePatternIdentifiers]::Pattern, [ref]$vp)) {
              $edit = @{ el = $kids[$j]; vp = $vp }
            }
          } catch { }
        }
        if (-not $button -and $ct -eq 'Button' -and $nm -like '*js-set-value*') {
          $bp = $null
          try { if ($kids[$j].TryGetCurrentPattern([System.Windows.Automation.InvokePatternIdentifiers]::Pattern, [ref]$bp)) { $button = $bp } } catch { }
        }
        if ($ct -eq 'Text' -and $nm -like 'V=*') { $oracle = $nm }
      }
      if ($edit -and $oracle -and $button) {
        return @{ edit = $edit; button = $button; oracle = $oracle; docName = $doc; kids = $kn; ms = $sw.ElapsedMilliseconds }
      }
      if ($edit) {
        # Report what the page actually exposes, so a missing oracle is visible as data
        # rather than surfacing as an unexplained timeout.
        "incomplete page tree (waited $($sw.ElapsedMilliseconds)ms): edit=$([bool]$edit) oracle='$oracle' button=$([bool]$button) pageDescendants=$kn"
      }
    } catch { }
    Start-Sleep -Milliseconds 400
  }
  return $null
}

$pn = Get-PageNodes $hwnd $TitlePart 30000
if (-not $pn) {
  'VERDICT: INSTRUMENT INVALID -- could not resolve the page input, the oracle div and the ' +
  'page button together within 30s. This run says nothing about Chromium reachability.'
  exit 2
}
"page resolved after $($pn.ms)ms: pageDescendants=$($pn.kids) oracle='$($pn.oracle)' (lazy a11y, no flag)"

# ---- POSITIVE CONTROL: change the value by JS, and see whether the oracle reports it ----
# If this fails, the oracle cannot see DOM value changes and every 'no effect' below would
# be a property of the probe, not of the write channel.
$pcF0 = [OR]::Focus(); $pcC0 = [OR]::Cursor()
$oracleBefore = $pn.oracle
try { $pn.button.Invoke() } catch { 'positive control Invoke threw: ' + $_.Exception.Message }
Start-Sleep -Milliseconds 1200
$pc = Get-PageNodes $hwnd $TitlePart 4000
$oracleAfter = if ($pc) { $pc.oracle } else { 're-resolve-failed' }
$pcF1 = [OR]::Focus(); $pcC1 = [OR]::Cursor()
$oracleWorks = ($oracleAfter -eq 'V=CLICKED')
"POSITIVE CONTROL: oracle '$oracleBefore' -> '$oracleAfter' expected 'V=CLICKED'  alive=$oracleWorks  fgMoved=$($pcF0 -ne $pcF1)"

# Put a window WE own in the foreground, so a foreground change caused by a write is
# attributable and "target was already on top" cannot masquerade as neutrality.
$grabExit = Join-Path $env:TEMP ('wpm-oracle-' + [guid]::NewGuid().ToString('N') + '.stop')
$grabProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '90000', '-ExitFile', "`"$grabExit`"",
  '-GrabFgAfterMs', '1200' -PassThru
$g = $null
for ($i = 0; $i -lt 50 -and -not $g; $i++) { Start-Sleep -Milliseconds 400; $g = Find-Win 'WpmWinFormsTarget' }
if (-not $g) { throw 'foreground hand-off window never appeared' }
$grabH = [IntPtr]$g.hwnd
$handoff = $false
for ($i = 0; $i -lt 30 -and -not $handoff; $i++) { $handoff = ([OR]::Fg() -eq $grabH.ToString()); if (-not $handoff) { Start-Sleep -Milliseconds 400 } }
if (-not $handoff) { throw "hand-off window never took the foreground ($([OR]::Fg())); neutrality would be unmeasurable" }
"hand-off ok: foreground=$grabH, target $hwnd is in the BACKGROUND (iconic=$([OR]::IsIconic($hwnd)))"

function Split-Oracle([string]$t) {
  # 'V=<value>' -> <value>. Substring(1) would keep the '=' and write '=abcQ': a silently
  # wrong expected value that no round could ever match, turning a working channel into a
  # reported failure.
  if ($t -like 'V=*') { return $t.Substring(2) }
  return $null
}

# The sampler runs across the MEASURED window and nothing else. A bare "the foreground
# changed once" is not attributable to the engine, and blaming a human mouse click on the
# write channel would be the mirror image of the mistake RM-4 exists to prevent.
$proofDir = Join-Path $env:USERPROFILE '.dsh\windows-parallel-mcp\proof'
if (-not (Test-Path -LiteralPath $proofDir)) { New-Item -ItemType Directory -Path $proofDir -Force | Out-Null }
$samplerOut = Join-Path $proofDir ('probe-oracle-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '.jsonl')
$samplerStop = Join-Path $env:TEMP ('wpm-oracle-stop-' + [guid]::NewGuid().ToString('N'))
$samplerProc = Start-Process powershell -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
  '-File', (Join-Path $PSScriptRoot 'probe-worker.ps1'), '-Hz', '20', '-DurationMs', '0',
  '-Out', "`"$samplerOut`"", '-StopFile', "`"$samplerStop`"" -PassThru -WindowStyle Hidden
# A sampler that died at startup records zero samples, and zero samples would make every
# channel look perfectly neutral. Verify it is writing before trusting anything it says.
$warm = (Get-Date).AddSeconds(12)
while ((Get-Date) -lt $warm -and (-not (Test-Path -LiteralPath $samplerOut) -or (Get-Item $samplerOut).Length -lt 300)) {
  Start-Sleep -Milliseconds 200
}
$samplerBytes = if (Test-Path -LiteralPath $samplerOut) { (Get-Item $samplerOut).Length } else { 0 }
"sampler: pid=$($samplerProc.Id) out=$samplerOut bootBytes=$samplerBytes"

$rows = @()
for ($r = 1; $r -le $Rounds; $r++) {
  $cur = Get-PageNodes $hwnd $TitlePart 6000
  if (-not $cur) {
    $rows += [pscustomobject]@{ round = $r; kind = 'page-setvalue'; oracle0 = 'unresolved'; oracle1 = 'unresolved'
      expected = ''; valueRead = 'n/a'; fg0 = [OR]::Focus(); fg1 = [OR]::Focus(); changed = $false; effect = $false
      error = 'page nodes not resolvable this round' }
    continue
  }
  $oBefore = $cur.oracle
  $base = Split-Oracle $oBefore
  if ($null -eq $base) {
    $rows += [pscustomobject]@{ round = $r; kind = 'page-setvalue'; oracle0 = $oBefore; oracle1 = $oBefore
      expected = ''; valueRead = ''; fg0 = [OR]::Focus(); fg1 = [OR]::Focus(); changed = $false; effect = $false
      error = 'oracle text not parseable' }
    continue
  }
  $expected = 'V=' + $base + 'Q'
  # What the pattern itself reports, recorded separately from the oracle. If Value get
  # throws or returns something other than the DOM value, that is a finding about
  # Chromium's provider and must appear in the record rather than corrupt the effect test.
  $vRead = ''
  try { $vRead = [string]$cur.edit.vp.Current.Value } catch { $vRead = 'read-threw: ' + $_.Exception.Message }
  $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $f0 = [OR]::Focus(); $cx0 = [OR]::Cursor()
  $err = $null
  try { $cur.edit.vp.SetValue($base + 'Q') } catch { $err = $_.Exception.Message }
  Start-Sleep -Milliseconds 500
  $f1 = [OR]::Focus(); $cx1 = [OR]::Cursor()
  $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $after = Get-PageNodes $hwnd $TitlePart 4000
  $oAfter = if ($after) { $after.oracle } else { 're-resolve-failed' }
  $rows += [pscustomobject]@{ round = $r; kind = 'page-setvalue'; oracle0 = $oBefore; oracle1 = $oAfter
    expected = $expected; valueRead = $vRead; fg0 = $f0; fg1 = $f1; changed = ($f0 -ne $f1)
    cursor0 = $cx0; cursor1 = $cx1; effect = ($oAfter -eq $expected); error = $err
    t0 = $t0; t1 = $t1 }
  Start-Sleep -Milliseconds 600
}

# Close the sampler through its own handshake so its tail samples survive: killing the
# process mid-write loses exactly the last second, where a slow effect would land.
Set-Content -LiteralPath $samplerStop -Value 'stop' -Force
$sd = (Get-Date).AddSeconds(10)
$graceful = $false
while ((Get-Date) -lt $sd -and -not $graceful) {
  if ((Get-Content -LiteralPath $samplerOut -Tail 1 -ErrorAction SilentlyContinue) -match '#done') { $graceful = $true }
  else { Start-Sleep -Milliseconds 150 }
}
if (-not $graceful) { try { Stop-Process -Id $samplerProc.Id -Force -ErrorAction Stop } catch { } }
Remove-Item $samplerStop -Force -ErrorAction SilentlyContinue
$samples = @(Get-Content -LiteralPath $samplerOut -ErrorAction SilentlyContinue |
  Where-Object { $_ -and $_ -notmatch '^#' } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
"sampler: rows=$($samples.Count) stoppedCleanly=$graceful"

# GetLastInputInfo reports MS SINCE the last physical input, so a sample's implied event
# time is ts - inputAgeMs. When that implied time advances between two samples, a human
# touched the mouse or keyboard inside the gap, and any cursor or foreground change there
# belongs to the human rather than to the write under test.
function Get-WindowAttribution([long]$a, [long]$b) {
  # Transition-level, per action window. Returns counts of foreground and focus transitions
  # split by whether the SAME sample gap carried a physical-input event.
  $in = @($samples | Where-Object { $_.ts -ge ($a - 100) -and $_.ts -le ($b + 100) } |
          Sort-Object { [long]$_.ts })
  if ($in.Count -lt 2) {
    return @{ samples = $in.Count; fgSoft = $null; fgHuman = $null; focusSoft = $null; focusHuman = $null;
             cursorSoftPx = $null; quietFrac = $null }
  }
  $fgSoft = 0; $fgHuman = 0; $fcSoft = 0; $fcHuman = 0; $curSoft = 0.0; $quietMs = 0; $spanMs = 0
  for ($i = 1; $i -lt $in.Count; $i++) {
    $gap = [long]$in[$i].ts - [long]$in[$i - 1].ts
    if ($gap -lt 0) { continue }
    $ea = [long]$in[$i - 1].ts - [long]$in[$i - 1].inputAgeMs
    $eb = [long]$in[$i].ts - [long]$in[$i].inputAgeMs
    # ageMs of -1 means GetLastInputInfo failed on that sample: the gap is then unknown,
    # and unknown must NOT be counted as "human" (that would launder a software change into
    # an exemption). Unknown gaps are left out of both buckets and reported as coverage loss.
    $known = ($in[$i - 1].inputAgeMs -ge 0) -and ($in[$i].inputAgeMs -ge 0)
    $human = $known -and ($eb -gt $ea + 2)
    $spanMs += $gap
    if ($known -and -not $human) { $quietMs += $gap }
    if ($in[$i].fg -ne $in[$i - 1].fg) { if ($human) { $fgHuman++ } elseif ($known) { $fgSoft++ } }
    if ($in[$i].focus -ne $in[$i - 1].focus) { if ($human) { $fcHuman++ } elseif ($known) { $fcSoft++ } }
    if ($known -and -not $human) {
      $dx = [double]$in[$i].cx - [double]$in[$i - 1].cx
      $dy = [double]$in[$i].cy - [double]$in[$i - 1].cy
      $curSoft += [Math]::Sqrt($dx * $dx + $dy * $dy)
    }
  }
  $qf = if ($spanMs -gt 0) { [Math]::Round(100.0 * $quietMs / $spanMs, 1) } else { 0 }
  return @{ samples = $in.Count; fgSoft = $fgSoft; fgHuman = $fgHuman; focusSoft = $fcSoft;
            focusHuman = $fcHuman; cursorSoftPx = [Math]::Round($curSoft, 1); quietFrac = $qf }
}
for ($i = 0; $i -lt $rows.Count; $i++) {
  $rw = $rows[$i]
  if ($rw.kind -ne 'page-setvalue' -or -not $rw.t0) { continue }
  $at = Get-WindowAttribution $rw.t0 $rw.t1
  $rows[$i] | Add-Member -NotePropertyName fgSoft -NotePropertyValue $at.fgSoft -Force
  $rows[$i] | Add-Member -NotePropertyName fgHuman -NotePropertyValue $at.fgHuman -Force
  $rows[$i] | Add-Member -NotePropertyName focusSoft -NotePropertyValue $at.focusSoft -Force
  $rows[$i] | Add-Member -NotePropertyName cursorSoftPx -NotePropertyValue $at.cursorSoftPx -Force
  $rows[$i] | Add-Member -NotePropertyName quietFrac -NotePropertyValue $at.quietFrac -Force
  $rows[$i] | Add-Member -NotePropertyName windowSamples -NotePropertyValue $at.samples -Force
}

$writes = @($rows | Where-Object { $_.kind -eq 'page-setvalue' })
$effN = @($writes | Where-Object { $_.effect }).Count
$fgN = @($writes | Where-Object { $_.changed }).Count
$tookTarget = @($writes | Where-Object { $_.changed -and (($_.fg1 -split '/')[0] -eq $hwnd.ToString()) }).Count
$curMoved = @($writes | Where-Object { $_.cursor0 -ne $_.cursor1 }).Count
# The numbers R2 is judged on: disturbance NOT explained by physical input. A raw
# foreground-move count of 1 that falls inside a human click is a clean channel; the same 1
# on a quiet desktop is a violation. Only the attributed version may be quoted.
# Summed transition-level counts. $fgUnattributable counts rounds where the sampler gave
# too few samples to attribute at all: those are POWER LOSS, reported next to the totals so
# a zero can never be read as a pass on a run that could not have detected a violation.
$fgUnexplained = @($writes | ForEach-Object { if ($_.fgSoft) { [int]$_.fgSoft } else { 0 } } | Measure-Object -Sum).Sum
$curUnexplainedPx = [double](@($writes | ForEach-Object { if ($null -ne $_.cursorSoftPx) { [double]$_.cursorSoftPx } else { 0 } } | Measure-Object -Sum).Sum)
$fgHumanTotal = @($writes | ForEach-Object { if ($_.fgHuman) { [int]$_.fgHuman } else { 0 } } | Measure-Object -Sum).Sum
$focusUnexplained = @($writes | ForEach-Object { if ($_.focusSoft) { [int]$_.focusSoft } else { 0 } } | Measure-Object -Sum).Sum
$unattributable = @($writes | Where-Object { $null -eq $_.fgSoft }).Count
$minQuiet = 100.0
foreach ($wr in $writes) { if ($null -ne $wr.quietFrac -and [double]$wr.quietFrac -lt $minQuiet) { $minQuiet = [double]$wr.quietFrac } }
if ($unattributable -eq $writes.Count) { $minQuiet = -1 }

''
"rounds=$Rounds oracleAlive=$oracleWorks writesWithDomEffect=$effN writesMovingForeground=$fgN writesTakingTargetForeground=$tookTarget writesMovingCursor=$curMoved"
"attributed per-transition: softwareForegroundChanges=$fgUnexplained softwareFocusChanges=$focusUnexplained softwareCursorPathPx=$curUnexplainedPx  humanForegroundChanges=$fgHumanTotal  unattributableRounds=$unattributable/$Rounds  minQuietPctInWindow=$minQuiet"
''
$writes | ForEach-Object {
  # valueRead is truncated because Chromium pads it to the visible column width: printing it
  # raw buries the one thing that matters (whether it matches the oracle at all).
  $vr = [string]$_.valueRead
  if ($vr.Length -gt 20) { $vr = $vr.Substring(0, 20) + '...' }
  "  oracle '$($_.oracle0)' -> '$($_.oracle1)' exp '$($_.expected)' valueRead='$vr' fg=$($_.fg0)->$($_.fg1) softFg=$($_.fgSoft) humanFg=$($_.fgHuman) softFocus=$($_.focusSoft) cursorPx=$($_.cursorSoftPx) quiet=$($_.quietFrac)% err=$($_.error)"
}
''
if (-not $oracleWorks) {
  'VERDICT: INSTRUMENT INVALID -- the DOM oracle did not report a value the page set itself. ' +
  'No statement about the UIA write channel may be quoted from this run.'
} elseif ($unattributable -gt 0 -or $minQuiet -lt 20) {
  "VERDICT: UNDER-POWERED, NOT A PASS -- unattributable rounds $unattributable/$Rounds, lowest " +
  "physically-quiet share inside an action window $minQuiet%. A software-caused count of zero " +
  'here may mean the channel is neutral or that the desktop was too busy for the instrument to ' +
  'tell. Re-run on a quieter desktop, or drive it with the batch harness that holds the human ' +
  'out of the measured window.'
} elseif ($unattributable -gt 0) {
  "VERDICT: INSTRUMENT INVALID -- $unattributable of $Rounds rounds had too few sampler rows " +
  'to attribute. An unattributable foreground change is neither clean nor dirty; this run ' +
  'may not be quoted as evidence either way.'
} elseif ($effN -eq 0) {
  if ($fgUnexplained -gt 0) {
    'VERDICT: the oracle is alive, so SetValue did NOT reach the page in any round, and the ' +
    "sampler still attributes $fgUnexplained software-caused foreground changes to it. On " +
    'Chromium the UIA write channel would be inert as a writer and disruptive as an actor: ' +
    'the worst case for R2, and the case where a "0 disturbance" headline must never be quoted.'
  } else {
    'VERDICT: the oracle is alive and SetValue never reached the page, with zero foreground and ' +
    'cursor disturbance. So on this Chromium the UIA Value channel cannot write page content at ' +
    'all -- target_unreachable for the largest interactive family, but not a focus violation. ' +
    'Page text entry would need the message channel (which Chromium ignores for the renderer) ' +
    'or an explicit handoff, and the README must say so.'
  }
} elseif ($effN -eq $writes.Count -and $fgUnexplained -eq 0 -and $curUnexplained -eq 0) {
  'VERDICT: UIA SetValue reaches Chromium page content (the DOM oracle confirms every write) ' +
  'while a DIFFERENT window holds the foreground, and the sampler attributes 0 foreground ' +
  'changes, 0 focus changes and 0 cursor pixels to the software across all rounds. R2 holds on ' +
  'the browser family, provided the engine waits for lazy a11y activation and re-resolves page ' +
  'elements per action. Note the positive control itself moved the foreground (JS button press), ' +
  'so page interaction CAN be disruptive when it goes through the app -- which is why the write ' +
  'rounds are measured with the target in the background.'
} else {
  "VERDICT: MIXED -- effects $effN/$($writes.Count), software-caused foreground $fgUnexplained " +
  "(raw $fgN, of which human-explained $humanExplained), software-caused cursor $curUnexplained. " +
  'Quote the per-round table; a single rate would hide which rounds broke.'
}

$summary = [ordered]@{
  generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  window = @{ hwnd = $hwnd; pid = $w.procId; profile = $ProfileDir; url = $url }
  pageResolveMs = $pn.ms
  pageDescendants = $pn.kids
  oracleAlive = $oracleWorks
  positiveControl = @{ before = $oracleBefore; after = $oracleAfter; expected = 'V=CLICKED'; fgMoved = ($pcF0 -ne $pcF1) }
  handoffForegroundHeldBy = $grabH
  rounds = $Rounds
  writesWithDomEffect = $effN
  writesMovingForeground = $fgN
  writesTakingTargetForeground = $tookTarget
  writesMovingCursor = $curMoved
  transitionAttribution = @{
    softwareForegroundChanges = $fgUnexplained
    softwareFocusChanges = $focusUnexplained
    softwareCursorPathPx = $curUnexplainedPx
    humanForegroundChanges = $fgHumanTotal
    unattributableRounds = $unattributable
    minQuietPctInWindow = $minQuiet
  }
  samplerFile = $samplerOut
  samplerRows = $samples.Count
  samplerStoppedCleanly = $graceful
  rows = @($writes | ForEach-Object { @{
    round = $_.round; oracle0 = $_.oracle0; oracle1 = $_.oracle1; expected = $_.expected
    valueRead = $_.valueRead; fg0 = $_.fg0; fg1 = $_.fg1; focusChanged = $_.changed
    cursor0 = $_.cursor0; cursor1 = $_.cursor1; effect = $_.effect; error = $_.error
    t0 = $_.t0; t1 = $_.t1
    fgChangesSoftware = $_.fgSoft; fgChangesHuman = $_.fgHuman
    focusChangesSoftware = $_.focusSoft; cursorPathSoftwarePx = $_.cursorSoftPx
    quietPctInWindow = $_.quietFrac; windowSamples = $_.windowSamples
  } })
}
$outFile = Join-Path $env:TEMP 'wpm-oracle-summary.json'
[System.IO.File]::WriteAllText($outFile, ($summary | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
"SUMMARYFILE=$outFile"

try { Set-Content -LiteralPath $grabExit -Value 'exit' -Force } catch { }
Start-Sleep -Milliseconds 800
try { Stop-Process -Id $grabProc.Id -Force -ErrorAction Stop } catch { }
& powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
  (Join-Path $PSScriptRoot 'close-edge-profile.ps1') -ProfileDir $ProfileDir 2>&1 |
  ForEach-Object { "cleanup: $_" }
