# probe-console-inject.ps1 -- does a REAL terminal receive injected characters? (findings §G3)
#
# THE CORE ASSUMPTION OF THE TERMINAL RELAXATION, measured end to end: a dedicated Windows Terminal window
# is created by this probe, brought to the foreground, and a command is typed into it. The proof is not a
# screenshot -- the command writes a file, so "the characters arrived and the shell executed them" is a
# fact about the filesystem.
#
# SAFETY. The window is created BY THIS PROBE, titled so it can be identified, and closed afterwards. The
# owner's own terminals are never targeted: every send is preceded by an assertion that the foreground
# window IS this probe's window, and nothing is sent when that assertion fails.
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/engine/engine.ps1')
. (Join-Path $root 'src/engine/input-inject.ps1')

# Clean up any window a previous failed run of this probe left behind (matched by this probe's title).
foreach ($w in @(Get-WpmWindowList)) {
  if ([string]$w.title -like '*wpm-console-inject-probe*') {
    try { [void][WpmWin]::PostMessageW([IntPtr][int64]$w.hwnd, [uint32][WpmWin]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) } catch { }
  }
}
Start-Sleep -Milliseconds 300

$title = 'wpm-console-inject-probe'
$outFile = Join-Path $env:TEMP ('wpm-console-proof-' + $PID + '.txt')
Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
$result = @{ ok = $false; step = 'start' }

function Find-Titled([string]$t) {
  $acc = @()
  foreach ($w in @(Get-WpmWindowList)) { if ([string]$w.title -like ('*' + $t + '*')) { $acc += $w } }
  return $acc
}

try {
  $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
  if (-not $wt) {
    $result.step = 'wt-missing'
    $result.reason = 'Windows Terminal (wt.exe) is not installed; a console host window could not be created deterministically'
  } else {
    $result.step = 'launch'
    $proc = Start-Process wt.exe -ArgumentList '-w', 'new', '--title', $title, 'powershell', '-NoProfile', '-NoLogo', '-NoExit' -PassThru
    Start-Sleep -Milliseconds 3000
    $wins = @(Find-Titled $title)
    $result.step = 'find-window'
    $result.found = $wins.Count
    if ($wins.Count -eq 0) {
      $result.reason = 'the Terminal window did not appear with the probe title; nothing was sent'
    } else {
      $hwnd = [string]$wins[0].hwnd
      $result.hwnd = $hwnd
      $result.cls = [string]$wins[0].cls
      $result.step = 'foreground'
      $probeHwnd = [IntPtr][int64]$hwnd
      [void][WpmWin]::RestoreForeground($probeHwnd)
      Start-Sleep -Milliseconds 400
      $fg = Test-WpmTargetForeground -Hwnd $hwnd
      $result.foregroundIsTarget = [bool]$fg.ok
      if (-not $fg.ok) {
        $result.reason = 'could not make the probe window the foreground; nothing was sent (' + [string]$fg.reason + ')'
      } else {
        $result.step = 'type'
        $cmd = "Set-Content -LiteralPath '" + $outFile + "' -Value 'wpm-ok' -Encoding ascii"
        $s = Send-WpmKeyText -Text $cmd
        $result.sentEvents = [int]$s.sent
        $result.sentChars = [int]$s.chars
        # Re-assert before pressing Enter: a foreground change between text and submit would send the key
        # into whatever moved in front.
        $fg2 = Test-WpmTargetForeground -Hwnd $hwnd
        $result.foregroundBeforeEnter = [bool]$fg2.ok
        if ($fg2.ok) {
          $k = Send-WpmKeyPress -Key 'enter'
          $result.enterSent = [bool]$k.ok
        } else {
          $result.reason = 'the foreground changed before Enter; the command was NOT submitted'
        }
        $result.step = 'verify'
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline) {
          Start-Sleep -Milliseconds 250
          if (Test-Path -LiteralPath $outFile) {
            $content = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match 'wpm-ok') { $result.ok = $true; $result.content = $content.Trim(); break }
          }
        }
        if (-not $result.ok) { $result.reason = 'the command was typed but the file never appeared (the terminal did not execute it)' }
      }
    }
    # Close the window we created. WM_CLOSE on the terminal window ends the tab we opened.
    if ($result.hwnd) { try { [void][WpmWin]::PostMessageW([IntPtr][int64]$result.hwnd, [uint32][WpmWin]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) } catch { } }
  }
} catch {
  $result.reason = $_.Exception.Message
} finally {
  Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
}
$result | ConvertTo-Json -Compress -Depth 5
exit 0
