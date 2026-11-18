# focus-neutrality.ps1 — per-action focus and cursor attribution (P0 verdict evidence).
#
# WHAT DECIDES THE PROJECT. R2 promises the agent works in its own windows while the human
# keeps the keyboard and mouse. R2.3 makes that checkable: zero real-cursor movement, zero
# foreground switches, zero keyboard-focus changes. The reachability matrix showed a split
# that threatens the whole claim: the UIA channels are the ONLY ones that land on modern
# XAML/Chromium targets, and several of them ended with keyboard focus ON the target acted
# on -- while the message channels could not find a child window to post to on those apps.
# If the only channel that reaches modern apps also takes focus, "true parallel" holds for
# one generation of software and the promise is not honest.
#
# METHOD -- three things the first version lacked:
#   1. Per-action bracketing. Each operation records focus before/after plus its own
#      timestamp span, so the sampler's continuous record can be attributed to THE ACTION,
#      not to the whole run. An aggregate cannot distinguish "SetValue took focus" from
#      "the human clicked elsewhere while we were typing".
#   2. Interleaved read-only control. A pattern-enumeration pass that cannot possibly
#      change anything runs in the same loop, the same number of times. If focus moves
#      during reads too, the movement is environmental (window settling, the human) and
#      must not be charged to the write channel. Without a control, a launch settling event
#      is indistinguishable from a focus-stealing call -- and that was exactly what the
#      first single-shot run appeared to show.
#   3. Repetition. ROUNDS per target per channel, so the result is a rate, not an anecdote.
#
# Cursor movement is attributed the same way: between the two samples bracketing an action,
# split by whether GetLastInputInfo moved. A cursor delta with NO physical input event in
# that gap can only come from software -- which is precisely the thing the claim forbids.
#
# SAFETY: only windows this script creates. No Notepad: one already sits on this desktop
# with a save dialog open, and UIA writes land wherever the caret is, so using it could
# type into the user's document. Targets here have no document state to damage.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File focus-neutrality.ps1
#        [-Rounds 10] [-Hz 20] [-OutDir path]
param(
  [int]$Rounds = 10,
  [int]$Hz = 20,
  [int]$SettleMs = 2500,
  [string]$OutDir = (Join-Path $env:USERPROFILE '.dsh\windows-parallel-mcp\proof')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class N {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags;
    public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
    public RECT rcCaret;
  }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, out GUITHREADINFO i);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
  [DllImport("user32.dll")] public static extern int GetWindowTextLengthW(IntPtr h);
  public delegate bool EB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EB cb, IntPtr l);

  public const uint WM_CHAR = 0x0102, WM_GETTEXTLENGTH = 0x000E, WM_SETTEXT = 0x000C,
                    WM_GETTEXT = 0x000D, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202,
                    WM_CLOSE = 0x0010;

  public static string Focus() {
    IntPtr fg = GetForegroundWindow();
    uint pid; uint tid = GetWindowThreadProcessId(fg, out pid);
    IntPtr fo = IntPtr.Zero;
    if (tid != 0) { GUITHREADINFO gi = new GUITHREADINFO(); gi.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
      if (GetGUIThreadInfo(tid, out gi)) fo = gi.hwndFocus; }
    return fg.ToInt64() + "/" + fo.ToInt64();
  }
  public static long Now() { return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); }

  public static string[] ChildInfo(IntPtr top) {
    List<string> acc = new List<string>();
    EB cb = delegate (IntPtr h, IntPtr l) {
      StringBuilder sb = new StringBuilder(256); GetClassNameW(h, sb, sb.Capacity);
      acc.Add(h.ToInt64() + ":" + sb.ToString()); return true; };
    EnumChildWindows(top, cb, IntPtr.Zero);
    return acc.ToArray();
  }
  public static void CloseWindow(IntPtr h) { PostMessageW(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); }
  public static int TextLen(IntPtr h) { return SendMessageW(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero).ToInt32(); }
  public static string GetText(IntPtr h) {
    int n = TextLen(h); if (n <= 0) return "";
    StringBuilder sb = new StringBuilder(n + 2); SendMessageW(h, WM_GETTEXT, (IntPtr)sb.Capacity, sb);
    return sb.ToString();
  }
  public static void SetText(IntPtr h, string s) { SetWindowTextW(h, s); }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SetWindowTextW(IntPtr h, string s);
  public static bool PostChar(IntPtr h, int ch) { return PostMessageW(h, WM_CHAR, (IntPtr)ch, (IntPtr)1); }
  public static int[] ClientOf(IntPtr h, int sx, int sy) {
    POINT p = new POINT(); p.x = sx; p.y = sy; ScreenToClient(h, ref p);
    return new int[] { p.x, p.y };
  }
  public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.l, r.t, r.r - r.l, r.b - r.t }; }
}
'@
Set-StrictMode -Off

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$actionsFile = Join-Path $OutDir "actions-$stamp.jsonl"
$recordFile = Join-Path $OutDir "neutrality-$stamp.jsonl"
$stopFile = Join-Path $env:USERPROFILE '.dsh\windows-parallel-mcp\stop'
try { Remove-Item $stopFile -Force -ErrorAction SilentlyContinue } catch { }

$enc = New-Object System.Text.UTF8Encoding($false)
$actW = New-Object System.IO.StreamWriter($actionsFile, $enc)
$actW.AutoFlush = $true

# ---------------------------------------------------------------------------------
# targets this script owns, one per toolkit generation
function Wait-Title([scriptblock]$m, [int]$sec) {
  $d = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $d) {
    foreach ($p in Get-Process | Where-Object { $_.MainWindowHandle -ne 0 }) {
      try { if (& $m $p) { return $p } } catch { }
    }
    Start-Sleep -Milliseconds 300
  }
  return $null
}

$made = @()          # cleanup registry
$targets = @()

# (a) classic Win32 child windows, reachable by WM_*
$wfExit = Join-Path $env:TEMP ('wpm-nf-' + [guid]::NewGuid().ToString('N') + '.stop')
$wfProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', '300000', '-ExitFile', "`"$wfExit`"" -PassThru
$made += @{ kind = 'process'; id = $wfProc.Id; file = $wfExit }
$w = Wait-Title { param($p) $p.MainWindowTitle -like '*WpmWinFormsTarget*' } 20
if ($w) {
  $targets += @{ id = 'winforms'; hwnd = [IntPtr]$w.MainWindowHandle; generation = 'win32' }
}

# (b) WPF: native UIA provider, no child window handles at all -- the generation where
#     UIA is the only door and message posting has no address to write to
$wpfExit = Join-Path $env:TEMP ('wpm-nw-' + [guid]::NewGuid().ToString('N') + '.stop')
$wpfProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'wpf-target.ps1'), '-HoldMs', '300000', '-ExitFile', "`"$wpfExit`"" -PassThru
$made += @{ kind = 'process'; id = $wpfProc.Id; file = $wpfExit }
$w2 = Wait-Title { param($p) $p.MainWindowTitle -like '*WpmWpfTarget*' } 20
if ($w2) { $targets += @{ id = 'wpf'; hwnd = [IntPtr]$w2.MainWindowHandle; generation = 'wpf' } }

# (c) Chromium: a data: URL we author, one <input> on the page
$edgeUrl = 'data:text/html,<title>WpmNeutr</title><body style="font:16px sans-serif"><h3>neutrality</h3><input id=k value=abc style="width:320px;font-size:22px">'
Start-Process msedge -ArgumentList @('--new-window', '--no-first-run', "`"$edgeUrl`"") | Out-Null
$w3 = Wait-Title { param($p) $p.MainWindowTitle -like '*WpmNeutr*' } 30
if ($w3) { $targets += @{ id = 'chromium'; hwnd = [IntPtr]$w3.MainWindowHandle; generation = 'chromium' } }

# (d) WinUI/XAML system app: Calculator. State is a number, so no document can be harmed.
Start-Process 'calculator:' | Out-Null
$w4 = Wait-Title { param($p) $p.MainWindowTitle -match '计算器|Calculator' } 25
if ($w4) { $targets += @{ id = 'winui-calc'; hwnd = [IntPtr]$w4.MainWindowHandle; generation = 'winui' } }

if ($targets.Count -lt 3) {
  $actW.Dispose()
  throw "only $($targets.Count) targets came up (need 3): $(($targets | ForEach-Object { $_.id }) -join ',')"
}

# ---------------------------------------------------------------------------------
# action recorder
function Rec([string]$action, [string]$target, [string]$op, [long]$t0, [long]$t1, [string]$f0, [string]$f1, [string]$outcome, [string]$why, [string[]]$own) {
  $moved = ($f0 -ne $f1)
  $after = ($f1 -split '/')[1]
  $onto = [bool]($moved -and $own -contains $after)
  # [pscustomobject], not [ordered]: an OrderedDictionary has no properties, so
  # Group-Object/Measure-Object over it report an empty key and every aggregate silently
  # collapses into one anonymous bucket.
  $r = [pscustomobject]@{
    round = $script:RoundIdx
    action = $action; target = $target; op = $op
    t0 = $t0; t1 = $t1; durationMs = [int]($t1 - $t0)
    focusBefore = $f0; focusAfter = $f1
    focusMoved = $moved; focusTakenOntoTarget = $onto
    outcome = $outcome; why = $why
  }
  $actW.WriteLine(($r | ConvertTo-Json -Compress))
  return $r
}

# ---------------------------------------------------------------------------------
# the sampler must be confirmed recording before any action runs
$sampler = Start-Process powershell -ArgumentList '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
  '-File', (Join-Path $PSScriptRoot 'probe-worker.ps1'), '-Hz', "$Hz", '-DurationMs', '0',
  '-Out', $recordFile, '-StopFile', $stopFile -WindowStyle Hidden -PassThru
try {
  $ready = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $ready -and (-not (Test-Path -LiteralPath $recordFile))) { Start-Sleep -Milliseconds 150 }
  if (-not (Test-Path -LiteralPath $recordFile)) { throw 'sampler never created its record' }
  $sz = (Get-Item $recordFile).Length
  while ($sz -lt 400) { Start-Sleep -Milliseconds 250; $sz = (Get-Item $recordFile).Length }
  Start-Sleep -Milliseconds $SettleMs

  $report = @()
  for ($round = 1; $round -le $Rounds; $round++) {
    $script:RoundIdx = $round
    foreach ($t in $targets) {
      $own = @([N]::ChildInfo($t.hwnd) | ForEach-Object { ($_ -split ':')[0] }) + @($t.hwnd.ToInt64().ToString()) | Select-Object -Unique

      $root = $null
      try { $root = [System.Windows.Automation.AutomationElement]::FromHandle($t.hwnd) } catch { }
      if (-not $root) {
        $report += Rec 'uia-root' $t.id 'control' ([N]::Now()) ([N]::Now()) ([N]::Focus()) ([N]::Focus()) 'refused' 'no UIA root (elevated or UIA-blocked process)' $own
        continue
      }

      # CONTROL: read-only enumeration. Cannot change anything by design, so whatever
      # focus movement appears here is environmental and defines the noise floor the write
      # channels have to beat.
      $c0 = [N]::Now(); $cf0 = [N]::Focus()
      $ve = @(); $ie = @()
      try {
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt [Math]::Min($all.Count, 120); $i++) {
          try { if ($all[$i].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)) { $ve += $all[$i] } } catch { }
          try { if ($all[$i].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)) { $ie += $all[$i] } } catch { }
        }
      } catch { }
      $c1 = [N]::Now(); $report += Rec 'read-enumerate' $t.id 'control' $c0 $c1 $cf0 ([N]::Focus()) 'ok' "valueEls=$($ve.Count) invokeEls=$($ie.Count)" $own

      # CHANNEL 1: UIA SetValue
      if ($ve.Count) {
        $vp = $null
        try { $vp = $ve[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern) } catch { }
        if ($vp -and -not $vp.Current.IsReadOnly) {
          $before = $vp.Current.Value
          $t0 = [N]::Now(); $f0 = [N]::Focus()
          try { $vp.SetValue([string]$before + 'Q') } catch {
            $report += Rec 'uia-setvalue' $t.id 'write' $t0 ([N]::Now()) $f0 ([N]::Focus()) 'refused' "exception: $($_.Exception.Message.Substring(0,[Math]::Min(90,$_.Exception.Message.Length)))" $own
          }
          Start-Sleep -Milliseconds 120
          $t1 = [N]::Now(); $f1 = [N]::Focus()
          $after = $null; try { $after = $vp.Current.Value } catch { }
          $eff = ($null -ne $after -and $after -ne $before)
          $report += Rec 'uia-setvalue' $t.id 'write' $t0 $t1 $f0 $f1 $(if ($eff) { 'ok' } else { 'no-effect' }) "value '$before' -> '$after'" $own
          try { $vp.SetValue([string]$before) } catch { }
        } else {
          $report += Rec 'uia-setvalue' $t.id 'write' ([N]::Now()) ([N]::Now()) ([N]::Focus()) ([N]::Focus()) 'refused' 'read-only or unreadable ValuePattern' $own
        }
      } else {
        $report += Rec 'uia-setvalue' $t.id 'write' ([N]::Now()) ([N]::Now()) ([N]::Focus()) ([N]::Focus()) 'absent' 'no ValuePattern element' $own
      }

      # CHANNEL 2: WM_CHAR into a child window of an input class
      $editLine = @([N]::ChildInfo($t.hwnd)) | Where-Object { $_ -match ':(Edit|RichEdit|RICHEDIT50W|Chrome_RenderWidgetHostHWND)$' } | Select-Object -First 1
      if ($editLine) {
        $eh = [IntPtr]([int64](($editLine -split ':')[0]))
        $cls = ($editLine -split ':')[1]
        $len0 = [N]::TextLen($eh)
        $t2 = [N]::Now(); $f2 = [N]::Focus()
        foreach ($c in 'abc'.ToCharArray()) { [void][N]::PostChar($eh, [int]$c); Start-Sleep -Milliseconds 20 }
        Start-Sleep -Milliseconds 200
        $t3 = [N]::Now(); $f3 = [N]::Focus()
        $len1 = [N]::TextLen($eh)
        $report += Rec 'wm-char' $t.id 'write' $t2 $t3 $f2 $f3 $(if ($len1 -ne $len0) { 'ok' } else { 'no-effect' }) "class=$cls textlen $len0 -> $len1" $own
      } else {
        $report += Rec 'wm-char' $t.id 'write' ([N]::Now()) ([N]::Now()) ([N]::Focus()) ([N]::Focus()) 'absent' 'no input-class child window to post to' $own
      }

      # CHANNEL 3: UIA Invoke (a click that the provider may implement by moving the
      # real cursor -- which is exactly what has to show up in the per-action cursor delta)
      if ($ie.Count) {
        $b = $ie[0]
        $n0 = ''; try { $n0 = $b.Current.Name } catch { }
        $t4 = [N]::Now(); $f4 = [N]::Focus()
        try { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch {
          $report += Rec 'uia-invoke' $t.id 'click' $t4 ([N]::Now()) $f4 ([N]::Focus()) 'refused' "exception: $($_.Exception.Message.Substring(0,[Math]::Min(90,$_.Exception.Message.Length)))" $own
        }
        Start-Sleep -Milliseconds 200
        $t5 = [N]::Now(); $f5 = [N]::Focus()
        $n1 = ''; try { $n1 = $b.Current.Name } catch { }
        $report += Rec 'uia-invoke' $t.id 'click' $t4 $t5 $f4 $f5 $(if ($n1 -ne $n0) { 'ok' } else { 'no-effect' }) "name '$n0' -> '$n1'" $own
      } else {
        $report += Rec 'uia-invoke' $t.id 'click' ([N]::Now()) ([N]::Now()) ([N]::Focus()) ([N]::Focus()) 'absent' 'no InvokePattern element' $own
      }

      Start-Sleep -Milliseconds 150
    }
  }
} finally {
  $actW.Flush(); $actW.Dispose()

  # stop the sampler through its own handshake, then read what it recorded
  Set-Content -LiteralPath $stopFile -Value ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -NoNewline
  $d = (Get-Date).AddSeconds(10)
  $done = $false
  while ((Get-Date) -lt $d -and -not $done) {
    $hit = $false
    if (Test-Path -LiteralPath $recordFile) {
      foreach ($ln in @(Get-Content -LiteralPath $recordFile -Encoding UTF8 -Tail 6)) {
        if ($ln -like '#done*') { $hit = $true; break }
      }
    }
    if ($hit) { $done = $true } else { Start-Sleep -Milliseconds 200 }
  }
  if (-not $done) { try { Stop-Process -Id $sampler.Id -Force -ErrorAction SilentlyContinue } catch { } }
}

# ---------------------------------------------------------------------------------
# attribution: per action, from the continuous record
$samples = @(Get-Content -LiteralPath $recordFile -Encoding UTF8 |
  Where-Object { $_ -and $_ -notlike '#*' } |
  ForEach-Object { try { $o = ConvertFrom-Json -InputObject $_ -ErrorAction Stop } catch { $o = $null }; if ($o) { $o } })

$perAction = @()
foreach ($a in $report) {
  $idx = @()
  for ($i = 0; $i -lt $samples.Count; $i++) {
    if ($samples[$i].ts -ge $a.t0 -and $samples[$i].ts -le ($a.t1 + 300)) { $idx += $i }
  }
  $maxMove = 0; $unexplained = 0; $fgCh = 0; $foCh = 0; $physEv = 0
  for ($k = 1; $k -lt $idx.Count; $k++) {
    $p = $samples[$idx[$k - 1]]; $q = $samples[$idx[$k]]
    $gap = $q.ts - $p.ts
    $ea = $p.ts - $p.inputAgeMs; $eb = $q.ts - $q.inputAgeMs
    $human = ($ea -gt 0) -and ($eb -gt 0) -and ($eb -gt ($ea + [Math]::Max(2, $gap * 0.6)))
    if ($human) { $physEv++ }
    $dx = $q.cx - $p.cx; $dy = $q.cy - $p.cy
    $dd = [Math]::Sqrt([double]($dx * $dx + $dy * $dy))
    if ($dd -gt $maxMove) { $maxMove = $dd }
    if ((-not $human) -and $dd -gt 0.5) { $unexplained += $dd }
    if ($q.fg -ne $p.fg) { $fgCh++ }
    if ($q.focus -ne $p.focus) { $foCh++ }
  }
  $perAction += [pscustomobject]@{
    round = $a.round; action = $a.action; target = $a.target; op = $a.op; outcome = $a.outcome
    durationMs = $a.durationMs; samples = $idx.Count
    cursorMaxDeltaPx = [math]::Round($maxMove, 1)
    cursorUnexplainedPx = [math]::Round($unexplained, 1)
    physicalInputEvents = $physEv
    fgChanges = $fgCh; focusChanges = $foCh
    focusMoved = $a.focusMoved; focusTakenOntoTarget = $a.focusTakenOntoTarget
    focusBefore = $a.focusBefore; focusAfter = $a.focusAfter
    why = $a.why
  }
}

# Rates by channel. The control row is the noise floor: a write channel only counts as a
# focus-stealer if it exceeds what pure reading produced.
$byChannel = @()
foreach ($g in ($perAction | Group-Object action)) {
  $n = $g.Count
  $okN = @($g.Group | Where-Object { $_.outcome -eq 'ok' }).Count
  $took = @($g.Group | Where-Object { $_.focusTakenOntoTarget }).Count
  $moved = @($g.Group | Where-Object { $_.focusMoved }).Count
  $maxCursor = 0; $maxUnexplained = 0
  foreach ($x in $g.Group) {
    if ($x.cursorMaxDeltaPx -gt $maxCursor) { $maxCursor = $x.cursorMaxDeltaPx }
    if ($x.cursorUnexplainedPx -gt $maxUnexplained) { $maxUnexplained = $x.cursorUnexplainedPx }
  }
  $byChannel += [pscustomobject]@{
    action = $g.Name; n = $n
    okRatePct = [math]::Round(100 * $okN / $n, 1)
    focusMovedPct = [math]::Round(100 * $moved / $n, 1)
    focusTakenPct = [math]::Round(100 * $took / $n, 1)
    cursorMaxDeltaPx = $maxCursor
    cursorUnexplainedMaxPx = $maxUnexplained
  }
}

$control = @($perAction | Where-Object { $_.action -eq 'read-enumerate' })
$controlMovedPct = if ($control.Count) { [math]::Round(100 * @($control | Where-Object { $_.focusMoved }).Count / $control.Count, 1) } else { 'n/a' }
$writes = @($perAction | Where-Object { $_.op -in 'write', 'click' })
$writeStealPct = if ($writes.Count) { [math]::Round(100 * @($writes | Where-Object { $_.focusTakenOntoTarget }).Count / $writes.Count, 1) } else { 'n/a' }

# The verdict shape the plan asks for: which channels reach which generation, and at what
# cost to R2.3. Computed here so the number and its interpretation come from one place.
$byGen = @()
foreach ($g in ($perAction | Group-Object target)) {
  # Measure-Object -Property cannot read these rows: they are ordered hashtables, not
  # PSCustomObjects, so the maximum is computed explicitly.
  $mu = 0
  foreach ($x in $g.Group) { if ($x.cursorUnexplainedPx -gt $mu) { $mu = $x.cursorUnexplainedPx } }
  $byGen += [pscustomobject]@{
    target = $g.Name
    n = $g.Count
    okByChannel = @(foreach ($c in ($g.Group | Group-Object action)) { @{ action = $c.Name; ok = @($c.Group | Where-Object { $_.outcome -eq 'ok' }).Count; n = $c.Count } })
    focusTakenByChannel = @(foreach ($c in ($g.Group | Group-Object action)) { @{ action = $c.Name; took = @($c.Group | Where-Object { $_.focusTakenOntoTarget }).Count; n = $c.Count } })
    cursorUnexplainedMaxPx = $mu
  }
}

[pscustomobject]@{
  generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  rounds = $Rounds
  targets = @($targets | ForEach-Object { @{ id = $_.id; generation = $_.generation; hwnd = $_.hwnd.ToInt64().ToString() } })
  samplerFile = $recordFile; actionsFile = $actionsFile
  samplerStoppedCleanly = $done
  samplesTotal = $samples.Count
  controlFocusMovedPct = $controlMovedPct
  writeFocusTakenPct = $writeStealPct
  byChannel = $byChannel
  byTarget = $byGen
  actions = $perAction
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $OutDir "neutrality-$stamp.json") -Encoding UTF8

# ---------------------------------------------------------------------------------
# close only what we opened
foreach ($m in $made) {
  if ($m.file) { try { Set-Content -LiteralPath $m.file -Value 'exit' -Force } catch { } }
}
Start-Sleep -Milliseconds 800
foreach ($m in $made) {
  if ($m.kind -eq 'process') {
    try {
      $pp = Get-Process -Id $m.id -ErrorAction SilentlyContinue
      if ($pp) {
        if ($pp.MainWindowHandle -ne 0) { [N]::CloseWindow([IntPtr]$pp.MainWindowHandle) }
        Start-Sleep -Milliseconds 200
        if (Get-Process -Id $m.id -EA SilentlyContinue) { Stop-Process -Id $m.id -Force -ErrorAction SilentlyContinue }
      }
    } catch { }
  }
}
# Chromium and Calculator windows: close the window we created, never their processes --
# both are shared by windows the user already had open.
foreach ($t in $targets) {
  if ($t.id -in 'chromium', 'winui-calc') {
    try { if ([N]::IsWindow($t.hwnd)) { [N]::CloseWindow($t.hwnd); Start-Sleep -Milliseconds 250 } } catch { }
  }
}

Write-Output "SUMMARYFILE=$((Join-Path $OutDir "neutrality-$stamp.json"))"
Write-Output "controlFocusMovedPct=$controlMovedPct writeFocusTakenPct=$writeStealPct rounds=$Rounds targets=$(($targets | ForEach-Object { $_.id }) -join ',')"
