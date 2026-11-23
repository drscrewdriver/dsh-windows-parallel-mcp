# refusals-test.ps1 -- every documented refusal code, driven to the point where it actually fires.
#
# WHY THE CASES LIVE IN THE SCHEMA. src/schema/tools.json declares one executable case per code, and
# this script iterates that array rather than carrying its own list. A test with its own copy of the
# cases drifts from the contract the moment one of them is added, and the drift is invisible: the
# suite stays green while the documented path is untested. Here, deleting a case from the schema
# deletes it from the run, and scripts/check-refusals.mjs fails if any code loses its case.
#
# WHAT "PASS" MEANS. The engine returned the exact documented code -- not a generic failure, not a
# different code that happens to end in the same place. A code that fires on the wrong condition is
# worse than a missing one, because the caller branches on it.
#
# WHAT "NOT-COVERED" MEANS. The case needs a condition this run cannot construct honestly (a real
# elevated window; a channel that reliably throws). Those are printed as NOT-COVERED and are counted
# separately: folding them into PASS would be the "empty arm speaks" failure this repo keeps hitting.
#
# Cleanup: the WinForms target is closed through its own exit file, then any surviving window whose
# title belongs to this run is closed, and the survivor count is printed. Runs in well under a minute.
param(
  [int]$WaitMs = 20000
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\src\engine\engine.ps1')
# NOTE: find-window.ps1 is a SCRIPT, not a library -- dot-sourcing it runs its body and throws for a
# missing parameter. It is invoked as a child process, exactly as g0prime.ps1 does.

$root = Split-Path -Parent $PSScriptRoot
$schemaPath = Join-Path $root 'src\schema\tools.json'
$schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json

function Find-TargetHwnd([string]$titlePart) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    (Join-Path $root 'scripts\find-window.ps1') -TitlePart $titlePart 2>$null
  $ErrorActionPreference = $prev
  if (-not $out) { return $null }
  try { return (($out | Select-Object -Last 1) | ConvertFrom-Json) } catch { return $null }
}

function Get-CaseArg([object]$bag, [string]$name) {
  if ($null -eq $bag) { return $null }
  if (-not ($bag.PSObject.Properties.Name -contains $name)) { return $null }
  return $bag.$name
}

# ---- context: three bindings the cases refer to ---------------------------------------------
$ctx = @{
  deadHwnd     = '1'                                       # not a window; IsWindow() is false
  liveHwnd     = ''
  winformsHwnd = ''
  missingName  = 'wpmNoSuchControl_2047'                   # deliberately absent from the target
}

$targetTitle = 'WpmRefusalTarget'
$exitF = Join-Path $env:TEMP ('wpm-refusal-' + [guid]::NewGuid().ToString('N') + '.stop')
$proc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', (Join-Path $root 'scripts\winforms-target.ps1'), '-HoldMs', '180000',
  '-ExitFile', "`"$exitF`"", '-Title', $targetTitle -PassThru

$t = $null
for ($i = 0; $i -lt [int]($WaitMs / 400) -and -not $t; $i++) { Start-Sleep -Milliseconds 400; $t = Find-TargetHwnd $targetTitle }
if (-not $t) {
  # No target means the WinForms cases cannot run. Say which ones degraded instead of reporting a
  # clean run over an empty arm.
  throw "winforms target '$targetTitle' never appeared -- the WinForms refusal cases cannot be measured"
}
$ctx.winformsHwnd = [string]$t.hwnd
"target: title='$targetTitle' hwnd=$($ctx.winformsHwnd) process=$($t.process)"

# A live window that is NOT the target, for the cases that only need "some window exists": the
# pause branch must be reachable without borrowing the target's specific shape.
$list = @(Get-WpmWindowList)
$other = $list | Where-Object { $_.hwnd -ne $ctx.winformsHwnd } | Select-Object -First 1
$ctx.liveHwnd = if ($other) { [string]$other.hwnd } else { $ctx.winformsHwnd }
"live binding: hwnd=$($ctx.liveHwnd) title='$(if ($other) { $other.title } else { '<target only>' })'"
''

function Resolve-Binding([string]$v) {
  if ($v -and $v.StartsWith('$')) {
    $key = $v.Substring(1)
    if (-not $ctx.ContainsKey($key)) { throw "unbound placeholder '$v' -- check-refusals.mjs should have caught this" }
    return [string]$ctx[$key]
  }
  return $v
}

function New-CaseFacts([object]$factsSpec) {
  # Facts are built through the typed constructor, so a misspelled or missing field raises instead
  # of becoming a $null that compares false and lands in the quiet branch.
  $names = @{
    hwnd = 'Hwnd'; paused = 'Paused'; elevatedTarget = 'ElevatedTarget'; family = 'Family'
    messageDoor = 'MessageDoor'; hasPattern = 'HasPattern'; patternKind = 'PatternKind'
    action = 'Action'; factsMeasured = 'FactsMeasured'
    uiaTreeEmpty = 'UiaTreeEmpty'; uiaProbeFailed = 'UiaProbeFailed'
    # R3's takeover facts were added to the CONSTRUCTOR and to tools.json's decision cases but not to
    # this map, so the three takeover/keyinject decision cases threw 'unknown facts field' instead of
    # running -- a runner bug that made three documented refusals unexercised while the schema said
    # otherwise. Found on 2026-11-23 by running the suite at HEAD, where it was already red.
    takeoverRequested = 'TakeoverRequested'; keyInjectRequested = 'KeyInjectRequested'
    keyInjectAllowed = 'KeyInjectAllowed'; hudReady = 'HudReady'; foregroundIsTarget = 'ForegroundIsTarget'
  }
  $splat = @{}
  foreach ($k in $factsSpec.PSObject.Properties.Name) {
    if (-not $names.ContainsKey($k)) { throw "refusal case uses an unknown facts field '$k'" }
    $val = $factsSpec.$k
    if ($val -is [string]) { $val = Resolve-Binding $val }
    $splat[$names[$k]] = $val
  }
  $splat['FactsMeasured'] = $true
  if (-not $splat.ContainsKey('Hwnd')) { $splat['Hwnd'] = [string]$ctx.liveHwnd }
  return New-WpmFacts @splat
}

function Invoke-Case([object]$case) {
  $tool = $case.tool
  # Not `$case.args`: a decision-mode case has no args at all, and under StrictMode reading a
  # missing property throws -- which is exactly what happened on the first run of this file.
  $ca = Get-CaseArg $case 'args'
  switch ($case.mode) {
    'decision' {
      if (-not ($case.PSObject.Properties.Name -contains 'facts') -or $null -eq $case.facts) {
        return (Get-WpmChannelDecision $null)
      }
      return (Get-WpmChannelDecision (New-CaseFacts $case.facts))
    }
    'engine' {
      $hwnd = Resolve-Binding ([string](Get-CaseArg $ca 'hwnd'))
      $paused = (Get-CaseArg $case 'setup') -eq 'pause'
      try {
        if ($paused) { Set-WpmPaused $true 'refusals-test' }
        $common = @{ Hwnd = $hwnd }
        if ($tool -eq 'wpm_click') {
          # `space`/`shotId`/`label`/`snapId` travel into the engine since 0.5.0: the stale_ref case is
          # exactly "space:'image' with a shotId that was never issued", so the runner has to forward it
          # or the case would test a different call than the one the schema documents. An absent space
          # must be 'screen' rather than '': [ValidateSet] REJECTS an empty string, which would have
          # turned every non-image click case into a binding error instead of a refusal.
          $sp = [string](Get-CaseArg $ca 'space')
          if (-not $sp) { $sp = 'screen' }
          $r = Invoke-WpmAction @common -Action click -X ([int](Get-CaseArg $ca 'x')) -Y ([int](Get-CaseArg $ca 'y')) `
            -Space $sp -ShotId ([string](Get-CaseArg $ca 'shotId')) `
            -Label ([int](Get-CaseArg $ca 'label')) -SnapId ([string](Get-CaseArg $ca 'snapId'))
        } elseif ($tool -eq 'wpm_type') {
          $r = Invoke-WpmAction @common -Action type -Text ([string](Get-CaseArg $ca 'text')) -ElementName ([string](Get-CaseArg $ca 'elementName')) `
            -Label ([int](Get-CaseArg $ca 'label')) -SnapId ([string](Get-CaseArg $ca 'snapId'))
        } elseif ($tool -eq 'wpm_focus') {
          $r = Invoke-WpmAction @common -Action focus -ElementName ([string](Get-CaseArg $ca 'elementName')) `
            -Label ([int](Get-CaseArg $ca 'label')) -SnapId ([string](Get-CaseArg $ca 'snapId'))
        } elseif ($tool -eq 'wpm_snapshot') {
          $r = Invoke-WpmAction @common -Action snapshot
        } elseif ($tool -eq 'wpm_screenshot') {
          $r = Invoke-WpmAction @common -Action screenshot -FullScreen ([bool](Get-CaseArg $ca 'fullScreen'))
        } elseif ($tool -eq 'wpm_preview') {
          $r = Invoke-WpmAction @common -Action preview -X ([int](Get-CaseArg $ca 'x')) -Y ([int](Get-CaseArg $ca 'y'))
        } elseif ($tool -eq 'wpm_status') {
          $r = Invoke-WpmAction @common -Action status
        } else {
          throw "case '$($case.id)' names tool '$tool' but this runner has no mapping for it"
        }
        return $r
      } finally {
        if ($paused) { Set-WpmPaused $false }
      }
    }
    default { return $null }
  }
}

# ---- run every case the schema declares ----------------------------------------------------
$script:pass = 0
$script:fail = 0
$script:uncovered = 0
$coveredCodes = @()
$failures = @()

'--- refusal cases (source: src/schema/tools.json refusalCases) ---'
foreach ($case in $schema.refusalCases) {
  $id = [string]$case.id
  $mode = [string]$case.mode
  $expect = [string]$case.expect
  if ($mode -eq 'none') {
    $script:uncovered++
    "  NOT-COVERED  $id :: expect=$expect -- $($case.note)"
    continue
  }
  $got = ''
  try {
    $res = Invoke-Case $case
    if ($null -eq $res) { $got = '<null result>' } else { $got = [string]$res.refusal }
  } catch {
    $got = '<threw: ' + $_.Exception.Message + '>'
  }
  if ($got -eq $expect) {
    $script:pass++
    $coveredCodes += $expect
    "  PASS  $id [$mode] expect=$expect got=$got"
  } else {
    $script:fail++
    $failures += $id
    "  FAIL  $id [$mode] expect=$expect got='$got' -- $($case.note)"
  }
}

# ---- engine: a query must stay a query --------------------------------------------------------
# Reading the branch order while writing the cases above showed that 'status' used to fall through
# to the UIA branch and INVOKE the pattern it found. This pins the fix: the call reports the query
# detail and takes no focus. (The pre-fix behaviour was found by reading, not by a failing run --
# say so rather than implying this assertion caught it.)
''
'--- engine: status is a query, not an action ---'
# Two properties, both from the schema: wpm_status declares no refusals (so it must answer for any
# target, including one that no action could use), and it must stay answerable while paused,
# because that is exactly when the owner asks 'what is it doing'.
$stA = Invoke-WpmAction -Hwnd ([string]$ctx.deadHwnd) -Action status
if ($stA.ok -and $stA.detail -eq 'status: query only, no action taken' -and $stA.focusTaken -eq 'false') {
  $script:pass++
  "  PASS  status-answers-for-a-dead-hwnd :: ok=$($stA.ok) fg=$($stA.foreground) focusTaken=$($stA.focusTaken)"
} else {
  $script:fail++
  $failures += 'status-answers-for-a-dead-hwnd'
  "  FAIL  status-answers-for-a-dead-hwnd :: ok=$($stA.ok) refusal='$($stA.refusal)' detail='$($stA.detail)'"
}
Set-WpmPaused $true 'refusals-test'
$stB = Invoke-WpmAction -Hwnd ([string]$ctx.liveHwnd) -Action status
Set-WpmPaused $false
if ($stB.ok -and $stB.paused -eq $true -and $stB.detail -eq 'status: query only, no action taken') {
  $script:pass++
  "  PASS  status-answers-while-paused :: paused=$($stB.paused) lastInputAgeMs=$($stB.lastInputAgeMs)"
} else {
  $script:fail++
  $failures += 'status-answers-while-paused'
  "  FAIL  status-answers-while-paused :: ok=$($stB.ok) paused=$($stB.paused) refusal='$($stB.refusal)'"
}

# ---- the coverage claim itself ---------------------------------------------------------------
# A green run over a subset is the failure mode this file exists to prevent, so the union of the
# executed expectations is compared against the declared code set.
$declared = @($schema.refusals | ForEach-Object { [string]$_.code })
# A code the contract already declares uncovered (with a reason) is not a silent gap: the difference
# between 'we know this is unmeasured' and 'nobody noticed' is the whole point of the two counts.
$declaredUncovered = @($schema.refusals | Where-Object { $_.PSObject.Properties.Name -contains 'uncoveredReason' } | ForEach-Object { [string]$_.code })
$missing = @($declared | Where-Object { $coveredCodes -notcontains $_ -and $declaredUncovered -notcontains $_ })

''
"codes declared: $($declared.Count); codes exercised: $(($coveredCodes | Sort-Object -Unique).Count); not-covered cases: $script:uncovered"
if ($declaredUncovered.Count) { "  declared uncovered (reason in tools.json): $($declaredUncovered -join ', ')" }
if ($missing.Count) {
  $script:fail++
  "  FAIL  declared code(s) with no executed case and no stated reason: $($missing -join ', ')"
}

# ---- cleanup --------------------------------------------------------------------------------
Set-WpmPaused $false
if ($proc -and -not $proc.HasExited) {
  Set-Content -LiteralPath $exitF -Value 'stop' -Encoding ascii
  for ($i = 0; $i -lt 25 -and -not $proc.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
  if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
}
Remove-Item -LiteralPath $exitF -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# Leftovers are counted, not assumed away: a run that leaks a window leaves the desktop in a state
# the next experiment inherits, and this repo has already paid for that once.
$left = @(Get-WpmWindowList | Where-Object { $_.title -like ($targetTitle + '*') })
if ($left.Count) {
  foreach ($w in $left) { [void][WpmWin]::PostMessageW([IntPtr][int64]$w.hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
  Start-Sleep -Milliseconds 500
  $left = @(Get-WpmWindowList | Where-Object { $_.title -like ($targetTitle + '*') })
}
"leftover sweep: $($left.Count) window(s) of this run still present"

''
"refusals-test: $script:pass passed, $script:fail failed, $script:uncovered not covered"
if ($script:fail -gt 0) {
  "failed cases: $($failures -join ', ')"
  exit 1
}
exit 0
