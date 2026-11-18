# close-edge-profile.ps1 — close ONLY the Edge processes using one profile directory.
#
# WHY MATCH ON THE COMMAND LINE AND NOT THE TITLE. Probe windows are identified by a title
# we authored, but a title can be reused, changed by the app, or matched by a window the
# user opened; and closing a browser window by title on a shared process would take the
# user's tabs with it. Every process in these experiments is launched with an explicit
# --user-data-dir under %TEMP%, a path no user session has, so the command line identifies
# ownership exactly and nothing else.
param(
  [Parameter(Mandatory = $true)][string]$ProfileDir,
  [switch]$DryRun
)
$ErrorActionPreference = 'Continue'
if (-not $ProfileDir) { throw 'ProfileDir is required; refusing to act without an ownership filter' }
# Guard against a value that would match everything: the profile must be a probe temp dir.
if ($ProfileDir -notmatch 'wpm-') {
  throw "refusing to close processes for '$ProfileDir': the name does not contain the 'wpm-' probe marker"
}

# Get-CimInstance is used rather than Get-Process because the command line is what carries
# the ownership proof, and 5.1's Get-Process does not expose it.
$procs = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like "*$ProfileDir*" })

if (-not $procs.Count) { "no msedge processes for '$ProfileDir'"; exit 0 }
"matched=$($procs.Count) for '$ProfileDir'"
foreach ($p in $procs) {
  $cl = $p.CommandLine
  if ($cl.Length -gt 140) { $cl = $cl.Substring(0, 140) + '...' }
  if ($DryRun) { "would stop pid=$($p.ProcessId) :: $cl"; continue }
  try {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
    "stopped pid=$($p.ProcessId)"
  } catch {
    # Browser processes re-parent: stopping the matched parent usually takes the renderers
    # with it. A surviving child is reported, never hidden.
    "stop failed pid=$($p.ProcessId): $($_.Exception.Message)"
  }
}
Start-Sleep -Milliseconds 900
$left = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like "*$ProfileDir*" })
"remaining=$($left.Count)"
