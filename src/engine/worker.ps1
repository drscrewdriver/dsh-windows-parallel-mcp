# worker.ps1 -- the sidecar's line protocol: one JSON request in, one JSON response out.
#
# WHY A WORKER AND NOT A DIRECT CALL. Two constraints collide in this process model:
#   * UIA COM wants a single-threaded apartment (powershell.exe -STA), and
#   * the caller is a Node event loop that cannot block on a synchronous P/Invoke round trip
#     without stalling the host's own tool loop.
# A long-lived STA process speaking one-line-request/one-line-response satisfies both. The same
# shape was measured to work in the sibling competitor (Node registers tools, PS sidecar speaks JSON
# lines) and TS-1 in findings.md chose it for that reason -- not for elegance.
#
# THE PROTOCOL IS THE PRODUCT'S UNDERPINNING, so it is deliberately boring and total:
#   request   {"id":"<string>","action":"windows|click|type|focus|status", ...args}
#   response  {"id":"<string>","ok":true,"result":{...}}
#             {"id":"<string>","ok":false,"error":"<message>","code":"<refusal-or-empty>"}
#
# THREE RULES THAT COST A RUN EACH IF BROKEN:
#   1. NOTHING ELSE MAY TOUCH STDOUT. Add-Type, assembly loads and any stray Write-Output would
#      interleave with the protocol lines and the reader would parse rubbish. Every call whose
#      output is not the response is assigned to $null, and the response is written through
#      [Console]::Out directly so a redirected pipeline cannot swallow or pad it.
#   2. A BAD REQUEST MUST STILL GET AN ANSWER. A null id is a bug on the caller's side; answering
#      with an error keeps the caller's request map from leaking a permanently-pending entry.
#   3. STDOUT/STDIN ARE UTF-8. This host's ANSI codepage is GBK, and window titles plus typed text
#      are routinely non-ASCII: without this, Chinese text arrives as mojibake and every title match
#      silently fails -- the same class as the BOM-less .ps1 incident recorded in check-ps-bom.mjs.
#
# Exit is driven by stdin closing: the parent owns the lifetime, so the worker never decides to stop
# on its own (an idle-exit would race the next request).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$ProgressPreference = 'SilentlyContinue'

$EngineRoot = $PSScriptRoot
. (Join-Path $EngineRoot 'engine.ps1')

function Write-Response([string]$Id, $Payload) {
  # Two-step because ConvertTo-Json is the only reliable serializer here, and because a response
  # that fails to serialize must still produce a protocol line rather than a silent stall.
  try {
    $line = $Payload | ConvertTo-Json -Depth 8 -Compress
  } catch {
    $line = '{"id":' + (ConvertTo-Json $Id -Compress) + ',"ok":false,"error":"response serialization failed: ' + ($_.Exception.Message -replace '"', "'") + '","code":""}'
  }
  [Console]::Out.WriteLine($line)
  [Console]::Out.Flush()
}

function Get-Arg($Bag, [string]$Name, $Default = $null) {
  if ($null -eq $Bag) { return $Default }
  if (-not ($Bag.PSObject.Properties.Name -contains $Name)) { return $Default }
  $v = $Bag.$Name
  if ($null -eq $v) { return $Default }
  return $v
}

# Announced once, on stderr, so the Node half can tell "the engine loaded" from "the process is up
# but the engine is not". It is a diagnostic only: no protocol line is written before a request.
[Console]::Error.WriteLine('wpm-worker ready engine=' + $EngineRoot)

while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }            # parent closed stdin: orderly shutdown
  if ($line.Trim() -eq '') { continue }

  $req = $null
  try { $req = $line | ConvertFrom-Json } catch {
    Write-Response '' @{ id = ''; ok = $false; error = 'request is not valid JSON: ' + $_.Exception.Message; code = '' }
    continue
  }

  $id = [string](Get-Arg $req 'id' '')
  $action = [string](Get-Arg $req 'action' '')

  try {
    switch ($action) {
      'windows' {
        $list = @(Get-WpmWindowList)
        Write-Response $id @{ id = $id; ok = $true; result = @{ windows = $list; count = $list.Count } }
      }
      'status' {
        $st = Get-WpmStatus
        Write-Response $id @{ id = $id; ok = $true; result = $st }
      }
      'overlay' {
        # Product surface (task_54): the marker + Ctrl+Alt+Q. `on` starts/stops the overlay thread;
        # `x`/`y` move the marker to the point the engine just acted on (the Node half calls this
        # after a successful action; the marker auto-hides).
        . (Join-Path $EngineRoot 'overlay.ps1')
        $on = [bool](Get-Arg $req 'on' $true)
        if ($on) {
          $r = Start-WpmOverlay
          # Cold-start allowance: the overlay runspace JITs PresentationFramework on first use.
          # Measured: the hwnd can stay absent past 2.5s on a cold worker and the caller then reads
          # 'overlay reported not running' -- a false failure of a surface that comes up a beat later.
          $st = Get-WpmOverlayState -WaitMs 6000
        } else {
          $r = Stop-WpmOverlay
          $st = $r.state
        }
        $mx = [int](Get-Arg $req 'x' -1)
        $my = [int](Get-Arg $req 'y' -1)
        if ($on -and $mx -ge 0 -and $my -ge 0) { [void](Set-WpmOverlayMarker -X $mx -Y $my) }
        Write-Response $id @{ id = $id; ok = $true; result = @{ start = $r; state = $st } }
      }
      'marker' {
        . (Join-Path $EngineRoot 'overlay.ps1')
        $mx = [int](Get-Arg $req 'x' -1)
        $my = [int](Get-Arg $req 'y' -1)
        $hide = [bool](Get-Arg $req 'hide' $false)
        $r = Set-WpmOverlayMarker -X $mx -Y $my -Hide:$hide
        Write-Response $id @{ id = $id; ok = $true; result = $r }
      }
      'pause' {
        # Owner control. Kept in the worker rather than in Node so the pause flag lives in exactly
        # one process: two copies would let a model bypass the pause by reaching whichever copy
        # forgot it.
        $on = [bool](Get-Arg $req 'on' $true)
        Set-WpmPaused $on 'owner'
        Write-Response $id @{ id = $id; ok = $true; result = @{ paused = $on } }
      }
      'click' {
        $r = Invoke-WpmAction -Hwnd ([string](Get-Arg $req 'hwnd' '')) -Action click `
          -X ([int](Get-Arg $req 'x' -1)) -Y ([int](Get-Arg $req 'y' -1)) `
          -SettleMs ([int](Get-Arg $req 'settleMs' 350))
        Write-Response $id @{ id = $id; ok = $true; result = $r }
      }
      'type' {
        $r = Invoke-WpmAction -Hwnd ([string](Get-Arg $req 'hwnd' '')) -Action type `
          -Text ([string](Get-Arg $req 'text' '')) -ElementName ([string](Get-Arg $req 'elementName' '')) `
          -Replace:([bool](Get-Arg $req 'replace' $false)) -SettleMs ([int](Get-Arg $req 'settleMs' 350))
        Write-Response $id @{ id = $id; ok = $true; result = $r }
      }
      'focus' {
        $r = Invoke-WpmAction -Hwnd ([string](Get-Arg $req 'hwnd' '')) -Action focus `
          -ElementName ([string](Get-Arg $req 'elementName' '')) -SettleMs ([int](Get-Arg $req 'settleMs' 350))
        Write-Response $id @{ id = $id; ok = $true; result = $r }
      }
      'ping' {
        # `text` is echoed back verbatim. That is not decoration: the protocol's encoding is a real
        # failure surface on this host (ANSI codepage GBK), and an echo is the only way to prove a
        # non-ASCII string survives Node -> stdin -> PowerShell -> stdout -> Node unchanged. The tool
        # surface deliberately does not expose this action.
        $echo = [string](Get-Arg $req 'text' '')
        Write-Response $id @{ id = $id; ok = $true; result = @{ pong = $true; pid = $PID; text = $echo; len = $echo.Length } }
      }
      default {
        Write-Response $id @{ id = $id; ok = $false; error = "unknown action '$action'"; code = '' }
      }
    }
  } catch {
    # The action threw. The engine's own refusals are returned as ok=$true results carrying
    # `refusal`; reaching here means something outside the decision table broke, so it is reported
    # as an error with the exception text rather than folded into a refusal code it does not own.
    Write-Response $id @{ id = $id; ok = $false; error = $_.Exception.Message; code = '' }
  }
}
