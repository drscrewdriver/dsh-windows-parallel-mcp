# sampler-hooks.ps1 — dot-sourced helpers that run probe-worker.ps1 around a measured
# window and attribute observed changes to physical input or to the software under test.
#
# WHY A SHARED FILE. Three drivers (reach-matrix, chromium-write-oracle, calc-display-oracle)
# need the identical start/verify/stop/attribute sequence. Duplicated inline it would drift,
# and drifted attribution is worse than no attribution: two scripts would report
# "software-caused changes" computed by subtly different rules under the same name. The
# rules here are the ones the G0 evidence already depends on:
#   * the sampler must be VERIFIED BUSY (>=300 bytes of record) before any injection,
#     because a dead sampler records nothing and nothing reads as perfect neutrality;
#   * stop goes through the worker's `#done` handshake, not a kill, so tail samples survive;
#   * attribution is PER SAMPLE GAP (20Hz): a gap is "human" only when the implied
#     GetLastInputInfo event time advances inside that same gap;
#   * inputAgeMs = -1 means GetLastInputInfo FAILED: that gap is UNKNOWN and goes into
#     neither bucket. Counting unknown as human would launder a software change into an
#     exemption, which is the one error direction this instrument must not have.
# Dot-source it:  . (Join-Path $PSScriptRoot 'sampler-hooks.ps1')

$script:WpmState = Join-Path $env:USERPROFILE '.dsh\windows-parallel-mcp'
$script:WpmProof = Join-Path $script:WpmState 'proof'

function Start-WpmSampler {
  param([int]$Hz = 20, [string]$Tag = 'run')
  if (-not (Test-Path -LiteralPath $script:WpmProof)) { New-Item -ItemType Directory -Path $script:WpmProof -Force | Out-Null }
  $out = Join-Path $script:WpmProof ('probe-' + $Tag + '-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '.jsonl')
  $stop = Join-Path $env:TEMP ('wpm-stop-' + [guid]::NewGuid().ToString('N'))
  if (Test-Path -LiteralPath $stop) { Remove-Item -LiteralPath $stop -Force }
  $proc = Start-Process powershell -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $PSScriptRoot 'probe-worker.ps1'), '-Hz', $Hz, '-DurationMs', '0',
    '-Out', "`"$out`"", '-StopFile', "`"$stop`"" -PassThru -WindowStyle Hidden
  # Verify before trusting: boot bytes >= 300 means the loop is actually writing.
  $warm = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $warm) {
    if ((Test-Path -LiteralPath $out) -and (Get-Item $out).Length -ge 300) { break }
    Start-Sleep -Milliseconds 200
  }
  $bytes = if (Test-Path -LiteralPath $out) { (Get-Item $out).Length } else { 0 }
  return @{ proc = $proc; out = $out; stop = $stop; bootBytes = $bytes; ok = ($bytes -ge 300) }
}

function Stop-WpmSampler {
  param($S, [int]$TimeoutSec = 10)
  Set-Content -LiteralPath $S.stop -Value 'stop' -Force
  $d = (Get-Date).AddSeconds($TimeoutSec)
  $graceful = $false
  while ((Get-Date) -lt $d -and -not $graceful) {
    if ((Get-Content -LiteralPath $S.out -Tail 1 -ErrorAction SilentlyContinue) -match '#done') { $graceful = $true }
    else { Start-Sleep -Milliseconds 150 }
  }
  if (-not $graceful) { try { Stop-Process -Id $S.proc.Id -Force -ErrorAction Stop } catch { } }
  Remove-Item -LiteralPath $S.stop -Force -ErrorAction SilentlyContinue
  $rows = @(Get-Content -LiteralPath $S.out -ErrorAction SilentlyContinue |
    Where-Object { $_ -and $_ -notmatch '^#' } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
  return @{ rows = $rows; graceful = $graceful; file = $S.out }
}

function Get-WpmLastAge {
  # Age of the last PHYSICAL input, read from the sampler's own record tail. Callers must
  # not spawn a second PowerShell to ask GetLastInputInfo directly: launching a process to
  # check whether the desktop is idle is an instrument that disturbs what it measures, and
  # it is also slower than tailing a file the sampler is already writing.
  param([string]$File)
  $line = ''
  try { $line = (Get-Content -LiteralPath $File -Tail 3 -ErrorAction SilentlyContinue |
    Where-Object { $_ -and $_ -notmatch '^\s*#' } | Select-Object -Last 1) } catch { return -1 }
  if (-not $line) { return -1 }
  if ($line -match '"inputAgeMs"\s*:\s*(-?\d+)') { return [int]$Matches[1] }
  return -1
}

function Get-WpmWindowAttribution {
  # Transition-level attribution for one action window [a, b] in unix ms.
  param([object[]]$Samples, [long]$a, [long]$b)
  $in = @($Samples | Where-Object { $_.ts -ge ($a - 100) -and $_.ts -le ($b + 100) } | Sort-Object { [long]$_.ts })
  if ($in.Count -lt 2) {
    return @{ samples = $in.Count; fgSoft = $null; fgHuman = $null; focusSoft = $null; cursorSoftPx = $null; quietFrac = $null }
  }
  $fgSoft = 0; $fgHuman = 0; $fcSoft = 0; $cur = 0.0; $quietMs = 0; $spanMs = 0
  for ($i = 1; $i -lt $in.Count; $i++) {
    $gap = [long]$in[$i].ts - [long]$in[$i - 1].ts
    if ($gap -le 0) { continue }
    $known = ($in[$i - 1].inputAgeMs -ge 0) -and ($in[$i].inputAgeMs -ge 0)
    $human = $false
    if ($known) {
      $ea = [long]$in[$i - 1].ts - [long]$in[$i - 1].inputAgeMs
      $eb = [long]$in[$i].ts - [long]$in[$i].inputAgeMs
      $human = ($eb -gt $ea + 2)
    }
    $spanMs += $gap
    if ($known -and -not $human) { $quietMs += $gap }
    if ($in[$i].fg -ne $in[$i - 1].fg) { if ($human) { $fgHuman++ } elseif ($known) { $fgSoft++ } }
    if ($in[$i].focus -ne $in[$i - 1].focus) { if ($human) { } elseif ($known) { $fcSoft++ } }
    if ($known -and -not $human) {
      $dx = [double]$in[$i].cx - [double]$in[$i - 1].cx
      $dy = [double]$in[$i].cy - [double]$in[$i - 1].cy
      $cur += [Math]::Sqrt($dx * $dx + $dy * $dy)
    }
  }
  $qf = if ($spanMs -gt 0) { [Math]::Round(100.0 * $quietMs / $spanMs, 1) } else { 0 }
  return @{ samples = $in.Count; fgSoft = $fgSoft; fgHuman = $fgHuman; focusSoft = $fcSoft;
            cursorSoftPx = [Math]::Round($cur, 1); quietFrac = $qf }
}
