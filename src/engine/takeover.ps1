# takeover.ps1 -- the ONE file allowed to move the real cursor, and the ONE place an interruption is
# read from. (R3, spec.md §1)
#
# WHY THIS IS A SEPARATE MODULE RATHER THAN A FUNCTION IN win.ps1. The product's safety claim is now
# "the cursor moves only when takeover was requested, and is ALWAYS put back". A claim like that is
# only checkable if the primitive is confined: scripts/check-no-cursor-control.mjs plus
# scripts/check-takeover-path.mjs G1 assert that SetCursorPos appears in this file and nowhere else.
# Structural confinement beats a promise in a comment -- the same reasoning the repo already used for
# the original "no injection" gate.
#
# THE THREE FACTS CALLERS NEED, and the honest shape of each:
#   * the position BEFORE the move (so a restore targets a measured point, not "here-ish");
#   * whether the move was actually applied (read-back == request), because a silently refused call
#     must not be reported as a moved cursor;
#   * whether the restore actually landed (read-back == the saved point), because "restored: true" in
#     a log while the pointer sits 40px away is worse than a red verdict.
#
# INTERRUPTION has two channels and both are read here (spec.md §1): the in-process volatile flag
# [WpmCtl]::TakeoverAbort, written by the HUD button / the global chord / the worker's abort command,
# and a latch FILE written by the host half, because the worker is single-threaded and cannot read a
# request while it is inside an action. Volatile is a request; the file is the one that survives a
# wedged notification. Either is sufficient; the flag alone is not treated as the only path.

Set-StrictMode -Version 2.0

if (-not ('WpmCtl' -as [type])) {
  . (Join-Path $PSScriptRoot 'win.ps1')
}

if (-not ('WpmTakeover' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WpmTakeover
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetCursorPos(int x, int y);

    public static int[] Read() {
        POINT p;
        if (!GetCursorPos(out p)) return null;
        return new int[] { p.X, p.Y };
    }
    public static int Apply(int x, int y) {
        if (SetCursorPos(x, y)) return 1;
        return 0;
    }
    public static int LastError() { return Marshal.GetLastWin32Error(); }
}
'@
}

function Get-WpmCursorPos {
  # Read-only. Returns the raw point plus 'ok', because a null from the API must not be read as (0,0).
  $p = [WpmTakeover]::Read()
  if (-not $p) { return @{ ok = $false; x = -1; y = -1; reason = 'GetCursorPos failed' } }
  return @{ ok = $true; x = [int]$p[0]; y = [int]$p[1]; reason = '' }
}

function Set-WpmCursorTakeover {
  # MOVE, THEN READ BACK. The request is remembered separately from the read-back on purpose: a
  # refusal (UIPI on an elevated foreground, for example) shows up as applied=false with the cursor
  # still at 'before', and the caller decides whether that is a refusal or a degraded takeover.
  param([int]$X, [int]$Y)
  $before = Get-WpmCursorPos
  if (-not $before.ok) {
    return @{ ok = $false; applied = $false; requestedX = $X; requestedY = $Y
      beforeX = -1; beforeY = -1; x = -1; y = -1; reason = 'could not read the cursor before moving it' }
  }
  $okSet = ([WpmTakeover]::Apply($X, $Y) -eq 1)
  # A read-back immediately after the call is the measurement; SetCursorPos' own return value is only
  # a hint (it can succeed into a queued move that a later warp overrides).
  Start-Sleep -Milliseconds 20
  $after = Get-WpmCursorPos
  $exact = ($after.ok -and $after.x -eq $X -and $after.y -eq $Y)
  return @{
    ok = [bool]($after.ok)
    applied = [bool]($exact)
    setReturned = [bool]$okSet
    requestedX = $X; requestedY = $Y
    beforeX = [int]$before.x; beforeY = [int]$before.y
    x = [int]$after.x; y = [int]$after.y
    deltaX = [int]($after.x - $X); deltaY = [int]($after.y - $Y)
    reason = if ($exact) { '' } else { 'the cursor did not land on the requested point (win32=' + [WpmTakeover]::LastError() + ')' }
  }
}

function Restore-WpmCursorTakeover {
  # RESTORE IS NOT CONDITIONAL ON THE ACTION HAVING SUCCEEDED. It is also not conditional on the move
  # having been recorded as applied: if the request was issued, the pointer may have been warped by the
  # OS anyway, so the restore is attempted whenever a 'before' point exists. The verdict is the
  # read-back, and a restore that failed is reported as restored=false rather than retried forever
  # (a watchdog here would fight the owner -- the same decision R2'.7 made about focus).
  param([hashtable]$Entry)
  if (-not $Entry -or -not $Entry.ok) {
    return @{ restored = $false; attempted = $false; x = -1; y = -1
      reason = 'no saved cursor position; nothing to restore' }
  }
  $bx = [int]$Entry.beforeX
  $by = [int]$Entry.beforeY
  [void][WpmTakeover]::Apply($bx, $by)
  Start-Sleep -Milliseconds 20
  $now = Get-WpmCursorPos
  $landed = ($now.ok -and $now.x -eq $bx -and $now.y -eq $by)
  return @{
    restored = [bool]$landed
    attempted = $true
    targetX = $bx; targetY = $by
    x = [int]$now.x; y = [int]$now.y
    deltaX = [int]($now.x - $bx); deltaY = [int]($now.y - $by)
    reason = if ($landed) { '' } else { 'the cursor did not return to the saved point (win32=' + [WpmTakeover]::LastError() + ')' }
  }
}

function Get-WpmTakeoverLatchPath {
  # Per-process latch so two workers cannot confuse each other's interruption, and so a stale file from
  # a crashed worker can never abort a live one. The host half writes the same path (lib/index.js).
  param([int]$ProcessId = $PID)
  $base = $env:LOCALAPPDATA
  if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
  return (Join-Path (Join-Path $base 'wpm') ('takeover-abort.' + $ProcessId))
}

function Test-WpmTakeoverAbort {
  param([int]$ProcessId = $PID)
  if ([WpmCtl]::TakeoverAbort) { return $true }
  $latch = Get-WpmTakeoverLatchPath -ProcessId $ProcessId
  if (Test-Path -LiteralPath $latch) { return $true }
  return $false
}

function Reset-WpmTakeoverAbort {
  param([int]$ProcessId = $PID)
  [WpmCtl]::TakeoverAbort = $false
  [WpmCtl]::InjectedChars = 0
  $latch = Get-WpmTakeoverLatchPath -ProcessId $ProcessId
  if (Test-Path -LiteralPath $latch) {
    try { Remove-Item -LiteralPath $latch -Force -ErrorAction Stop } catch { }
  }
  return @{ cleared = $true; latch = $latch; latchExists = (Test-Path -LiteralPath $latch) }
}
