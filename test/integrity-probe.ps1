# integrity-probe.ps1 -- measure the new elevated_target wiring on every live window.
#
# WHAT MAKES THIS A TEST AND NOT A SMOKE RUN. The check has three ways to be wrong and each one
# produces a DIFFERENT user-visible failure:
#   * too eager: a normal window reads elevated -> the engine refuses windows it can drive (this is
#     the failure mode the old unwired comment was afraid of);
#   * too blind: an elevated window reads normal -> the engine acts, nothing happens, and the
#     result says 'reported-by-send', which is a lie with a green tick;
#   * unstable: the same pid reads differently between calls -> refusals become non-reproducible.
# So this prints the raw RID for every drivable window, checks our own process reads medium,
# re-reads a sample for stability, and reports whether ANY window on this desktop reads high.
# If none does, the high side is simply not observable right now and says so -- an absent arm is
# declared, not silently passed.
param([int]$StabilityRounds = 3)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# engine.ps1 dot-sources both halves: the probe needs win.ps1 (WpmWin, Get-WpmFacts) AND
# decide.ps1 (New-WpmFacts, Get-WpmChannelDecision) for the high-arm decision line.
. (Join-Path $PSScriptRoot '..\src\engine\engine.ps1')

$names = @{ 0x1000 = 'low'; 0x2000 = 'medium'; 0x3000 = 'high'; 0x4000 = 'system' }
function Rid-Name($rid) { if ($rid -lt 0) { 'unknown' } elseif ($names.ContainsKey($rid)) { $names[$rid] } else { "rid=0x$($rid.ToString('X'))" } }

$mine = [WpmWin]::IntegrityOf([uint32]$PID)
"self (pid=$PID): $(Rid-Name $mine)"
if ($mine -ne 0x2000) { "  NOTE: this session is NOT medium integrity -- the comparison baseline moves with it" }

$acc = @()
$cb = [WpmWin+EnumProc] {
  param([IntPtr]$h, [IntPtr]$l)
  if (-not [WpmWin]::IsWindowVisible($h)) { return $true }
  $t = [WpmWin]::Txt($h)
  if (-not $t) { return $true }
  $p = [WpmWin]::PidOf($h)
  $script:WpmAcc += [pscustomobject]@{ hwnd = $h.ToInt64(); title = $t; pid = $p; rid = [WpmWin]::IntegrityOf($p) }
  return $true
}
$script:WpmAcc = @()
[void][WpmWin]::EnumWindows($cb, [IntPtr]::Zero)
$list = $script:WpmAcc

'--- integrity per live titled window ---'
$byName = $list | Group-Object { Rid-Name $_.rid } | Sort-Object Count -Descending
foreach ($g in $byName) { "  {0,-10} x{1}" -f $g.Name, $g.Count }
$high = @($list | Where-Object { $_.rid -eq 0x3000 })
$sys = @($list | Where-Object { $_.rid -eq 0x4000 })
$unknown = @($list | Where-Object { $_.rid -lt 0 })

'--- the three wrongness arms ---'
# 1. too eager: does any NORMAL window read above ours?
$ours = $mine
$above = @($list | Where-Object { $_.rid -gt $ours })
if ($above.Count -eq 0) { "  PASS  no window reads above ours (nothing refused that we could drive)" }
else {
  "  OBSERVE $($above.Count) window(s) read above ours:"
  foreach ($w in $above) { "    $($w.hwnd) '$($w.title.Substring(0,[Math]::Min(40,$w.title.Length)))' pid=$($w.pid) $(Rid-Name $w.rid)" }
}
# 2. IsElevatedTarget agrees with the raw comparison on every window
$disagree = 0
foreach ($w in $list) {
  $flag = [WpmWin]::IsElevatedTarget($w.pid)
  $expect = ($w.rid -gt $ours -and $w.rid -ge 0 -and $ours -ge 0)
  if ($flag -ne $expect) { $disagree++ }
}
if ($disagree -eq 0) { "  PASS  IsElevatedTarget agrees with raw RID comparison on all $($list.Count) windows" }
else { "  FAIL  $disagree window(s) disagree between flag and raw comparison" }
# 3. stability: same pid, same answer every round
$sample = @($list | Group-Object pid | ForEach-Object { $_.Group[0] } | Select-Object -First 12)
$flips = 0
for ($r = 0; $r -lt $StabilityRounds; $r++) {
  foreach ($w in $sample) {
    if ([WpmWin]::IntegrityOf($w.pid) -ne $w.rid) { $flips++ }
  }
}
if ($flips -eq 0) { "  PASS  integrity stable across $StabilityRounds rounds x $($sample.Count) pids" }
else { "  FAIL  $flips unstable reads" }

'--- the high arm ---'
if ($high.Count -gt 0) {
  "  OBSERVABLE: $($high.Count) elevated window(s) right now:"
  foreach ($w in $high) { "    $($w.hwnd) '$($w.title.Substring(0,[Math]::Min(40,$w.title.Length)))' pid=$($w.pid)" }
  $probe = Get-WpmFacts -Hwnd ([IntPtr]$high[0].hwnd) -Action click
  "  Get-WpmFacts on it: elevatedTarget=$($probe.facts.elevatedTarget) door=$($probe.facts.messageDoor) pattern=$($probe.facts.patternKind)"
  $dec = Get-WpmChannelDecision $probe.facts
  "  decision: channel=$($dec.channel) refusal='$($dec.refusal)'"
} else {
  "  NOT-OBSERVABLE: no high-integrity window exists on this desktop right now."
  "  The refusal path is unit-tested in the table (decide-test) and the CHECK is measured above;"
  "  the end-to-end refusal needs one elevated window to exist -- owner opens an admin terminal."
}
if ($unknown.Count -gt 0) { "  (unknown reads: $($unknown.Count) -- degraded handle reads, treated as NOT elevated)" }
