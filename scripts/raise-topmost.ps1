# raise-topmost.ps1 -- test helper: put a window at the top of the TOPMOST band without activating it.
#
# WHY A TEST NEEDS THIS. The desktop arms assert facts about a screen point ("WindowFromPoint at the
# marker returns my base window"; "the click lands on my target's button"). A third-party full-screen
# window -- a video player that went fullscreen while these lines were written -- sits ON that point,
# so WindowFromPoint returns the occluder. When that happens the ENGINE IS RIGHT to refuse: it must
# never act under a window the caller did not name. What actually broke is the arm's PREMISE. Raising
# the test's own window into the topmost band restores the premise through the same mechanism the
# overlay already uses (HWND_TOPMOST + SWP_NOACTIVATE): z-order changes, GetForegroundWindow does not.
#
# This is a scripts/ test helper, deliberately NOT part of the product surface -- there is no reason
# to let a model raise arbitrary windows to topmost, and none exists in tools.json.
param([Parameter(Mandatory)][long]$Hwnd)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\engine\win.ps1')
$ok = [WpmWin]::MakeTopmostNoActivate([IntPtr]$Hwnd)
Write-Output ("raised={0} hwnd={1}" -f $ok, $Hwnd)
exit $(if ($ok) { 0 } else { 1 })
