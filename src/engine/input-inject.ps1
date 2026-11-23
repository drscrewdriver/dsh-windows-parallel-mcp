# input-inject.ps1 -- the ONE file allowed to call SendInput, and it can only ever construct a
# KEYBOARD event. (R3, spec.md §1)
#
# WHY KEYBOARD IS ALLOWED WHERE MOUSE IS NOT. Measured (findings §B): a terminal's text surface has
# three child HWNDs and none of them accepts WM_CHAR/WM_SETTEXT, so no message door exists; UIA exposes
# no pattern either. Its text can only be typed. A mouse event has an alternative that already exists
# (SetCursorPos shows the point, the message/UIA tier clicks), so mouse injection buys nothing and stays
# banned -- the gate forbids MOUSEEVENTF_* repo-wide, and this file never names it.
#
# THE THREE CONSTRAINTS THAT MATTER MORE THAN THE CAPABILITY (spec.md §1):
#   S1 FOREGROUND IS THE TARGET. SendInput delivers to the current foreground window, not to "the
#      window you meant". Measured with this host's own probe (scripts/probe-sendinput-unicode.ps1):
#      text sent while window B was foreground landed in B and NOT in A, even though A was the target
#      the caller had in mind. So the assertion below is not ceremony -- it is the difference between
#      typing into the terminal and typing into whatever the owner was writing.
#   S2 INTERRUPTIBLE PER CHARACTER. A 500-character payload must not be an uninterruptible burst: the
#      loop checks the caller's abort probe every 8 characters or 50ms and reports how many characters
#      actually went out.
#   S3 NO MOUSE. Only INPUT_KEYBOARD is constructed; there is no code path here that can move a pointer
#      or click (the gate enforces the constants' absence, not the intent).
#
# WHY KEYEVENTF_UNICODE AND NOT SCAN CODES. Unicode mode does not consult the keyboard layout, so it
# works on a DE layout and with Chinese/emoji payloads; scan-code mapping (VkKeyScan) mis-types on
# non-US layouts and dead keys. The price is documented rather than hidden: a Unicode-injected character
# carries no hardware scancode, and the rare target that only reads scancodes (some games, remote KVM)
# will ignore it.

Set-StrictMode -Version 2.0

if (-not ('WpmCtl' -as [type])) {
  . (Join-Path $PSScriptRoot 'win.ps1')
}

if (-not ('WpmInject' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WpmInject
{
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT
    {
        public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT
    {
        public uint type; public KEYBDINPUT ki; public int pad0; public int pad1;
    }

    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int cbSize);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);

    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;

    static INPUT Make(ushort scan, uint flags) {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.ki.wVk = 0;
        i.ki.wScan = scan;
        i.ki.dwFlags = flags;
        i.ki.time = 0;
        i.ki.dwExtraInfo = IntPtr.Zero;
        return i;
    }

    // One character = one down + one up, as a single SendInput call so the pair cannot be separated by
    // another process's input. Returns the number of events the OS accepted (0..2).
    public static uint SendChar(char c) {
        INPUT[] pair = new INPUT[2];
        pair[0] = Make((ushort)c, KEYEVENTF_UNICODE);
        pair[1] = Make((ushort)c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
        return SendInput(2, pair, Marshal.SizeOf(typeof(INPUT)));
    }

    // A named key with optional modifiers -- used where a target needs RETURN/TAB rather than text.
    // The modifiers are held for the duration of the press and released in reverse order.
    public static uint SendCombo(ushort vk, ushort[] mods) {
        int n = 2 * (mods.Length + 1);
        INPUT[] seq = new INPUT[n];
        int k = 0;
        foreach (ushort m in mods) { INPUT i = Make(m, 0); seq[k++] = i; }
        { INPUT d = Make(vk, 0); seq[k++] = d; }
        { INPUT u = Make(vk, KEYEVENTF_KEYUP); seq[k++] = u; }
        for (int j = mods.Length - 1; j >= 0; j--) { INPUT r = Make(mods[j], KEYEVENTF_KEYUP); seq[k++] = r; }
        return SendInput((uint)n, seq, Marshal.SizeOf(typeof(INPUT)));
    }

    public static string ForegroundClass() {
        IntPtr fg = GetForegroundWindow();
        return fg.ToInt64().ToString();
    }
    public static string RootOf(string hwnd) {
        IntPtr h = new IntPtr(long.Parse(hwnd));
        IntPtr root = GetAncestor(h, 2);
        return root.ToInt64().ToString();
    }
}
'@
}

function Test-WpmTargetForeground {
  # S1's assertion. A child of the target counts (the foreground is often the child control), which is
  # why this compares ROOTS rather than exact handles.
  param([string]$Hwnd)
  if (-not $Hwnd) { return @{ ok = $false; foreground = ''; reason = 'no target hwnd' } }
  $fg = [WpmInject]::ForegroundClass()
  if (-not $fg -or $fg -eq '0') { return @{ ok = $false; foreground = ''; reason = 'no foreground window' } }
  $fgRoot = [WpmInject]::RootOf($fg)
  $targetRoot = [WpmInject]::RootOf($Hwnd)
  $match = ($fg -eq $Hwnd) -or ($fgRoot -eq $targetRoot)
  return @{ ok = [bool]$match; foreground = $fg; foregroundRoot = $fgRoot; targetRoot = $targetRoot
    reason = if ($match) { '' } else { 'the foreground window is not the target; sending input would write into the wrong application' } }
}

function Send-WpmKeyText {
  # PER-CHARACTER LOOP, by design (S2). The abort probe is a caller-supplied scriptblock so this file
  # does not need to know where the interruption comes from (HUD button, global chord, host latch).
  param(
    [string]$Text = '',
    [scriptblock]$ShouldAbort = $null,
    [int]$CheckEveryChars = 8,
    [int]$CheckEveryMs = 50
  )
  if (-not $Text) { return @{ ok = $false; sent = 0; chars = 0; aborted = $false; reason = 'empty payload' } }
  $chars = 0
  $events = 0
  $lastCheck = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  for ($i = 0; $i -lt $Text.Length; $i++) {
    if ($ShouldAbort) {
      $dueByCount = ($CheckEveryChars -gt 0) -and (($i % $CheckEveryChars) -eq 0)
      $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $dueByTime = (($nowMs - $lastCheck) -ge $CheckEveryMs)
      if ($i -gt 0 -and ($dueByCount -or $dueByTime)) {
        $lastCheck = $nowMs
        $stop = $false
        try { $stop = [bool](& $ShouldAbort) } catch { $stop = $false }
        if ($stop) {
          return @{ ok = $false; sent = $events; chars = $chars; aborted = $true
            reason = 'interrupted after ' + $chars + ' of ' + $Text.Length + ' characters' }
        }
      }
    }
    $queued = [WpmInject]::SendChar([char]$Text[$i])
    $events += [int]$queued
    $chars += 1
    # Progress is published per character so a caller watching [WpmCtl]::InjectedChars (the HUD does)
    # sees the real count even if the call is later interrupted.
    [WpmCtl]::InjectedChars = $chars
    if ($queued -eq 0) {
      return @{ ok = $false; sent = $events; chars = $chars; aborted = $false
        reason = 'SendInput accepted no events for character ' + $i + ' (a higher-integrity foreground refuses input)' }
    }
    Start-Sleep -Milliseconds 2
  }
  return @{ ok = $true; sent = $events; chars = $chars; aborted = $false; reason = '' }
}

function Send-WpmKeyPress {
  # Single key + modifiers. Kept because "type" is not the only thing an agent needs: confirming a
  # dialog or submitting a form is a RETURN press, and faking it with a text write would be a lie.
  param([string]$Key = 'enter')
  $map = @{
    'enter' = 0x0D; 'return' = 0x0D; 'tab' = 0x09; 'escape' = 0x1B; 'esc' = 0x1B
    'space' = 0x20; 'backspace' = 0x08; 'delete' = 0x2E; 'up' = 0x26; 'down' = 0x28
    'left' = 0x25; 'right' = 0x27; 'home' = 0x24; 'end' = 0x23
  }
  $k = $Key.ToLowerInvariant()
  if (-not $map.ContainsKey($k)) {
    return @{ ok = $false; sent = 0; reason = "unknown key '" + $Key + "'; named keys: " + (($map.Keys | Sort-Object) -join ', ') }
  }
  $queued = [WpmInject]::SendCombo([uint16]$map[$k], [uint16[]]@())
  return @{ ok = [bool]($queued -gt 0); sent = [int]$queued; reason = if ($queued -gt 0) { '' } else { 'SendInput accepted no events' } }
}
