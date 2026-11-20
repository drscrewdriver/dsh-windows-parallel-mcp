# probe-hit.ps1 -- who actually owns a SCREEN POINT, in the same coordinate space the engine uses.
#
# Desktop arms that assert "the point under test belongs to window X" need this because a third-party
# window (a video player that went full-screen while the suite was written, for example) can sit on
# the point and make WindowFromPoint return IT. That is not the product failing and not the test's
# base window winning -- the arm's premise ("this point is ours to test") simply does not hold right
# now, and the honest outcome is SKIP with the occluder named, not a FAIL that blames the plugin.
# win.ps1 declares DPI awareness at load, so the probe and the engine see the same coordinate space.
param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\engine\win.ps1')
$pt = New-Object 'WpmWin+POINT' -Property @{ X = $X; Y = $Y }
$hit = [WpmWin]::WindowFromPoint($pt)
$root = if ($hit -ne [IntPtr]::Zero) { [WpmWin]::Root($hit) } else { [IntPtr]::Zero }
[ordered]@{
  x = $X; y = $Y
  hit = [int64]$hit
  root = [int64]$root
  rootTitle = $(if ($root -ne [IntPtr]::Zero) { [WpmWin]::Txt($root) } else { '' })
  rootCls = $(if ($root -ne [IntPtr]::Zero) { [WpmWin]::Cls($root) } else { '' })
  rootPid = $(if ($root -ne [IntPtr]::Zero) { [int][WpmWin]::PidOf($root) } else { 0 })
} | ConvertTo-Json -Compress
