# probe-sendinput-unicode.ps1 -- P0 probe for R3: does SendInput + KEYEVENTF_UNICODE actually
# deliver characters, and does the delivery really go to the FOREGROUND window (S1's premise)?
#
# SAFETY RULES THIS PROBE ENFORCES ON ITSELF, because a keyboard injector pointed at the owner's desktop
# is the most dangerous primitive in this repo:
#   * both targets are windows THIS PROCESS created; nothing is sent to any other application;
#   * the text is a fixed ASCII+Chinese marker, so a stray delivery is recognisable;
#   * the window is closed and the process exits in a finally block regardless of the arm's outcome.
#
# Arm A: our window is foreground -> the text must land in its textbox.
# Arm B: our SECOND window is foreground -> the first textbox must NOT receive the text (which is the
#        measured form of "SendInput writes to the foreground, not to the target you believe").
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('WpmInjectProbe' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WpmInjectProbe {
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; public int pad1; public int pad2; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int cbSize);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);

    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_UNICODE = 0x0004;
    const uint KEYEVENTF_KEYUP = 0x0002;

    public static int SendText(string text) {
        int queued = 0;
        foreach (char c in text) {
            INPUT[] down = new INPUT[1];
            down[0].type = INPUT_KEYBOARD;
            down[0].ki.wVk = 0;
            down[0].ki.wScan = (ushort)c;
            down[0].ki.dwFlags = KEYEVENTF_UNICODE;
            uint r1 = SendInput(1, down, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
            INPUT[] up = new INPUT[1];
            up[0].type = INPUT_KEYBOARD;
            up[0].ki.wVk = 0;
            up[0].ki.wScan = (ushort)c;
            up[0].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            uint r2 = SendInput(1, up, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
            queued += (int)(r1 + r2);
        }
        return queued;
    }
}
'@
}

$mkForm = {
    param([string]$Title, [int]$Top)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.Width = 520; $f.Height = 160
    $f.Left = 120; $f.Top = $Top
    $f.StartPosition = 'Manual'
    $f.TopMost = $true
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.Dock = 'Fill'
    $tb.Text = ''
    [void]$f.Controls.Add($tb)
    $f.Show()
    [void][WpmInjectProbe]::ShowWindow($f.Handle, 5)
    [void][WpmInjectProbe]::SetForegroundWindow($f.Handle)
    Start-Sleep -Milliseconds 350
    return @{ form = $f; box = $tb }
}

$marker = 'wpm-sendinput-probe-测试abc'
$result = @{ ok = $true; marker = $marker; armA = @{}; armB = @{} }
$f1 = $null; $f2 = $null
try {
    $a = & $mkForm 'wpm-probe-A' 140
    $f1 = $a.form
    [void]$f1.Text  # touch to keep strict mode happy
    $fg = [WpmInjectProbe]::GetForegroundWindow()
    $result.armA.foregroundIsA = ($fg -eq $f1.Handle)
    $queued = [WpmInjectProbe]::SendText($marker)
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.Application]::DoEvents()
    $result.armA.charsLanded = $a.box.Text
    $result.armA.length = $a.box.Text.Length
    $result.armA.queuedEvents = $queued
    $result.armA.pass = ($a.box.Text -eq $marker)

    $b = & $mkForm 'wpm-probe-B' 340
    $f2 = $b.form
    $a.box.Text = ''
    [void][WpmInjectProbe]::SetForegroundWindow($f2.Handle)
    Start-Sleep -Milliseconds 300
    $fg2 = [WpmInjectProbe]::GetForegroundWindow()
    $result.armB.foregroundIsB = ($fg2 -eq $f2.Handle)
    $queued2 = [WpmInjectProbe]::SendText($marker)
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.Application]::DoEvents()
    $result.armB.landedInA = $a.box.Text
    $result.armB.landedInB = $b.box.Text
    $result.armB.queuedEvents = $queued2
    $result.armB.pass = ($a.box.Text -eq '' -and $b.box.Text -eq $marker)
} catch {
    $result.ok = $false
    $result.reason = $_.Exception.Message
} finally {
    foreach ($f in @($f1, $f2)) { if ($f) { try { $f.Close() } catch { } } }
}
$result | ConvertTo-Json -Compress -Depth 6
exit 0
