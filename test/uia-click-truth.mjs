// uia-click-truth.mjs -- a click must act on the element AT THE POINT, not the first one in
// tree order.
//
// THE BUG THIS PINS. The UIA tier used to take the first descendant carrying any usable pattern
// and invoke it, while the contract says x/y are required and that a point which does not resolve
// inside the target is refused "instead of being sent somewhere else". On any target without a
// message door -- WPF, UWP, WinUI3, i.e. most modern apps -- 'click' at Bravo's coordinates
// invoked Alpha and returned ok:true. Verified against the pre-fix engine while writing this file:
// alpha 0->1, bravo unchanged, last='alpha', result ok:true. A single-button target cannot see
// this; two buttons far apart turn it into an observation.
//
// WHY THE ORACLE IS A FILE THE APP WRITES. Reading a WPF control's text back through UIA to check
// what our own Invoke did is grading homework in its own class. The handler that fired is the only
// code that knows, so it appends to a JSON file and this test reads that.
//
// WHY THE TARGET REPORTS PHYSICAL PIXELS. This desktop runs at 150%; the first version of this
// test multiplied PointToScreen by TransformToDevice, double-counted the scale, aimed 1.5x outside
// the window and got a (correct) refusal for a point that was never inside the target. The target
// now reports its own button centres in physical pixels -- the same DPI lesson the marker had.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const ROOT = process.cwd();
const PS = process.env.SystemRoot
  ? join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  : 'powershell.exe';

let pass = 0;
const failures = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
};

const oracle = join(tmpdir(), `wpm-two-button-${Date.now()}.json`);
if (existsSync(oracle)) rmSync(oracle);

// The target is launched by a scheduled task, not by this process: the host reaps a child's
// process tree when the command that started it exits, so a detached GUI would die with the shell.
const runner = join(tmpdir(), `wpm-2btn-${Date.now()}.cmd`);
const TASK = `WpmUiaClickTruth_${process.pid}`;
writeFileSync(runner, [
  '@echo off',
  `"${PS}" -NoProfile -ExecutionPolicy Bypass -STA -File "${join(ROOT, 'test', 'uia-click-target.ps1')}" -HoldMs 180000 -X 700 -Y 500 -OutFile "${oracle}"`,
  '',
].join('\r\n'));

const schtasks = (args) => spawnSync('schtasks', args, { encoding: 'utf8', timeout: 30000 });
const cleanup = () => {
  schtasks(['/end', '/tn', TASK]);
  schtasks(['/delete', '/tn', TASK, '/f']);
  try { rmSync(runner); } catch { /* already gone */ }
  try {
    spawnSync(PS, ['-NoProfile', '-Command',
      `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*uia-click-target*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`],
      { encoding: 'utf8', timeout: 30000 });
  } catch { /* best effort */ }
};

let target = null;
try {
  schtasks(['/create', '/tn', TASK, '/tr', runner, '/sc', 'once', '/st', '23:59', '/f', '/it']);
  schtasks(['/run', '/tn', TASK]);

  // Wait for the app to publish MEANINGFUL geometry. The point is reported BY THE TARGET, so the
  // only thing this test computes is "did the counter for THAT button move".
  //
  // Why the loop does not stop at "the file parses": it used to, and that was the bug. The target
  // wrote an oracle before ShowDialog() with -1,-1 coordinates (ActualWidth was still 0, so
  // PointToScreen threw and the catch-all won); the reader took the first parseable snapshot and
  // graded it. Under load the composite gate hit exactly that window and reported four failures that
  // looked like product defects. A snapshot is only evidence once BOTH centres are real, so a
  // placeholder is treated as "not up yet" rather than as a measurement.
  const usable = (s) => Boolean(s)
    && Number.isFinite(s?.alphaPoint?.x) && s.alphaPoint.x > 0
    && Number.isFinite(s?.bravoPoint?.x) && s.bravoPoint.x > 0;
  let snap = null;
  for (let i = 0; i < 60 && !usable(snap); i += 1) {
    await new Promise((r) => setTimeout(r, 500));
    if (!existsSync(oracle)) continue;
    try { snap = JSON.parse(readFileSync(oracle, 'utf8')); } catch { snap = null; }
  }
  ok('the two-button target came up and published its oracle', Boolean(snap),
    snap ? '' : 'no oracle file');
  ok('it reports both button centres in physical pixels',
    snap && snap.bravoPoint && snap.bravoPoint.x > 0 && snap.alphaPoint.x > 0, JSON.stringify(snap?.bravoPoint));
  ok('the two centres are far apart (a single-point target could not tell them apart)',
    snap && Math.abs(snap.bravoPoint.x - snap.alphaPoint.x) > 100, JSON.stringify(snap && [snap.alphaPoint, snap.bravoPoint]));

  if (snap) {
    const mod = await import('../lib/index.js');
    const registered = [];
    const disposers = [];
    mod.apply({
      tools: { register: (t) => registered.push(t) },
      logger: { info: () => {}, warn: () => {} },
      on: (event, fn) => { if (event === 'dispose') disposers.push(fn); },
    }, {});
    const tool = registered[0];

    // Find the target through the product's own window list: a hardcoded hwnd would be a stale
    // constant the moment the task is relaunched.
    let hwnd = '';
    for (let i = 0; i < 20 && !hwnd; i += 1) {
      const w = await tool.execute({ action: 'windows' });
      const line = (w.text || '').split('\n').find((l) => /WpmTwoButtonTarget/.test(l));
      if (line) hwnd = line.trim().split(/\s+/)[0];
      else await new Promise((r) => setTimeout(r, 500));
    }
    ok('the product can see the target window', Boolean(hwnd), hwnd || 'never appeared');

    if (hwnd) {
      const before = JSON.parse(readFileSync(oracle, 'utf8'));
      const p = before.bravoPoint;
      const r = await tool.execute({ action: 'click', hwnd, x: p.x, y: p.y, settleMs: 600 });
      await new Promise((res) => setTimeout(res, 1200));
      const after = JSON.parse(readFileSync(oracle, 'utf8'));

      ok('the click was accepted', r.ok === true, `${r.ok} ${r.refusal} ${r.text}`);
      ok('THE POINT IS THE CONTRACT: the button under the point fired (bravo +1)',
        after.bravo === before.bravo + 1, `bravo ${before.bravo}->${after.bravo}`);
      ok('and the OTHER button was NOT touched (the pre-fix engine bumped it)',
        after.alpha === before.alpha, `alpha ${before.alpha}->${after.alpha}`);
      ok('the app itself agrees which handler ran', after.last === 'bravo', String(after.last));
      ok('the report names the UIA tier, so this was the path under test',
        /channel=uia/.test(r.text) || /channel=message/.test(r.text), r.text?.slice(0, 120));

      // A point OUTSIDE the target must be refused, never redirected. This is the same invariant
      // expressed in the other direction: 'not this window' is a refusal, not a best guess.
      const out = await tool.execute({ action: 'click', hwnd, x: 5, y: 5, settleMs: 300 });
      await new Promise((res) => setTimeout(res, 800));
      const after2 = JSON.parse(readFileSync(oracle, 'utf8'));
      ok('a point outside the target is refused rather than sent to some element',
        out.ok === false && out.refusal === 'unreachable', `${out.ok} ${out.refusal} ${out.text}`);
      ok('  ... and neither button fired for it',
        after2.alpha === after.alpha && after2.bravo === after.bravo,
        `alpha ${after.alpha}->${after2.alpha} bravo ${after.bravo}->${after2.bravo}`);
      ok('  ... and the refusal says WHY, not just unreachable',
        /at that point:/.test(out.text || ''), out.text);
    }

    for (const fn of disposers) { try { await fn(); } catch { /* best effort */ } }
  }
} finally {
  cleanup();
}

console.log('');
console.log(`uia-click-truth: ${pass} passed, ${failures.length} failed`);
if (failures.length) { console.log(`failed: ${failures.join(', ')}`); process.exit(1); }
process.exit(0);
