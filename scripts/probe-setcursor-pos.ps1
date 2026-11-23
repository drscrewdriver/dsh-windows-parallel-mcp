# probe-setcursor-pos.ps1 -- P0 probe for R3: does SetCursorPos read back exactly, and does it
# work when the foreground window belongs to a higher-integrity process?
#
# Read-modify-restore only. The cursor is put back where it was found before the script exits, and the
# three read-backs are printed as JSON so the findings table can quote a measured value.
#
# Why this probe exists: spec.md §G1/G2. "The cursor is moved deliberately and restored" is a promise
# that needs (a) the read-back to equal the request at this desktop's 150% scale, and (b) the failure
# mode on an elevated foreground to be a MEASURED fact rather than a guess about UIPI.
Set-StrictMode -Version 2.0

if (-not ('WpmCursorProbe' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WpmCursorProbe {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    public static int[] Read() {
        POINT p; if (!GetCursorPos(out p)) return null;
        return new int[] { p.X, p.Y };
    }
    public static string FgInfo() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return "|0|";
        var sb = new System.Text.StringBuilder(256); GetClassNameW(h, sb, 256);
        var tb = new System.Text.StringBuilder(256); GetWindowTextW(h, tb, 256);
        uint pid; GetWindowThreadProcessId(h, out pid);
        return sb.ToString() + "|" + pid + "|" + tb.ToString();
    }
}
'@
}

function J([hashtable]$o) { return ($o | ConvertTo-Json -Compress -Depth 5) }

$start = [WpmCursorProbe]::Read()
if (-not $start) { Write-Output (J @{ ok = $false; reason = 'GetCursorPos failed' }); exit 1 }
$sx = $start[0]; $sy = $start[1]

$reqX = $sx + 40; $reqY = $sy + 20
$moved = [WpmCursorProbe]::SetCursorPos($reqX, $reqY)
Start-Sleep -Milliseconds 120
$after = [WpmCursorProbe]::Read()

$back = [WpmCursorProbe]::SetCursorPos($sx, $sy)
Start-Sleep -Milliseconds 120
$final = [WpmCursorProbe]::Read()

# --- the elevated-foreground arm ---------------------------------------------------------------
# Honest about what it can arrange: if Task Manager is not already foreground, this probe reports
# that it could not put an elevated window in front rather than claiming a result it never measured.
$fgBefore = [WpmCursorProbe]::FgInfo()
$startedTmg = $null
$elevatedArm = @{ attempted = $false; foregroundClass = ($fgBefore.Split('|')[0]); measured = 'n/a' }
if ($fgBefore.Split('|')[0] -ne 'TaskManagerWindow') {
    $existing = @(Get-Process -Name Taskmgr -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 0) {
        try { $startedTmg = Start-Process taskmgr -PassThru; Start-Sleep -Milliseconds 1500 } catch { $startedTmg = $null }
    }
    $fgNow = [WpmCursorProbe]::FgInfo()
    if ($fgNow.Split('|')[0] -eq 'TaskManagerWindow') {
        $elevatedArm.foregroundClass = 'TaskManagerWindow'
    }
}
# Only run the arm when an elevated window really is the foreground; otherwise say so.
$fg2 = [WpmCursorProbe]::FgInfo()
if ($fg2.Split('|')[0] -eq 'TaskManagerWindow') {
    $p0 = [WpmCursorProbe]::Read()
    $okSet = [WpmCursorProbe]::SetCursorPos($p0[0] + 40, $p0[1] + 20)
    Start-Sleep -Milliseconds 120
    $p1 = [WpmCursorProbe]::Read()
    [void][WpmCursorProbe]::SetCursorPos($p0[0], $p0[1])
    $elevatedArm.attempted = $true
    $elevatedArm.setReturned = $okSet
    $elevatedArm.dx = ($p1[0] - $p0[0])
    $elevatedArm.dy = ($p1[1] - $p0[1])
    $elevatedArm.measured = if ($elevatedArm.dx -eq 40 -and $elevatedArm.dy -eq 20) { 'works' } else { 'refused-silently-or-limited' }
}
# Never leave a Task Manager we started running.
if ($startedTmg) { try { Stop-Process -Id $startedTmg.Id -Force -ErrorAction SilentlyContinue } catch { } }

# --- DPI / virtualisation facts ----------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
$dpiScale = 1.0
try {
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $dpiScale = [Math]::Round(($g.DpiX / 96.0), 3)
    $g.Dispose()
} catch { }

Write-Output (J @{
    ok = $true
    startX = $sx; startY = $sy
    requestX = $reqX; requestY = $reqY
    movedCallReturned = [bool]$moved
    readBackX = $after[0]; readBackY = $after[1]
    deltaX = ($after[0] - $reqX); deltaY = ($after[1] - $reqY)
    exactReadBack = ($after[0] -eq $reqX -and $after[1] -eq $reqY)
    restoreCallReturned = [bool]$back
    finalX = $final[0]; finalY = $final[1]
    restoredToStart = ($final[0] -eq $sx -and $final[1] -eq $sy)
    dpiScale = $dpiScale
    foregroundBefore = $fgBefore
    elevatedArm = $elevatedArm
})
