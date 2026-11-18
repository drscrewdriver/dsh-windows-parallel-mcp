# check-ps-parse.ps1 — run the PowerShell parser over every .ps1 in the repo.
#
# WHY THIS IS A GATE AND NOT A HABIT. Two scripts in this repo were broken by the same
# single character: writing `desktop\'s` inside a single-quoted string. PowerShell escapes a
# single quote by DOUBLING it; a backslash closes nothing, so the string terminates early and
# the parser then reports a missing brace fifty lines away from the actual mistake. Both times
# the error surfaced only when the script was finally executed, which in this repo means after
# a 5-8 minute experiment had already been set up around it.
#
# A syntax check costs about 400ms per file and no experiment setup, so the rule is enforced
# by a command rather than remembered by a person. It uses the real parser
# ([System.Management.Automation.Language.Parser]) and not a heuristic, so it reports exactly
# what powershell.exe would refuse to run -- and nothing it would accept.
param([string[]]$Roots = @('scripts', 'src', 'test', 'worker'))
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Management.Automation

$files = @()
foreach ($r in $Roots) {
  if (-not (Test-Path -LiteralPath $r)) { continue }
  $files += @(Get-ChildItem -LiteralPath $r -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
if (-not $files.Count) { "no .ps1 files under: $($Roots -join ', ')"; exit 0 }

$bad = 0
foreach ($f in $files) {
  $tokens = $null; $errors = $null
  try {
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
  } catch {
    "PARSE-CRASH $f : $($_.Exception.Message)"
    $bad++
    continue
  }
  if ($errors -and $errors.Count) {
    $bad++
    "FAIL $f"
    foreach ($e in @($errors | Select-Object -First 4)) {
      # Offset + the offending extent, not just a message: the message alone sends you to the
      # wrong line, which is the whole reason this check exists.
      $ln = 0
      if ($e.Extent -and $e.Extent.StartScriptPosition) { $ln = $e.Extent.StartScriptPosition.LineNumber }
      $ex = ''
      try { $ex = $e.Extent.Text } catch { }
      if ($ex.Length -gt 60) { $ex = $ex.Substring(0, 60) + '...' }
      "   L$ln  $($e.Message)  |near| $ex"
    }
  }
}
"$($files.Count) file(s) parsed, $bad with syntax errors"
if ($bad) { exit 1 }
'OK'
