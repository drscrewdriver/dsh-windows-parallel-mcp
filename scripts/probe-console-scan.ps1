# probe-console-scan.ps1 -- why did Unicode injection not reach the terminal? (findings §G3, second arm)
#
# The first arm measured: SetCursorPos/foreground/HUD aside, KEYEVENTF_UNICODE events were accepted by
# SendInput (242 events) and the terminal did not execute the typed command. This arm tests the competing
# hypothesis -- that the console input stack wants SCAN CODES, not VK_PACKET -- by typing the same command
# with KEYEVENTF_SCANCODE + the layout's own virtual-key mapping.
#
# If this works, the shipped path becomes "scan codes for the terminal family, Unicode for GUI targets",
# and the limitation of each is written down. If it also fails, the conclusion is that this host's
# terminal cannot be driven by synthetic keys at all, and the terminal claim has to be withdrawn.
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/engine/engine.ps1')

if (-not ('WpmScanProbe' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WpmScanProbe {
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; public int pad0; public int pad1; }
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] i, int cb);
    [DllImport("user32.dll")] public static extern short VkKeyScan(char c);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);

    const uint KEYBOARD = 1, UP = 0x0002, SCANCODE = 0x0008;
    const ushort SHIFT = 0x10;

    static INPUT K(ushort vk, ushort scan, uint flags) {
        INPUT i = new INPUT(); i.type = KEYBOARD; i.ki.wVk = vk; i.ki.wScan = scan; i.ki.dwFlags = flags; return i;
    }
    // One character as a real keystroke: the layout maps the character to a VK, the VK to a scan code,
    // and shift is held when the layout says the character needs it.
    public static int TypeChar(char c) {
        short vkScan = VkKeyScan(c);
        if (vkScan == -1) return 0;
        ushort vk = (ushort)(vkScan & 0xFF);
        bool shift = ((vkScan >> 8) & 1) != 0;
        ushort scan = (ushort)MapVirtualKey(vk, 0);
        if (scan == 0) return 0;
        int n = 0; uint sent = 0;
        if (shift) { INPUT[] s = new INPUT[1]; s[0] = K(SHIFT, (ushort)MapVirtualKey(SHIFT, 0), SCANCODE); sent += SendInput(1, s, Marshal.SizeOf(typeof(INPUT))); }
        INPUT[] d = new INPUT[1]; d[0] = K(vk, scan, SCANCODE); sent += SendInput(1, d, Marshal.SizeOf(typeof(INPUT)));
        INPUT[] u = new INPUT[1]; u[0] = K(vk, scan, SCANCODE | UP); sent += SendInput(1, u, Marshal.SizeOf(typeof(INPUT)));
        if (shift) { INPUT[] s2 = new INPUT[1]; s2[0] = K(SHIFT, (ushort)MapVirtualKey(SHIFT, 0), SCANCODE | UP); sent += SendInput(1, s2, Marshal.SizeOf(typeof(INPUT))); }
        n = (int)sent;
        return n;
    }
    public static int TypeText(string t) { int total = 0; foreach (char c in t) { int k = TypeChar(c); if (k == 0) return -1; total += k; } return total; }
}
'@
}

$title = 'wpm-console-scan-probe'
$outFile = Join-Path $env:TEMP ('wpm-scan-proof-' + $PID + '.txt')
Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
$result = @{ ok = $false }
try {
  $proc = Start-Process wt.exe -ArgumentList '-w', 'new', '--title', $title, 'powershell', '-NoProfile', '-NoLogo', '-NoExit' -PassThru
  Start-Sleep -Milliseconds 3000
  $wins = @(Get-WpmWindowList | Where-Object { [string]$_.title -like ('*' + $title + '*') })
  $result.found = $wins.Count
  if ($wins.Count -gt 0) {
    $hwnd = [string]$wins[0].hwnd
    $result.hwnd = $hwnd
    [void][WpmWin]::RestoreForeground([IntPtr][int64]$hwnd)
    Start-Sleep -Milliseconds 400
    $fg = [WpmWin]::Fg()
    $result.foregroundIsTarget = ($fg -eq $hwnd)
    if (-not $result.foregroundIsTarget) {
      $result.reason = 'could not make the probe window foreground; nothing sent'
    } else {
      $cmd = "Set-Content -LiteralPath '" + $outFile + "' -Value 'wpm-ok' -Encoding ascii"
      $result.events = [WpmScanProbe]::TypeText($cmd)
      $result.typedAsciiOnly = ($cmd -match '^[\x20-\x7E]*$')
      Start-Sleep -Milliseconds 150
      # Enter through the same scan-code path.
      $result.enterEvents = [WpmScanProbe]::TypeChar([char]0x000D)
      $deadline = (Get-Date).AddSeconds(8)
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $outFile) {
          $c = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
          if ($c -and $c -match 'wpm-ok') { $result.ok = $true; $result.content = $c.Trim(); break }
        }
      }
      if (-not $result.ok) { $result.reason = 'scan-code typing did not execute either' }
    }
    try { [void][WpmWin]::PostMessageW([IntPtr][int64]$hwnd, [uint32][WpmWin]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) } catch { }
  } else {
    $result.reason = 'no probe window found'
  }
} catch {
  $result.reason = $_.Exception.Message
} finally {
  Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
}
$result | ConvertTo-Json -Compress -Depth 5
exit 0
