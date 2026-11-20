# hotkey-availability.ps1 -- which global chords are actually free on THIS desktop.
# Why: overlay.ps1 registers Ctrl+Alt+Q and, on this machine, RegisterHotKey returns false -- some
# other app owns it. "The document says Ctrl+Alt+Q" is not a feature if the key is taken, so the
# candidates are measured rather than assumed. Registers each chord on a throwaway hidden window,
# reports free/taken, and unregisters everything before exiting.
param([string]$Candidates = '')
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HkProbe {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr CreateWindowExW(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool DestroyWindow(IntPtr h);
}
'@
$MOD_ALT = 0x0001; $MOD_CONTROL = 0x0002; $MOD_SHIFT = 0x0004; $MOD_WIN = 0x0008

# label -> (mods, vk)
$list = @(
  @{ label = 'Ctrl+Alt+Q';   mods = ($MOD_CONTROL -bor $MOD_ALT);   vk = 0x51 },
  @{ label = 'Ctrl+Alt+W';   mods = ($MOD_CONTROL -bor $MOD_ALT);   vk = 0x57 },
  @{ label = 'Ctrl+Alt+P';   mods = ($MOD_CONTROL -bor $MOD_ALT);   vk = 0x50 },
  @{ label = 'Ctrl+Alt+Space'; mods = ($MOD_CONTROL -bor $MOD_ALT); vk = 0x20 },
  @{ label = 'Ctrl+Shift+Q'; mods = ($MOD_CONTROL -bor $MOD_SHIFT); vk = 0x51 },
  @{ label = 'Ctrl+Shift+F12'; mods = ($MOD_CONTROL -bor $MOD_SHIFT); vk = 0x7B },
  @{ label = 'Ctrl+Alt+Shift+Q'; mods = ($MOD_CONTROL -bor $MOD_ALT -bor $MOD_SHIFT); vk = 0x51 },
  @{ label = 'Win+Alt+Q';    mods = ($MOD_WIN -bor $MOD_ALT);       vk = 0x51 }
)
if ($Candidates) { }
# hWnd = NULL registers against THIS THREAD's message queue: enough to learn whether the chord is
# already owned, and it needs no window class at all (CreateWindowExW with a predefined class
# failed here with 1407 -- the probe does not need a window to answer this question).
$hwnd = [IntPtr]::Zero
$id = 1
$rows = @()
try {
  foreach ($c in $list) {
    $ok = [HkProbe]::RegisterHotKey($hwnd, $id, [uint32]$c.mods, [uint32]$c.vk)
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $rows += [pscustomobject]@{ chord = $c.label; free = $ok; win32 = $err }
    if ($ok) { [void][HkProbe]::UnregisterHotKey($hwnd, $id) }
    $id++
  }
} finally { }
$rows | ForEach-Object { "{0,-16} {1}  win32={2}" -f $_.chord, $(if ($_.free) { 'FREE' } else { 'TAKEN' }), $_.win32 }
$freeCount = ($rows | Where-Object { $_.free }).Count
""
"hotkey-availability: $freeCount/$($rows.Count) free"
if ($freeCount -eq 0) { exit 1 }
exit 0
