# diag-msgchan-xproc.ps1 — message channels exercised FROM OUTSIDE the target process.
#
# WHY THIS EXISTS, AND WHY THE EARLIER DIAGNOSIS WAS WORTHLESS. diag-msgchan.ps1 ran
# SendMessage inside the process that owned the edit, and both channels worked flawlessly:
# WM_CHAR 'Q' -> 'Q', 'W' -> 'QW', WM_SETTEXT -> 'set-xyz'. On the strength of that the
# channel matrix was declared broken. But the engine under planning is a SEPARATE process
# talking to someone else's window, and cross-process SendMessage differs in three concrete
# ways: the string pointer in lParam must be marshalled by the system, the target thread must
# be pumped, and some messages are simply ignored unless the control owns the caret. A
# positive control that passes in-process and fails in production is worse than no control at
# all -- it certifies the instrument. So the control has to be run from the position the
# product will actually occupy.
param(
  [string]$Title = 'WpmMsgTarget',
  [int]$HoldMs = 60000
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class XMSG {
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr res);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetFocus();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("kernel32.dll")] public static extern uint GetLastError();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EP c, IntPtr l);
  public static string Of(IntPtr h) {
    int n = GetWindowTextLength(h); var sb = new StringBuilder(n + 4);
    GetWindowTextW(h, sb, sb.Capacity); return sb.ToString();
  }
  public static string Cls(IntPtr h) {
    var sb = new StringBuilder(512); GetClassNameW(h, sb, sb.Capacity); return sb.ToString();
  }
  public static List<string> Edits(IntPtr parent) {
    List<string> acc = new List<string>();
    EnumChildWindows(parent, delegate (IntPtr h, IntPtr l) {
      string c = Cls(h);
      if (c.IndexOf("EDIT", StringComparison.OrdinalIgnoreCase) >= 0 ||
          c.IndexOf("RichEdit", StringComparison.OrdinalIgnoreCase) >= 0)
        acc.Add(h.ToInt64() + "\t" + c);
      return true;
    }, IntPtr.Zero);
    return acc;
  }
}
'@

function Find-Win([string]$marker) {
  $o = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot 'find-window.ps1') -TitlePart $marker 2>$null
  if (-not $o) { return $null }
  try { ($o | Select-Object -Last 1) | ConvertFrom-Json } catch { $null }
}

$wfExit = Join-Path $env:TEMP ('wpm-xp-' + [guid]::NewGuid().ToString('N') + '.stop')
# The app-side oracle. Without it the run produced eleven 'EFFECT=False' lines that could
# each have meant one of two opposite things, which is the least useful output an experiment
# can have.
$wfState = Join-Path $env:TEMP ('wpm-xp-state-' + [guid]::NewGuid().ToString('N') + '.txt')
$wfProc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $PSScriptRoot 'winforms-target.ps1'), '-HoldMs', "$HoldMs", '-ExitFile', "`"$wfExit`"",
  '-StateFile', "`"$wfState`"", '-Title', $Title, '-X', '1000', '-Y', '430' -PassThru
$wf = $null
for ($i = 0; $i -lt 50 -and -not $wf; $i++) { Start-Sleep -Milliseconds 400; $wf = Find-Win $Title }
if (-not $wf) { throw 'target never appeared' }
$wfH = [IntPtr]$wf.hwnd
"target frame hwnd=$wfH pid=$($wf.procId)  (this driver pid=$PID)"
$edits = @([XMSG]::Edits($wfH))
foreach ($e in $edits) {
  $h = [IntPtr]([int64](($e -split '\t')[0]))
  "  child hwnd=$h class=$(($e -split '\t')[1]) text(WM_GETTEXT)='$([XMSG]::Of($h))'"
}
function Get-AppState {
  # Tab-separated live control text, written by the owning process every 400ms.
  if (-not (Test-Path -LiteralPath $wfState)) { return @{ ok = $false; edit = ''; rich = '' } }
  $l = (Get-Content -LiteralPath $wfState -Tail 1 -ErrorAction SilentlyContinue | Select-Object -Last 1)
  if (-not $l) { return @{ ok = $false; edit = ''; rich = '' } }
  $p = $l -split "`t"
  return @{ ok = $true; edit = $p[0]; rich = $(if ($p.Count -gt 1) { $p[1] } else { '' }) }
}
$st0 = Get-AppState
"app-side oracle at start: ok=$($st0.ok) edit='$($st0.edit)' rich='$($st0.rich)'"
if (-not $st0.ok) { throw 'app-side state oracle never appeared: this run cannot distinguish a dead channel from a blind measurement' }
# First child is the single-line TextBox; second is the RichTextBox. Testing both, because
# the message door is answered per control class and one conclusion for the toolkit would be
# wrong.
if ($edits.Count -lt 2) { throw 'expected a TextBox and a RichTextBox child' }
$targets = @()
foreach ($e in $edits) {
  $targets += [pscustomobject]@{ name = 'hwnd' + (($e -split '\t')[0]); h = [IntPtr]([int64](($e -split '\t')[0])); cls = (($e -split '\t')[1]) }
}

"foreground now=$([XMSG]::GetForegroundWindow()) (our target is in the background)"
''
$which = 0
foreach ($t in $targets) {
  $which++
  $field = if ($t.cls -like '*RichEdit*') { 'rich' } else { 'edit' }
  "### $($t.cls) hwnd=$($t.h)  (app-side field: $field)"
  $before = [XMSG]::Of($t.h)
  $stA = Get-AppState
  "  start: WM_GETTEXT='$before'  app-side=$($stA.$field)  AGREE=$($before -eq $stA.$field)"

  # A) WM_SETTEXT, local pointer, cross-process. The system marshals this message's lParam for
  #    us, so a failure here is NOT a marshalling story -- and any claim about it must say so.
  $txt = [string]$before + 'Z'
  $ptr = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($txt)
  try {
    $r = [XMSG]::SendMessageW($t.h, 0x000C, [IntPtr]::Zero, $ptr)
    $gl = [XMSG]::GetLastError()
    Start-Sleep -Milliseconds 700
    $a = [XMSG]::Of($t.h); $stB = Get-AppState
    "  SendMessage WM_SETTEXT Z: ret=$r gle=$gl  WM_GETTEXT='$a'  app-side='$($stB.$field)'  EFFECT_gettext=$($a -like '*Z') EFFECT_appside=$($stB.$field -like '*Z')"
  } catch { "  WM_SETTEXT threw: $($_.Exception.Message)" } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }

  # B) WM_CHAR cross-process. A character message without the caret may legitimately be
  #    dropped by the control; reporting that as 'channel dead' would be an error, so the
  #    focus state is printed next to the result and the two are never conflated.
  $r2 = [XMSG]::SendMessageW($t.h, 0x0102, [IntPtr]([int][char]'Q'), [IntPtr]::Zero)
  $gl2 = [XMSG]::GetLastError()
  Start-Sleep -Milliseconds 700
  $b2 = [XMSG]::Of($t.h); $stC = Get-AppState
  "  SendMessage WM_CHAR Q: ret=$r2 gle=$gl2  WM_GETTEXT='$b2'  app-side='$($stC.$field)'  EFFECT_gettext=$($b2 -like '*Q') EFFECT_appside=$($stC.$field -like '*Q')"

  $r3 = [XMSG]::PostMessageW($t.h, 0x0102, [IntPtr]([int][char]'P'), [IntPtr]::Zero)
  Start-Sleep -Milliseconds 900
  $b3 = [XMSG]::Of($t.h); $stD = Get-AppState
  "  PostMessage WM_CHAR P: ret=$r3  WM_GETTEXT='$b3'  app-side='$($stD.$field)'  EFFECT_gettext=$($b3 -like '*P') EFFECT_appside=$($stD.$field -like '*P')"

  # C) SendMessageTimeout, the form the engine would use against a possibly-busy window: it
  #    cannot hang the caller indefinitely, and ret=0 means refusal or timeout, which must be
  #    distinguishable from 'worked'.
  $res = [IntPtr]::Zero
  $sptr = [Runtime.InteropServices.Marshal]::StringToHGlobalUni([string]([XMSG]::Of($t.h)) + 'T')
  try {
    $r4 = [XMSG]::SendMessageTimeoutW($t.h, 0x000C, [IntPtr]::Zero, $sptr, 0x0001, 2000, [ref]$res)
  } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($sptr) }
  Start-Sleep -Milliseconds 700
  $b4 = [XMSG]::Of($t.h); $stE = Get-AppState
  "  SendMessageTimeout WM_SETTEXT T: ret=$r4 res=$res  WM_GETTEXT='$b4'  app-side='$($stE.$field)'  EFFECT_gettext=$($b4 -like '*T') EFFECT_appside=$($stE.$field -like '*T')"

  ''
}
# THE OPEN QUESTION, STATED RATHER THAN FAKED AWAY. If app-side also shows no effect, one
# explanation survives that this instrument cannot exclude: an edit control may decline WM_CHAR
# unless it owns the caret, and giving it the caret would mean activating the window -- the
# very disturbance under measurement. The separation is made below instead of by hand-waving,
# because 'we cannot tell' is only honest once the two branches have been distinguished.

try { Set-Content -LiteralPath $wfExit -Value 'exit' -Force } catch { }
Start-Sleep -Milliseconds 900
try { Stop-Process -Id $wfProc.Id -Force -ErrorAction Stop } catch { }
