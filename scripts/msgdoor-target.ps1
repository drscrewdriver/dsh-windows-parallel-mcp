# msgdoor-target.ps1 — a window holding EVERY shape of classic message door.
#
# WHY A SEPARATE TARGET. The refusal-path measurement needs controls that REFUSE, and the
# general-purpose probe window has none: it offers one editable TextBox, one RichTextBox and
# one enabled Button, so the only thing it can demonstrate is that a working door works. A
# door that silently refuses looks identical to a dead driver unless the dead case is present
# in the same run, which is why the effect oracle is kept app-side here too.
#
# Launched hidden-but-visible (SW_SHOWNA) so it never steals the foreground, and it exits only
# through the -ExitFile this driver writes. Nothing here touches a window it did not create.
param(
  [int]$HoldMs = 120000,
  [string]$Title = 'WpmDoorTarget',
  [string]$ExitFile = '',
  [string]$StateFile = '',
  [int]$X = 1000,
  [int]$Y = 300
)
$ErrorActionPreference = 'Stop'
foreach ($sw in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.2', 'Switch.System.Windows.Forms.UseLegacyAccessibilityFeatures.3') {
  try { [AppContext]::SetSwitch($sw, $false) } catch { }
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DShow {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  public static void Reveal(IntPtr h) { ShowWindow(h, 8); } // SW_SHOWNA: visible, not activated
}
'@

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.Size = New-Object System.Drawing.Size(520, 460)
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point($X, $Y)
$form.Topmost = $false
$form.ShowInTaskbar = $true

$made = @()
function Add-Ctl([string]$name, [string]$kind, [string]$text, [bool]$ro, [bool]$dis) {
  $c = if ($kind -eq 'edit') { New-Object System.Windows.Forms.TextBox }
       elseif ($kind -eq 'rich') { New-Object System.Windows.Forms.RichTextBox }
       elseif ($kind -eq 'combo') { $cb = New-Object System.Windows.Forms.ComboBox; $cb.Items.AddRange(@('one','two')); $cb }
       else { New-Object System.Windows.Forms.Button }
  $c.Name = $name
  if ($kind -ne 'combo') { $c.Text = $text } else { $c.SelectedIndex = 0 }
  if ($ro -and $kind -in @('edit','rich')) { $c.ReadOnly = $true }
  if ($dis) { $c.Enabled = $false }
  $c.Location = New-Object System.Drawing.Point(20, $script:row)
  $c.Size = New-Object System.Drawing.Size(460, 30)
  $script:row += 40
  $form.Controls.Add($c) | Out-Null
  # Out-Null, not a bare call: Controls.Add() RETURNS the index of the added control, and a
  # function's return value in PowerShell is everything its body emitted. Without this, every
  # `$edOk = Add-Ctl ...` captured @(0, <control>) instead of the control, so $edOk.Text threw
  # inside the state-file writer -- which had a catch{} that swallowed it. The target window
  # appeared perfectly normally and the oracle simply never wrote, and the driver could only
  # report 'state file never appeared'. A pipeline that emits a value into an accumulator is a
  # silent-corruption generator, and an empty catch is what let it stay silent.
  $script:made += $name
  return $c
}
$script:row = 20
$script:made = @()

# Six shapes. The list is deliberately the cross-product of (editable | read-only | disabled)
# x (edit | button) minus duplicates, because the refusal REASON differs per shape and an
# engine that reports one generic 'failed' for all six would be useless in practice.
$edOk = Add-Ctl 'doorEditOk' 'edit' 'editable-abc' $false $false
$edRo = Add-Ctl 'doorEditRo' 'edit' 'readonly-abc' $true $false
$edDis = Add-Ctl 'doorEditDis' 'edit' 'disabled-abc' $false $true
$rich = Add-Ctl 'doorRich' 'rich' 'rich-abc' $false $false
$btnOk = Add-Ctl 'doorBtnOk' 'button' 'Press' $false $false
$btnDis = Add-Ctl 'doorBtnDis' 'button' 'PressDisabled' $false $true
$combo = Add-Ctl 'doorCombo' 'combo' '' $false $false
$multi = Add-Ctl 'doorEditMulti' 'edit' 'multi-abc' $false $false
$multi.Multiline = $true
$multi.Height = 60

$clicks = 0
$btnOk.Add_Click({ $script:clicks++; $btnOk.Text = "Press($($script:clicks))" })
$btnDis.Add_Click({ $script:clicks += 100; $btnDis.Text = "DisabledClicked($($script:clicks))" })

# State file: the app's own truth, tab-separated, name=value so the driver matches by label
# and never by index -- an index drift between two runs would attribute one control's refusal
# to another control's success.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
  if ($ExitFile -and (Test-Path -LiteralPath $ExitFile)) { $form.Close(); return }
  if (((Get-Date) - $started).TotalMilliseconds -gt $HoldMs) { $form.Close(); return }
  if ($StateFile) {
    try {
      $pairs = @(
        "doorEditOk=$($edOk.Text)", "doorEditRo=$($edRo.Text)", "doorEditDis=$($edDis.Text)",
        "doorRich=$($rich.Text)", "doorBtnOk=$($btnOk.Text)", "doorBtnDis=$($btnDis.Text)",
        "doorCombo=$($combo.Text)", "doorEditMulti=$($multi.Text)"
      ) -join "`t"
      Set-Content -LiteralPath $StateFile -Value $pairs -Force -ErrorAction Stop
      $script:stateErr = ''
    } catch {
      # The writer's own failure is made visible rather than swallowed. The first version had
      # a bare catch{} here, and when Controls.Add() polluted every control variable the
      # oracle silently stopped writing while the window looked perfectly healthy -- the
      # driver then reported only 'state file never appeared', with no clue that the cause was
      # inside the app.
      $script:stateErr = $_.Exception.Message
      Write-Output ("STATE-ERR " + $script:stateErr)
    }
  }
})
$started = Get-Date
$form.Add_Shown({ try { [void][DShow]::Reveal($form.Handle) } catch { }; Write-Output ("HWND=" + $form.Handle.ToInt64()) })
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
