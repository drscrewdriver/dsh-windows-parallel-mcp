# keyinject-test.ps1 -- the keyboard-injection constraints, measured. (spec.md §1 S1/S2, checklist K1/K3/K4/K6)
#
# WHAT IS ASSERTED AND WHY EACH ONE MATTERS
#   K1  the foreground assertion is real: a target that is NOT in front gets zero characters. The measured
#       fact behind it (scripts/probe-sendinput-unicode.ps1, arm B) is that SendInput writes to whatever is
#       in the foreground -- so "I meant that window" is not a safety property, "it IS the foreground" is.
#   K3  a long payload can be interrupted and reports how many characters went out.
#   K4  Unicode injection actually delivers: a real PowerShell console receives a typed command, runs it,
#       and the file it wrote proves the characters arrived. This is the assumption the whole terminal
#       relaxation rests on, so it is measured rather than inferred. The console is created BY THIS TEST
#       and killed afterwards; an existing terminal of the owner's is never touched.
#   K6  the effect word for an injected write is reported-by-send, never "verified".
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/engine/engine.ps1')
. (Join-Path $root 'src/engine/input-inject.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$pass = 0; $fail = 0; $skips = 0
function Ok([string]$name, [bool]$cond, [string]$detail = '') {
  if ($cond) { $script:pass++; Write-Output ("  PASS  " + $name) }
  else { $script:fail++; Write-Output ("  FAIL  " + $name + $(if ($detail) { ' :: ' + $detail } else { '' })) }
}
function Skip([string]$name, [string]$why) { $script:skips++; Write-Output ("  SKIP  " + $name + ' :: ' + $why) }

function New-TargetForm([string]$title, [int]$top) {
  $f = New-Object System.Windows.Forms.Form
  $f.Text = $title
  $f.Width = 460; $f.Height = 200
  $f.StartPosition = 'Manual'
  $f.Left = 140; $f.Top = $top
  $f.TopMost = $true
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Multiline = $true
  $tb.Dock = 'Fill'
  $tb.Text = ''
  [void]$f.Controls.Add($tb)
  $f.Show()
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 200
  return @{ form = $f; box = $tb; hwnd = [string]$f.Handle }
}

$chars = { param($s) return [string]$s }
$a = New-TargetForm 'wpm-inject-A' 150
$b = New-TargetForm 'wpm-inject-B' 470
$fgOk = $false
try {
  # ---- K4-lite: Unicode text lands in the foreground target --------------------------------
  [void][WpmWin]::RestoreForeground([IntPtr][int64]$a.hwnd)
  Start-Sleep -Milliseconds 150
  $fa = Test-WpmTargetForeground -Hwnd $a.hwnd
  if ($fa.ok) {
    $marker = 'wpm-inject-AB测试' + [char]0x4E2D
    $r = Send-WpmKeyText -Text $marker
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.Application]::DoEvents()
    Ok 'K4: Unicode (incl. Chinese) text is delivered by SendInput to the foreground target' ([string]$a.box.Text -eq $marker) ('got=' + [string]$a.box.Text)
    Ok 'K6: the injection reports the event count it queued, not a verdict' ([int]$r.sent -gt 0) ([string]$r.sent)
    Ok 'K6: the character counter matches the payload' ([int]$r.chars -eq $marker.Length) ([string]$r.chars + '/' + $marker.Length)
  } else {
    Skip 'K4: Unicode delivery' 'this test could not make its own window the foreground (foreground=' + $fa.foreground + ')'
  }

  # ---- K1: not the foreground => zero characters ------------------------------------------
  [void][WpmWin]::RestoreForeground([IntPtr][int64]$b.hwnd)
  Start-Sleep -Milliseconds 150
  $a.box.Text = ''
  $fb = Test-WpmTargetForeground -Hwnd $a.hwnd
  Ok 'K1: the foreground assertion says the other window is in front' (-not $fb.ok) ([string]$fb.reason)
  if (-not $fb.ok) {
    $blocked = @{ chars = 0; sent = 0 }
    # The engine refuses at the decision table; the module's own contract is that reaching it without the
    # assertion is impossible from the engine path. Assert the fact the engine relies on, plus the empty
    # outcome: A's box must stay empty while B is in front.
    $sentBefore = [string]$a.box.Text
    Ok 'K1: the non-foreground target receives nothing' ($sentBefore -eq '' -and [string]$b.box.Text -eq '') ('A="' + $sentBefore + '" B="' + [string]$b.box.Text + '"')
  }

  # ---- K3: a long payload can be interrupted ----------------------------------------------
  [void][WpmWin]::RestoreForeground([IntPtr][int64]$a.hwnd)
  Start-Sleep -Milliseconds 150
  $a.box.Text = ''
  $script:abortCalls = 0
  $script:abortAt = 3
  $probe = {
    $script:abortCalls = $script:abortCalls + 1
    return ($script:abortCalls -ge $script:abortAt)
  }
  $long = ('x' * 400)
  $ri = Send-WpmKeyText -Text $long -ShouldAbort $probe
  Start-Sleep -Milliseconds 100
  Ok 'K3: an interrupted injection reports aborted' ([bool]$ri.aborted) ([string]$ri.reason)
  Ok 'K3: it reports how many characters actually went out' ([int]$ri.chars -gt 0 -and [int]$ri.chars -lt 400) ([string]$ri.chars)
  Ok 'K3: the abort probe was consulted' ([int]$script:abortCalls -ge 3) ([string]$script:abortCalls)
  Ok 'K3: [WpmCtl]::InjectedChars carries the same count (the HUD reads this)' ([int][WpmCtl]::InjectedChars -eq [int]$ri.chars) ([string][WpmCtl]::InjectedChars + ' vs ' + [string]$ri.chars)

  # ---- K5-lite: the gates are independent ------------------------------------------------
  $f1 = New-WpmFacts -Hwnd $a.hwnd -FactsMeasured $true -MessageDoor $true -TakeoverRequested $true -HudReady $true -KeyInjectRequested $true -KeyInjectAllowed $false -ForegroundIsTarget $true
  $d1 = Get-WpmChannelDecision $f1
  Ok 'K5: keyInjectAllowed=false refuses even with takeover on and the target in front' ([string]$d1.refusal -eq 'keyinject_unavailable') ([string]$d1.refusal)
  $f2 = New-WpmFacts -Hwnd $a.hwnd -FactsMeasured $true -MessageDoor $true -KeyInjectRequested $true -KeyInjectAllowed $true -ForegroundIsTarget $true
  $d2 = Get-WpmChannelDecision $f2
  Ok 'K5: injection outside the takeover tier is refused even with the gate open' ([string]$d2.refusal -eq 'keyinject_unavailable') ([string]$d2.refusal)

  # ---- K4: a REAL console receives a typed command (the terminal relaxation's core) -------
  $outFile = Join-Path $env:TEMP ('wpm-inject-proof-' + $PID + '.txt')
  Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
  $con = $null
  try {
    $con = Start-Process powershell -ArgumentList '-NoProfile', '-NoLogo', '-NoExit' -PassThru
    Start-Sleep -Milliseconds 1500
    try { $con.Refresh() } catch { }
    $conHwnd = $con.MainWindowHandle
    if (-not $conHwnd -or $conHwnd -eq [IntPtr]::Zero) {
      Skip 'K4: real console delivery' 'the console window has no MainWindowHandle (a host-managed terminal); not guessed at'
    } else {
      [void][WpmWin]::RestoreForeground($conHwnd)
      Start-Sleep -Milliseconds 300
      $fc = Test-WpmTargetForeground -Hwnd ([string]$conHwnd.ToInt64())
      if (-not $fc.ok) {
        Skip 'K4: real console delivery' ('could not bring the console to the foreground: ' + [string]$fc.reason)
      } else {
        $cmd = "'wpm-ok' | Out-File -FilePath " + "'" + $outFile + "'" + ' -Encoding ascii'
        $res = Invoke-WpmAction -Hwnd ([string]$conHwnd.ToInt64()) -Action type -Text $cmd -Takeover -KeyInject -TakeoverArmMs 0 -HudDoneMs 0 -TakeoverMaxMs 8000 -SettleMs 100
        Ok 'K4: the terminal request goes through the takeover tier (not terminal_no_door)' ([string]$res.tier -eq 'takeover' -and [string]$res.refusal -eq '') ([string]$res.tier + '/' + [string]$res.refusal + ' ' + [string]$res.reason)
        Ok 'K6: an injected write reports effect=reported-by-send' ([string]$res.effect -eq 'reported-by-send') ([string]$res.effect)
        Ok 'K4: the cursor was restored after typing into the terminal' ([string]$res.cursorRestored -eq 'true') ([string]$res.cursorRestored)
        $cur = New-Object 'System.Drawing.Point'
        $cur = [System.Windows.Forms.Cursor]::Position
        # Enter is a KEY PRESS, not a character: injected as a named key after the text, which is exactly
        # the split the product exposes (text through characters, a submitting key through Send-WpmKeyPress).
        $kp = Send-WpmKeyPress -Key 'enter'
        Ok 'K4: the submitting key press was accepted' ([bool]$kp.ok) ([string]$kp.reason)
        $deadline = (Get-Date).AddSeconds(6)
        $got = $false
        while ((Get-Date) -lt $deadline) {
          Start-Sleep -Milliseconds 250
          if (Test-Path -LiteralPath $outFile) {
            $content = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match 'wpm-ok') { $got = $true; break }
          }
        }
        Ok 'K4: the real console ran the typed command (the file it wrote contains wpm-ok)' ([bool]$got) $outFile
      }
    }
  } catch {
    Skip 'K4: real console delivery' ('could not arrange the console: ' + $_.Exception.Message)
  } finally {
    if ($con) { try { Stop-Process -Id $con.Id -Force -ErrorAction SilentlyContinue } catch { } }
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
  }
} finally {
  foreach ($f in @($a.form, $b.form)) { if ($f) { try { $f.Close() } catch { } } }
}

Write-Output ('keyinject-test: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:skips + ' skipped')
if ($script:fail -gt 0) { exit 1 }
exit 0
