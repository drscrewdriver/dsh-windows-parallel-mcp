# uia-background-test.ps1 — can UIA read a window that is NOT in the foreground?
#
# WHY THIS IS THE DECISIVE P0 EXPERIMENT. The neutrality run found 35 Invoke buttons in
# Calculator on round 1 and zero on rounds 2-8. The only thing that changed is that
# Calculator stopped being the foreground window. If UIA cannot enumerate a background
# XAML app, "use UIA, take no focus" cannot reach the desktop's largest family while the
# user works elsewhere -- which is the whole product premise -- and the verdict has to be
# judged on that rather than on a probe artifact.
#
# THE CONSTRUCTION THAT MAKES THIS VALID, AND THE ONE THAT DOESN'T.
# The first attempt moved the foreground with SetForegroundWindow from this process, which
# owns neither window. The foreground lock refuses that call, so phase B "measured a
# background target" while the target was in fact still foreground -- an invalid run that
# looked complete. Every state below is therefore produced with ShowWindow, which is NOT
# subject to the foreground lock, and every phase asserts its own precondition from
# GetForegroundWindow + IsIconic + IsWindowVisible rather than assuming it.
param(
  [string]$TitlePart = 'Calculator',
  [int]$MaxElements = 400
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BG {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  public static string Fg() { return GetForegroundWindow().ToInt64().ToString(); }
  // IsIconic, not a style bitmask: the first draft masked GWL_STYLE with 0x40000000,
  // which is not WS_MINIMIZE (0x20000000) and never lit, so a genuinely minimized window
  // reported minimized=False and the empty UIA tree that followed would have been blamed
  // on the wrong cause.
  public static string State(IntPtr h) {
    StringBuilder sb = new StringBuilder(256);
    GetWindowTextW(h, sb, sb.Capacity);
    return "{\"fg\":" + Fg() + ",\"iconic\":" + (IsIconic(h) ? "true" : "false") +
           ",\"visible\":" + (IsWindowVisible(h) ? "true" : "false") + ",\"title\":\"" + sb.ToString() + "\"}";
  }
}
'@

function Find-Win([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

function Get-Census([IntPtr]$hwnd) {
  $r = @{ root = 'none'; descendants = -1; valueEls = 0; invokeEls = 0 }
  $root = $null
  try { $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd) } catch { $r.root = 'exception' }
  if (-not $root) { return $r }
  $r.root = 'ok'
  $all = $null
  try { $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) }
  catch { $r.descendants = -2 }
  if ($null -eq $all) { return $r }
  $r.descendants = $all.Count
  $n = [Math]::Min($all.Count, $MaxElements)
  for ($i = 0; $i -lt $n; $i++) {
    try { if ($all[$i].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)) { $r.valueEls++ } } catch { }
    try { if ($all[$i].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)) { $r.invokeEls++ } } catch { }
  }
  return $r
}

$w = Find-Win $TitlePart
if (-not $w) {
  # Launch it ourselves so the fresh GUI process takes the foreground legitimately --
  # that is what makes phase A's "target is foreground" precondition reachable without
  # any cross-process activation call, which the foreground lock would refuse.
  Start-Process 'calculator:' | Out-Null
  for ($i = 0; $i -lt 40 -and -not $w; $i++) { Start-Sleep -Milliseconds 400; $w = Find-Win $TitlePart }
}
if (-not $w) { throw "no window matching '$TitlePart'" }
$calc = [IntPtr]$w.hwnd
"target: hwnd=$calc title='$($w.title)' class='$($w.cls)' pid=$($w.procId)"

# Phase A needs the target to BE the foreground window, and the only way to put it there
# from a process that owns neither window is to let a fresh launch do it. Calculator is
# single-instance and its state is a number, so restarting it is a safe, reversible way to
# obtain that state. The check is done through the window manager, not assumed: if the
# target already holds the foreground, nothing is restarted.
Start-Sleep -Milliseconds 1200
$st0 = [BG]::State($calc) | ConvertFrom-Json
if ($st0.fg -ne $calc.ToString()) {
  'target is not the foreground window; restarting it so a fresh launch takes the foreground'
  Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class CL{[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);public static void Close(IntPtr h){PostMessageW(h,0x0010,IntPtr.Zero,IntPtr.Zero);}}'
  [CL]::Close($calc)
  Start-Sleep -Milliseconds 2500
  Start-Process 'calculator:' | Out-Null
  $w2 = $null
  for ($i = 0; $i -lt 40 -and -not $w2; $i++) { Start-Sleep -Milliseconds 400; $w2 = Find-Win $TitlePart }
  if (-not $w2) { throw 'relaunched target never appeared' }
  $calc = [IntPtr]$w2.hwnd
  "target relaunched: hwnd=$calc"
  Start-Sleep -Milliseconds 1500
}
# NOTE: no control window is launched here. The first draft launched one before phase A,
# which handed the foreground to the control and made A's precondition unsatisfiable --
# the instrument had destroyed the state it was about to measure. Hand-off processes are
# launched lazily, at the phase that needs them.

$states = [ordered]@{ }
$pre = [ordered]@{ }
$extraProcs = @()

# Bring a window we own to the foreground by LAUNCHING A PROCESS for it at that moment --
# not by calling SetForegroundWindow/ShowWindow from this script. The foreground lock
# refuses cross-process activation from a process that is neither the current foreground
# process nor the last to receive input, and that is precisely how the first two drafts of
# this script "measured a background target" that had never left the foreground. A freshly
# launched GUI process is granted foreground rights, so the hand-off actually happens --
# and the assertion below checks it instead of trusting it.
function Hand-Fg {
  $ef = Join-Path $env:TEMP ('wpm-hand-' + [guid]::NewGuid().ToString('N') + '.stop')
  # -GrabFgAfterMs is what makes this phase valid at all. The target form normally shows
  # itself with SW_SHOWNA, deliberately NOT activating, so a plain launch leaves the
  # foreground with Calculator and phase B would measure a foreground target while
  # believing it measured a background one.
  $pp = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
    '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '60000', '-ExitFile', "`"$ef`"",
    '-GrabFgAfterMs', '1500' -PassThru
  $script:extraProcs += @{ file = $ef; proc = $pp }
  $h = $null
  for ($i = 0; $i -lt 50 -and -not $h; $i++) { Start-Sleep -Milliseconds 400; $h = Find-Win 'WpmWinFormsTarget' }
  if (-not $h) { throw 'hand-off window never appeared' }
  $hh = [IntPtr]$h.hwnd
  # Wait for the hand-off to actually land, rather than assuming it did. This is the
  # assertion whose absence made two earlier drafts silently invalid. Returning $null on
  # failure (instead of throwing) keeps the other phases running while making THIS phase
  # report its own broken precondition, so the run is invalid in the open.
  for ($i = 0; $i -lt 30; $i++) {
    if (([BG]::Fg()) -eq $hh.ToString()) { return $hh }
    Start-Sleep -Milliseconds 400
  }
  "!! hand-off failed: $hh never became foreground (fg is $([BG]::Fg())) -- the background phase will report an invalid precondition"
  return $null
}

# NOT named Measure: that collides with the built-in Measure-Object alias, which wins,
# so the call fell through to the cmdlet and died on a positional argument it cannot take.
function Test-State([string]$tag, [string]$expect, [scriptblock]$setup) {
  $info = & $setup
  Start-Sleep -Milliseconds 1400
  $st = [BG]::State($calc) | ConvertFrom-Json
  $c = Get-Census $calc
  $fgIsTarget = ($st.fg -eq $calc.ToString())
  $fgIsOther = ($null -ne $info.otherH -and $st.fg -eq $info.otherH.ToString())
  # Preconditions are asserted, not assumed. An unasserted phase is how an earlier version
  # reported a background reading for a window that was still foreground.
  $p = switch ($expect) {
    'target-fg' { $fgIsTarget -and (-not $st.iconic) }
    'other-fg' { $fgIsOther -and (-not $st.iconic) -and $st.visible }
    'minimized' { $st.iconic }
    default { $false }
  }
  $pre[$tag] = @{ pass = $p; expect = $expect; fgIsTarget = $fgIsTarget; fgIsOther = $fgIsOther; iconic = $st.iconic; visible = $st.visible }
  $states[$tag] = $c
  "{0,-14} pre={1,-5} fgIsTarget={2,-5} fgIsOther={3,-5} iconic={4,-5} visible={5,-5} descendants={6,-4} value={7,-3} invoke={8}" -f `
    $tag, $p, $fgIsTarget, $fgIsOther, $st.iconic, $st.visible, $c.descendants, $c.valueEls, $c.invokeEls
}

''
# A: target visible and foreground. A process launched just before this line legitimately
# holds the foreground, so no activation call is needed here.
Test-State 'A foreground' 'target-fg' { @{ otherH = $null } }

# B: target visible but NOT foreground -- the state a background app actually lives in.
$script:otherB = $null
Test-State 'B background' 'other-fg' {
  if (-not $script:otherB) { $script:otherB = Hand-Fg }
  @{ otherH = $script:otherB }
}

# C: target minimized -- the state a user leaves an idle app in.
Test-State 'C minimized' 'minimized' {
  if (-not $script:otherB) { $script:otherB = Hand-Fg }
  [void][BG]::ShowWindow($calc, 2)   # SW_MINIMIZE: no activation rights needed
  @{ otherH = $script:otherB }
}

# Leave the desktop as found: restore the target, close the windows we started.
[void][BG]::ShowWindow($calc, 9)
Start-Sleep -Milliseconds 500
foreach ($e in $extraProcs) {
  try { Set-Content -LiteralPath $e.file -Value 'exit' -Force } catch { }
}
Start-Sleep -Milliseconds 800
foreach ($e in $extraProcs) { try { Stop-Process -Id $e.proc.Id -Force -ErrorAction Stop } catch { } }

''
$allValid = -not (@($pre.Values | Where-Object { -not $_.pass }).Count)
$a = $states['A foreground']; $b = $states['B background']; $c = $states['C minimized']
if (-not $allValid) {
  'VERDICT: INVALID -- a phase ran without its precondition satisfied. No coverage claim may be quoted from this run.'
  foreach ($k in $pre.Keys) { if (-not $pre[$k].pass) { "  $k : expected '$($pre[$k].expect)', got fgIsTarget=$($pre[$k].fgIsTarget) fgIsOther=$($pre[$k].fgIsOther) iconic=$($pre[$k].iconic)" } }
} else {
  if ($a.descendants -gt 5 -and $b.descendants -gt 5) {
    if ($c.descendants -le 2) {
      'VERDICT: UIA reads a VISIBLE background XAML window normally, but returns an EMPTY tree once MINIMIZED. So a "no pattern elements" reading on an idle app means minimized/suspended, not unreachable: the engine must treat minimized targets as a separate refusal, not as evidence the family cannot be driven.'
    } else {
      'VERDICT: UIA ENUMERATION HOLDS IN THE BACKGROUND (both visible-background and minimized). The XAML family is reachable without focus, so the R2 premise survives on the desktop''s largest family.'
    }
  } elseif ($a.descendants -gt 5 -and $b.descendants -le 2) {
    'VERDICT: UIA ENUMERATION BREAKS WHEN THE WINDOW IS VISIBLE BUT IN THE BACKGROUND -- a reproducible reachability gap on the desktop''s largest family.'
  } else {
    'VERDICT: inconclusive. A descendants=' + $a.descendants + ' B=' + $b.descendants + ' C=' + $c.descendants
  }
}

try { Set-Content -LiteralPath $wfExit -Value 'exit' -Force } catch { }
Start-Sleep -Milliseconds 700
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
