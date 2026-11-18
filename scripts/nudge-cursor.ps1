# nudge-cursor.ps1 — instrument self-test helper for proof-probe.mjs --move.
# Moves the SYSTEM cursor by a known delta, holds, then restores it. Exists only to
# prove the sampler is not blind: a probe that reports 0px for a 300px nudge measures
# nothing. Not part of the engine, and never used during a proof run.
param(
  [int]$DeltaPx = 300,
  [int]$HoldMs = 1500
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Cur {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  public static void Nudge(int dx, int holdMs) {
    POINT a; GetCursorPos(out a);
    int ox = a.x, oy = a.y;
    SetCursorPos(ox + dx, oy);
    System.Threading.Thread.Sleep(holdMs);
    SetCursorPos(ox, oy);
    Console.WriteLine("{\"from\":[" + ox + "," + oy + "],\"dx\":" + dx + "}");
  }
}
'@
[Cur]::Nudge($DeltaPx, $HoldMs)
