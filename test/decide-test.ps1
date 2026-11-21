# decide-test.ps1 -- every branch of the R2' decision tables, asserted without touching a desktop.
#
# WHY THIS EXISTS BEFORE THE ENGINE. The two tables in src/engine/decide.ps1 encode the product's
# safety properties: which targets are driven quietly, which cost a flash, which are refused, and
# when it is legal to take the focus back. A wrong branch here is not a crash -- it is a silent
# behaviour change that acts on the owner's windows. Every branch therefore gets an assertion,
# including the ones that must REFUSE, because a refusal branch that never fires is indistinguishable
# from an absent one until it matters.
#
# Runs in well under a second, no UIA, no P/Invoke, no windows created. Exit code 1 on any failure.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\src\engine\decide.ps1')

$script:pass = 0
$script:fail = 0
function Assert-Case([string]$name, [hashtable]$got, [hashtable]$want) {
  $bad = @()
  foreach ($k in $want.Keys) {
    $g = if ($got.ContainsKey($k)) { $got[$k] } else { '<missing>' }
    if ("$g" -ne "$($want[$k])") { $bad += "$k got='$g' want='$($want[$k])'" }
  }
  if ($bad.Count -eq 0) { $script:pass++; "  PASS  $name" }
  else { $script:fail++; "  FAIL  $name :: $($bad -join '; ')" }
}

'--- channel table ---'

# A classic child window with a message door: the quiet tier, and specifically NOT the UIA tier
# even when a pattern also exists. This asserts the R2.2 -> R2'.2 inversion directly: if the
# preference ever flips back, this case fails.
Assert-Case 'message door wins over an available pattern' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0x1' -Family 'winforms' -MessageDoor $true -HasPattern $true -PatternKind 'invoke' `
  -FactsMeasured $true)) @{ channel = 'message'; tier = 'quiet'; needsRestore = 'False' }

# A WPF target: no child door, has a pattern, so bounded flash and restoration is mandatory.
Assert-Case 'pattern without a door costs a flash and demands restore' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0x2' -Family 'wpf' -MessageDoor $false -HasPattern $true -PatternKind 'value' `
  -FactsMeasured $true)) @{ channel = 'uia'; tier = 'bounded-flash'; needsRestore = 'True' }

# Terminal: its own refusal code, because the fix differs from the generic one.
Assert-Case 'terminal with no door and no pattern is refused by its own code' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0x3' -Family 'terminal' -FactsMeasured $true)) @{ channel = 'refuse'; refusal = 'terminal_no_door' }

# Nothing measured: must refuse, never default into the quiet branch.
Assert-Case 'unmeasured target is refused, not assumed quiet' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0x4' -Family 'uwp' -FactsMeasured $false)) @{ channel = 'refuse'; refusal = 'needs_facts' }

# Measured and genuinely door-less: generic unreachable, distinct from needs_facts.
Assert-Case 'measured door-less target is unreachable' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0x5' -Family 'chromium' -FactsMeasured $true)) @{ channel = 'refuse'; refusal = 'unreachable' }

# The two worlds behind a probe that found nothing. 2026-11-21 census and re-read: a Chromium
# window with renderer accessibility off walks to a tree with ZERO content elements (uTools:
# one Chrome Legacy Window shell Pane, no interactive element, identical across three in-place
# reads), while an a11y-on window walks to hundreds (DSH 514 at census time, 1019 on re-read).
# One code for both worlds made the fix unreadable: tree-empty needs the APP to relaunch with
# a11y on, unreachable needs a different target or point. No retry belongs to either -- the
# empty tree never grows content under re-query, which is measured, not assumed.
Assert-Case 'a tree with no content elements is uia_tree_empty, not unreachable' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0xa' -Family 'chromium' -FactsMeasured $true -UiaTreeEmpty $true)) @{ channel = 'refuse'; refusal = 'uia_tree_empty' }

# A probe that THREW cannot say anything about the tree: an unmeasurable tree is not an empty
# tree, and the exception text rides the reason rather than a generic failure word.
Assert-Case 'a probe that threw is uia_probe_failed, not unreachable' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0xb' -Family 'chromium' -FactsMeasured $true -UiaProbeFailed $true)) @{ channel = 'refuse'; refusal = 'uia_probe_failed' }

# Precedence between the two: a measurement that threw cannot also certify emptiness, so the
# probe failure wins when both flags are somehow set.
Assert-Case 'probe failure outranks tree-empty when both are set' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0xc' -Family 'chromium' -FactsMeasured $true -UiaProbeFailed $true -UiaTreeEmpty $true)) @{ channel = 'refuse'; refusal = 'uia_probe_failed' }

# And a usable door still outranks every diagnosis: these codes only replace the terminal
# refusal, never a working channel.
Assert-Case 'message door outranks a thrown probe' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0xd' -Family 'chromium' -MessageDoor $true -FactsMeasured $true -UiaProbeFailed $true)) @{ channel = 'message'; tier = 'quiet' }

# Ordering: paused must beat a working door. If capability were checked first, this would return
# 'message' and the caller would act while the owner had asked it to stop.
Assert-Case 'pause beats a working message door' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0x6' -MessageDoor $true -Paused $true -FactsMeasured $true)) @{ channel = 'refuse'; refusal = 'paused' }

Assert-Case 'pause beats an available pattern' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0x7' -HasPattern $true -PatternKind 'invoke' -Paused $true -FactsMeasured $true)) `
  @{ channel = 'refuse'; refusal = 'paused' }

Assert-Case 'missing hwnd is refused even with every door present' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '' -MessageDoor $true -HasPattern $true -PatternKind 'invoke' -FactsMeasured $true)) `
  @{ channel = 'refuse'; refusal = 'no_hwnd' }

Assert-Case 'elevated target is refused before any capability check' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0x8' -MessageDoor $true -ElevatedTarget $true -FactsMeasured $true)) `
  @{ channel = 'refuse'; refusal = 'elevated_target' }

Assert-Case 'empty facts refuse rather than throw' (Get-WpmChannelDecision $null) @{ channel = 'refuse'; refusal = 'needs_facts' }

# A pattern that exists but reports kind 'none' is not usable: claiming the flash tier off an
# unusable pattern would promise driveability the engine cannot deliver.
Assert-Case 'pattern flag with no usable kind does not reach the flash tier' (Get-WpmChannelDecision (New-WpmFacts `
  -Hwnd '0x9' -HasPattern $true -PatternKind 'none' -FactsMeasured $true)) `
  @{ channel = 'refuse'; refusal = 'unreachable' }

'--- restore table ---'

Assert-Case 'our own raised window is restored' (Get-WpmRestoreDecision -CurrentFg '77' -RaisedHwnd '77' `
  -TargetPid '100' -CurrentFgPid '100' -RaisedHappened $true) @{ restore = 'True'; outcome = 'restore' }

# The dialog branch. Without it, an action that opens Save would be yanked back and the box left
# unresponsive -- the failure is invisible in logs and obvious to the user.
Assert-Case 'same-pid dialog is left alone' (Get-WpmRestoreDecision -CurrentFg '88' -RaisedHwnd '77' `
  -TargetPid '100' -CurrentFgPid '100' -RaisedHappened $true) @{ restore = 'False'; outcome = 'skip-dialog' }

# A third window: the owner or another app chose it. Never fight.
Assert-Case 'third-party window is never pulled from the owner' (Get-WpmRestoreDecision -CurrentFg '99' -RaisedHwnd '77' `
  -TargetPid '100' -CurrentFgPid '555' -RaisedHappened $true) @{ restore = 'False'; outcome = 'skip-taken' }

Assert-Case 'no raise means nothing to restore' (Get-WpmRestoreDecision -CurrentFg '88' -RaisedHwnd '77' `
  -TargetPid '100' -CurrentFgPid '555' -RaisedHappened $false) @{ restore = 'False'; outcome = 'skip' }

Assert-Case 'one-shot: a second restore is refused' (Get-WpmRestoreDecision -CurrentFg '77' -RaisedHwnd '77' `
  -TargetPid '100' -CurrentFgPid '100' -RaisedHappened $true -AlreadyRestored $true) `
  @{ restore = 'False'; outcome = 'skip' }

''
"decide-test: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
