// idle-baseline.mjs -- what the cursor does when NOTHING of ours runs.
//
// WHY THIS EXISTS. The runtime proof (lib/proof-window.mjs) had to decide what it may BLAME on an
// action. The decisive measurement is this one: sample the cursor over windows the same length as a
// real action while no action runs. Measured on the authoring machine (150% DPI, PotPlayer-era
// desktop, four 400ms-spaced idle windows of 24 samples): unexplained motion gaps of 0, 3, 0, 0 with
// a max delta of ~11px -- i.e. the desktop ITSELF produces multi-gap unexplained motion. That single
// measurement is why the cursor dimension can only ever report pass/inconclusive and never fail, and
// why the cursor promise moved to build time (check-no-cursor-control.mjs: the engine contains no
// SetCursorPos/SendInput/mouse_event/keybd_event, which IS blameable with certainty).
//
// It is kept runnable rather than quoted: an ambient-driven number decays. A future reviewer can
// re-run this on a machine suspected of noise and see whether the runtime sensor's restraint is
// still honest -- and a machine where idle stays at 0 gaps across many windows is one where a
// stricter runtime cursor rule COULD be revisited (with new evidence, not nostalgia).
//
// Usage:  node scripts/idle-baseline.mjs [windows]   (default 4)
import { spawnSync } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { evaluateProof } from '../lib/proof-window.mjs';

const N = Math.max(1, parseInt(process.argv[2] || '4', 10) || 4);
const dir = '.tmp';
mkdirSync(dir, { recursive: true });
const ps = join(dir, 'idle-samples.ps1');
// Same four read-only syscalls the engine's sampler uses, in the same 15ms rhythm -- but no worker,
// no overlay, no door call: nothing of the product runs during these windows.
writeFileSync(ps, `
. (Join-Path $PSScriptRoot '..\\src\\engine\\win.ps1')
$out = @()
for ($i = 0; $i -lt 24; $i++) {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $s = [WpmWin]::Sample()
  $out += (@{ ts = $now; cx = [int]$s[0]; cy = [int]$s[1]; fg = [string]$s[2]; focus = [string]$s[3]; inputAgeMs = [long]$s[4] })
  Start-Sleep -Milliseconds 15
}
($out | ConvertTo-Json -Depth 4 -Compress) | Write-Output
`, 'utf8');

let worstGaps = 0;
for (let k = 0; k < N; k++) {
  const r = spawnSync('powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps],
    { encoding: 'utf8', timeout: 30000 });
  const lines = (r.stdout || '').trim().split('\n').filter(Boolean);
  let samples = [];
  try { const j = JSON.parse(lines[lines.length - 1]); samples = Array.isArray(j) ? j : [j]; } catch { /* fallthrough */ }
  const ev = evaluateProof(samples);
  const a = ev.attribution || {};
  worstGaps = Math.max(worstGaps, a.unexplainedCursorMotionGaps ?? 0);
  console.log(`idle window ${k + 1}/${N}: samples=${ev.samples} gaps=${a.unexplainedCursorMotionGaps ?? '?'} maxPx=${a.unexplainedCursorMaxDeltaPx ?? '?'} fg=${a.unexplainedForegroundSwitches ?? '?'} verdict=${ev.verdict}`);
  await new Promise((x) => setTimeout(x, 400));
}
console.log('');
console.log(`worst unexplained cursor gaps with NOTHING running: ${worstGaps} (over ${N} window(s))`);
if (worstGaps >= 2) {
  console.log('=> the runtime cursor dimension must NOT fail on multi-gap motion: this desktop moves on its own');
} else if (N >= 10 && worstGaps === 0) {
  console.log('=> quiet across >=10 windows: a stricter runtime cursor rule COULD be revisited WITH THIS EVIDENCE');
} else {
  console.log('=> not enough windows to conclude quietness (ambient motion is episodic: the same machine');
  console.log('   showed 3 gaps in one window minutes before this run). Run with a higher count, or accept');
  console.log('   the current rule: blame lives at build time, the sensor reports and does not accuse.');
}
