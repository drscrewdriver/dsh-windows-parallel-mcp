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
          # The handshake now waits for the SAME flag the verdict reports (OverlayOn, not the hwnd)
          # and says 'starting' when the budget merely expired -- so it can stay short and honest.
          # Patience above a genuinely slow start lives in the Node half's placement retry loop,
          # where a stop condition exists; a worker-side sleep cannot name one.
          $st = Get-WpmOverlayState -WaitMs 2500
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
        # R3: takeover/keyInput travel as explicit request fields. The HOST half is what enforces the
        # settings gates (lib/index.js) and strips these fields when a gate is off, so a request that
        # arrives here with takeover=true was already authorised; the engine still re-checks the HUD.
        $r = Invoke-WpmAction -Hwnd ([string](Get-Arg $req 'hwnd' '')) -Action click `
          -X ([int](Get-Arg $req 'x' -1)) -Y ([int](Get-Arg $req 'y' -1)) `
          -SettleMs ([int](Get-Arg $req 'settleMs' 350)) `
          -Space ([string](Get-Arg $req 'space' 'screen')) `
          -ShotId ([string](Get-Arg $req 'shotId' '')) `
          -Label ([int](Get-Arg $req 'label' 0)) `
          -SnapId ([string](Get-Arg $req 'snapId' '')) `
          -Takeover:([bool](Get-Arg $req 'takeover' $false)) `
          -TakeoverMaxMs ([int](Get-Arg $req 'takeoverMaxMs' 10000)) `
          -KeyInject:([bool](([string](Get-Arg $req 'keyInput' 'none')) -eq 'inject')) `
          -TakeoverArmMs ([int](Get-Arg $req 'takeoverArmMs' 800)) `
          -HudDoneMs ([int](Get-Arg $req 'hudDoneMs' 1500))
        Write-Response $id @{ id = $id; ok = $true; result = $r }
      }
      'type' {
        $r = Invoke-WpmAction -Hwnd ([string](Get-Arg $req 'hwnd' '')) -Action type `
          -Text ([string](Get-Arg $req 'text' '')) -ElementName ([string](Get-Arg $req 'elementName' '')) `
          -Label ([int](Get-Arg $req 'label' 0)) `
          -SnapId ([string](Get-Arg $req 'snapId' '')) `
          -Replace:([bool](Get-Arg $req 'replace' $false)) -SettleMs ([int](Get-Arg $req 'settleMs' 350)) `
          -Takeover:([bool](Get-Arg $req 'takeover' $false)) `
          -TakeoverMaxMs ([int](Get-Arg $req 'takeoverMaxMs' 10000)) `
          -KeyInject:([bool](([string](Get-Arg $req 'keyInput' 'none')) -eq 'inject')) `
          -TakeoverArmMs ([int](Get-Arg $req 'takeoverArmMs' 800)) `
          -HudDoneMs ([int](Get-Arg $req 'hudDoneMs' 1500))
        Write-Response $id @{ id = $id; ok = $true; result = $r }
      }
      'focus' {
        $r = Invoke-WpmAction -Hwnd ([string](Get-Arg $req 'hwnd' '')) -Action focus `
          -ElementName ([string](Get-Arg $req 'elementName' '')) `
          -Label ([int](Get-Arg $req 'label' 0)) `
          -SnapId ([string](Get-Arg $req 'snapId' '')) `
          -SettleMs ([int](Get-Arg $req 'settleMs' 350)) `
          -Takeover:([bool](Get-Arg $req 'takeover' $false)) `
          -TakeoverMaxMs ([int](Get-Arg $req 'takeoverMaxMs' 10000))
        Write-Response $id @{ id = $id; ok = $true; result = $r }
      }
      'snapshot' {
        # Read path (0.5.0). The cap comes from the host settings (snapshotMaxElements), which sends it
        # as maxElements; interactableOnly defaults ON because the whole point of the frame is to be
        # small enough for a decision, not to be an exhaustive dump.
        $r = Invoke-WpmAction -Hwnd ([string](Get-Arg $req 'hwnd' '')) -Action snapshot `
          -MaxElements ([int](Get-Arg $req 'maxElements' 300)) `
          -InteractableOnly ([bool](Get-Arg $req 'interactableOnly' $true)) `
          -SinceSnapId ([string](Get-Arg $req 'sinceSnapId' '')) `
          -Intent ([string](Get-Arg $req 'intent' ''))
        Write-Response $id @{ id = $id; ok = $true; result = $r }
      }
      'screenshot' {
        $r = Invoke-WpmAction -Hwnd ([string](Get-Arg $req 'hwnd' '')) -Action screenshot `
          -FullScreen ([bool](Get-Arg $req 'fullScreen' $false)) `
          -MaxWidth ([int](Get-Arg $req 'maxWidth' 0)) `
          -ShotsKeep ([int](Get-Arg $req 'shotsKeep' 10))
        Write-Response $id @{ id = $id; ok = $true; result = $r }
      }
      'preview' {
        # Silent by construction: the marker is a click-through request and nothing is serialised into
        # any input queue. No proof window is produced -- there is no action to prove.
        $r = Invoke-WpmAction -Hwnd ([string](Get-Arg $req 'hwnd' '')) -Action preview `
          -X ([int](Get-Arg $req 'x' -1)) -Y ([int](Get-Arg $req 'y' -1))
        Write-Response $id @{ id = $id; ok = $true; result = $r }
      }
      'hud' {
        # Product surface for tests and for the owner: start/stop the HUD on its own, so its window
        # properties can be measured without an action in flight (test/hud-test.ps1).
        . (Join-Path $EngineRoot 'hud.ps1')
        $on = [bool](Get-Arg $req 'on' $true)
        if ($on) {
          $r = Start-WpmHud -Action ([string](Get-Arg $req 'action' 'hud')) -MaxMs ([int](Get-Arg $req 'maxMs' 10000)) -ArmMs ([int](Get-Arg $req 'armMs' 0))
          $st = if ($r.state) { $r.state } else { Get-WpmHudState -WaitMs 100 }
        } else {
          $r = Stop-WpmHud
          $st = $r.state
        }
        Write-Response $id @{ id = $id; ok = $true; result = @{ hud = $st } }
      }
      'takeover' {
        # Alias of 'hud' on purpose: the HUD IS the takeover precondition, so "takeover on" and "hud on"
        # are the same operation. Reported separately from the settings gate, which lives in the host.
        . (Join-Path $EngineRoot 'hud.ps1')
        $on = [bool](Get-Arg $req 'on' $true)
        if ($on) {
          $r = Start-WpmHud -Action 'takeover' -MaxMs ([int](Get-Arg $req 'maxMs' 10000)) -ArmMs 0
          $st = if ($r.state) { $r.state } else { Get-WpmHudState -WaitMs 100 }
        } else {
          $r = Stop-WpmHud
          $st = $r.state
        }
        Write-Response $id @{ id = $id; ok = $true; result = @{ hud = $st; stance = 'takeover requires the host setting takeoverAllowed; the HUD is the hard precondition' } }
      }
      'abort' {
        # IMMEDIATE ANSWER, and it must not wait for anything. This is the host's signal -> worker path;
        # the FILE latch is the path the engine actually polls, so both are written here and the answer
        # goes out before any cleanup work could delay it.
        . (Join-Path $EngineRoot 'takeover.ps1')
        [WpmCtl]::TakeoverAbort = $true
        $latch = Get-WpmTakeoverLatchPath
        $written = $false
        try {
          $dir = Split-Path -Parent $latch
          if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
          Set-Content -LiteralPath $latch -Value 'abort' -Encoding ASCII -ErrorAction Stop
          $written = $true
        } catch { }
        Write-Response $id @{ id = $id; ok = $true; result = @{ aborted = $true; latch = $latch; latchWritten = $written; flagSet = [bool][WpmCtl]::TakeoverAbort } }
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
