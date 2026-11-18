# probe-worker.ps1 — raw Win32 input-state sampler for the parallel proof (P0 / task_2).
# Emits one JSONL line per sample (to stdout, and appended to -Out when given).
# Read-only: no SendInput, no SetForegroundWindow, no cursor write. Anything that could
# move or grab something is deliberately absent, because the sampler itself must not
# become the disturbance it measures.
#
# Record: {ts,cx,cy,fg,fgTid,fgPid,focus,focusTid}
#   fg    = GetForegroundWindow()
#   focus = GetGUIThreadInfo(fgThread).hwndFocus  (keyboard focus owner)
param(
  [int]$Hz = 20,          # sampling period in ms
  [int]$DurationMs = 0,   # 0 = until -StopFile appears, stdin closes, or the host is killed
  [string]$StopFile = "",
  [string]$Out = ""
)
$ErrorActionPreference = 'Stop'
# -TypeDefinition (not -MemberDefinition): the latter wraps the body inside a generated
# class, which makes `using` directives and nested types illegal. The sampler gets
# compiled into the worker process at runtime -- system csc, no build step, no install.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Probe {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags;
    public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
    public RECT rcCaret;
  }

  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public int cbSize; public uint dwTime; }

  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, out GUITHREADINFO i);
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  [DllImport("kernel32.dll")] public static extern uint GetTickCount();

  // lastInputMs = ms since the LAST physical input (mouse move/click, key). This is what
  // makes A1 honest: on a live desktop the human is moving the cursor too, so "max delta
  // = 0px" is only attributable to the AI when no physical input happened in that span.
  // Without it, a human twitch invalidates the assertion; with it, a sample window can be
  // partitioned into human-active and AI-only, and only the latter is charged to the agent.
  public static long LastInputAgeMs() {
    LASTINPUTINFO lii = new LASTINPUTINFO();
    lii.cbSize = Marshal.SizeOf(typeof(LASTINPUTINFO));
    if (!GetLastInputInfo(ref lii)) return -1;
    return (long)(GetTickCount() - lii.dwTime);
  }

  public static string Sample(long ts) {
    POINT p; GetCursorPos(out p);
    IntPtr fg = GetForegroundWindow();
    uint pid; uint tid = GetWindowThreadProcessId(fg, out pid);
    IntPtr focus = IntPtr.Zero;
    if (tid != 0) {
      GUITHREADINFO gi = new GUITHREADINFO();
      gi.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
      if (GetGUIThreadInfo(tid, out gi)) focus = gi.hwndFocus;
    }
    return "{\"ts\":" + ts + ",\"cx\":" + p.x + ",\"cy\":" + p.y +
           ",\"fg\":\"" + fg.ToInt64().ToString() + "\"" +
           ",\"fgTid\":" + tid + ",\"fgPid\":" + pid +
           ",\"focus\":\"" + focus.ToInt64().ToString() + "\"" +
           ",\"focusTid\":" + tid +
           ",\"inputAgeMs\":" + LastInputAgeMs() + "}";
  }
}
'@

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$deadline = if ($DurationMs -gt 0) { $sw.ElapsedMilliseconds + $DurationMs } else { [int64]::MaxValue }
$utf8 = New-Object System.Text.UTF8Encoding($false)
# The record goes to -Out only. stdout is intentionally not used: when the parent
# redirects it to NUL (detached/background launch), .NET's console stream is absent and
# a StreamWriter over it throws -- and a sampler that dies at startup reports zero
# motion, which is exactly the false PASS this instrument exists to prevent.
$outStream = if ($Out) {
  New-Object System.IO.StreamWriter([System.IO.File]::Open($Out, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite), $utf8)
} else { (New-Object System.IO.StreamWriter([System.IO.File]::Create(([System.IO.Path]::GetTempFileName())), $utf8)) }

function Emit([string]$line) {
  $outStream.WriteLine($line)
  $outStream.Flush()
}

$next = 0
try {
  while ($sw.ElapsedMilliseconds -lt $deadline) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    try { Emit ([Probe]::Sample($ts)) } catch { Emit ('#err ' + $_.Exception.Message) }
    $next += $Hz
    $sleep = $next - $sw.ElapsedMilliseconds
    if ($sleep -gt 0) { Start-Sleep -Milliseconds ([int]$sleep) } else { $next = $sw.ElapsedMilliseconds }
    if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { break }
  }
} finally {
  $outStream.Flush(); $outStream.Dispose()
  if (-not $Out) { try { [GC]::Collect() } catch {} }
}
