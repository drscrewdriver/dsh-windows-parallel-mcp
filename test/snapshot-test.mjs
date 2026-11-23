// snapshot-test.mjs -- the numbered frame's own promises, and the retention policy behind screenshots.
//
// WHY A SEPARATE SUITE FROM geometry-truth. geometry-truth answers "can the model point at the thing
// it means". This file answers "is the numbering itself honest": continuous labels, a truncation
// notice that names both numbers, a sinceSnapId delta that is EMPTY when nothing moved, a superseded
// frame that is refused instead of silently reused, screenshots that stop accumulating, and - the
// one that is pure arithmetic - the frame invariant from src/engine/win.ps1 evaluated with the
// measured numbers and with a deliberately shifted frame, so the predicate cannot be green by
// construction.
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const ROOT = process.cwd();
const PS = process.env.SystemRoot
  ? join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  : 'powershell.exe';

let pass = 0;
const skips = [];
const failures = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
};
const skip = (name, why) => { skips.push(name); console.log(`  SKIP  ${name} :: ${why}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- arm 0: the frame invariant, as a PURE predicate with measured numbers --------------------
// The measured pair from this desktop (findings.md 2026-11-23): DWM frame 0,0,1920,1032 vs the
// accessibility tree's root rect -8,-8,1928,1040 (the shadow space). The predicate must say YES for
// that pair and NO for a frame shifted by 10px -- otherwise it is decoration.
{
  const probe = join(tmpdir(), `wpm-frame-invariant-${Date.now()}.ps1`);
  writeFileSync(probe, [
    "$ErrorActionPreference = 'Stop'",
    "Set-StrictMode -Version 2.0",
    `. (Join-Path '${join(ROOT, 'src', 'engine').replace(/'/g, "''")}' 'engine.ps1')`,
    '$frame = @{ ok = $true; frame = \'dwm\'; hr = 0; left = 0; top = 0; right = 1920; bottom = 1032 }',
    '$root = @{ left = -8; top = -8; right = 1928; bottom = 1040 }',
    'Write-Output ("measured=" + (Test-WpmFrameInsideRoot -Frame $frame -RootRect $root).ok)',
    '$shifted = @{ ok = $true; frame = \'dwm\'; hr = 0; left = 20; top = 20; right = 1940; bottom = 1052 }',
    'Write-Output ("shifted=" + (Test-WpmFrameInsideRoot -Frame $shifted -RootRect $root).ok)',
    '$outside = @{ ok = $true; frame = \'dwm\'; hr = 0; left = 0; top = 0; right = 1920; bottom = 1032 }',
    '$tinyRoot = @{ left = 100; top = 100; right = 500; bottom = 500 }',
    'Write-Output ("tinyRoot=" + (Test-WpmFrameInsideRoot -Frame $outside -RootRect $tinyRoot).ok)',
  ].join('\n'));
  const r = spawnSync(PS, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', probe],
    { encoding: 'utf8', timeout: 120000 });
  const out = ((r.stdout || '') + (r.stderr || '')).trim();
  try { rmSync(probe); } catch { /* best effort */ }
  ok('the measured frame/root pair PASSES the invariant', /measured=True/.test(out), out.slice(0, 300));
  ok('a +10px shifted frame FAILS the invariant (the predicate is not decoration)', /shifted=False/.test(out), out.slice(0, 300));
  ok('a frame larger than the root FAILS the invariant', /tinyRoot=False/.test(out), out.slice(0, 300));
}

// ---- the live target -------------------------------------------------------------------------
const appOracle = join(tmpdir(), `wpm-snapshot-test-${Date.now()}.json`);
if (existsSync(appOracle)) rmSync(appOracle);
const TASK = `WpmSnapshotTest_${process.pid}`;
const runner = join(tmpdir(), `wpm-snap-${Date.now()}.cmd`);
writeFileSync(runner, [
  '@echo off',
  `"${PS}" -NoProfile -ExecutionPolicy Bypass -STA -File "${join(ROOT, 'test', 'uia-click-target.ps1')}" -HoldMs 240000 -X 640 -Y 440 -OutFile "${appOracle}"`,
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
const readApp = () => JSON.parse(readFileSync(appOracle, 'utf8'));

try {
  schtasks(['/create', '/tn', TASK, '/tr', runner, '/sc', 'once', '/st', '23:59', '/f', '/it']);
  schtasks(['/run', '/tn', TASK]);
  const usable = (s) => Boolean(s) && Number.isFinite(s?.bravoPoint?.x) && s.bravoPoint.x > 0;
  let appSnap = null;
  for (let i = 0; i < 60 && !usable(appSnap); i += 1) {
    await sleep(500);
    if (!existsSync(appOracle)) continue;
    try { appSnap = JSON.parse(readFileSync(appOracle, 'utf8')); } catch { appSnap = null; }
  }
  ok('the two-button target came up', usable(appSnap), JSON.stringify(appSnap?.bravoPoint));
  if (!usable(appSnap)) throw new Error('target never came up');

  const mod = await import('../lib/index.js');
  const registered = [];
  const disposers = [];
  mod.apply({
    tools: { register: (t) => registered.push(t) },
    logger: { info: () => {}, warn: () => {} },
    on: (event, fn) => { if (event === 'dispose') disposers.push(fn); },
  }, {});
  const tool = registered[0];

  let hwnd = '';
  for (let i = 0; i < 20 && !hwnd; i += 1) {
    const w = await tool.execute({ action: 'windows' });
    const line = (w.text || '').split('\n').find((l) => /WpmTwoButtonTarget/.test(l));
    if (line) hwnd = line.trim().split(/\s+/)[0];
    else await sleep(400);
  }
  ok('the product can see the target', Boolean(hwnd), hwnd || 'never appeared');
  if (!hwnd) throw new Error('target not visible');

  // ---- 1. labels, truncation ----------------------------------------------------------------
  const A = await tool.execute({ action: 'snapshot', hwnd, intent: 'truncation arm' });
  ok('snapshot A answered', A.ok === true, `${A.refusal} ${A.text}`);
  ok('A prints a continuous label sequence starting at 1', A.elements.every((e, i) => e.label === i + 1),
    A.elements.slice(0, 6).map((e) => e.label).join(','));
  ok('A reports a total that is at least the number returned', A.count <= (A.total ?? A.count),
    `count=${A.count} total=${A.total}`);
  const C1 = await tool.execute({ action: 'snapshot', hwnd, maxElements: 1 });
  ok('maxElements=1 truncates', C1.truncated === true, JSON.stringify({ count: C1.count, truncated: C1.truncated }));
  ok('the truncation is stated with BOTH numbers in the text',
    new RegExp(`truncated at 1 of \\d+`).test(C1.text || ''), (C1.text || '').split('\n')[0]);

  // ---- 2. interactableOnly ------------------------------------------------------------------
  const loose = await tool.execute({ action: 'snapshot', hwnd, interactableOnly: false });
  ok('interactableOnly:false returns at least as many elements as the default',
    (loose.count ?? 0) >= (A.count ?? 0), `default=${A.count} all=${loose.count}`);

  // ---- 3. the delta is EMPTY when nothing moved ---------------------------------------------
  // The worker keeps exactly TWO snapshots: the newest resolves labels, the one before it is the only
  // valid sinceSnapId. So the empty-delta arm takes its own base and diffs against it IMMEDIATELY --
  // an intervening snapshot would supersede the base and turn this into a stale_ref arm by accident.
  const F = await tool.execute({ action: 'snapshot', hwnd, intent: 'delta base' });
  const B = await tool.execute({ action: 'snapshot', hwnd, sinceSnapId: F.snapId });
  ok('a delta against an unchanged tree is empty',
    /no changes since/.test(B.text || ''), (B.text || '').split('\n').slice(0, 3).join(' | '));
  ok('the empty delta carries no element table', (B.delta?.added ?? []).length === 0
    && (B.delta?.removed ?? []).length === 0 && (B.delta?.changed ?? []).length === 0,
    JSON.stringify(B.delta));

  // ---- 4. the delta names what DID move ------------------------------------------------------
  // B is the newest frame, so its labels are the ones that resolve.
  const bravoRow = (B.elements || []).find((e) => /^Bravo/.test(e.name || '') && (e.patterns || []).includes('invoke'));
  ok('the frame contains Bravo as a numbered invokable element', Boolean(bravoRow),
    (B.elements || []).slice(0, 5).map((e) => `${e.label}:${e.name}`).join(' | '));
  if (bravoRow) {
    const before = readApp();
    const useX = Math.round((bravoRow.rect.left + bravoRow.rect.right) / 2);
    const useY = Math.round((bravoRow.rect.top + bravoRow.rect.bottom) / 2);
    const clicked = await tool.execute({ action: 'click', hwnd, x: useX, y: useY, label: bravoRow.label, snapId: B.snapId, settleMs: 400 });
    await sleep(1200);
    const after = readApp();
    ok('the labelled click fired bravo', clicked.ok === true && after.bravo === before.bravo + 1,
      `${clicked.refusal} bravo ${before.bravo}->${after.bravo}`);
    const C = await tool.execute({ action: 'snapshot', hwnd, sinceSnapId: B.snapId });
    ok('the delta after the click is NOT empty', /delta vs/.test(C.text || '')
      && ((C.delta?.added?.length ?? 0) + (C.delta?.removed?.length ?? 0) + (C.delta?.changed?.length ?? 0)) > 0,
      (C.text || '').split('\n').slice(0, 4).join(' | '));
    ok('the changed list names the button whose label text changed',
      (C.delta?.changed ?? []).some((e) => /^Bravo/.test(e.name || '')),
      JSON.stringify((C.delta?.changed ?? []).map((e) => ({ name: e.name, changed: e.changed }))));
    ok('the delta reports which fields moved, not just that something did',
      (C.delta?.changed ?? []).every((e) => Array.isArray(e.changed) && e.changed.length > 0),
      JSON.stringify(C.delta?.changed));

    // ---- 5. superseded references are refused ---------------------------------------------
    const oldLabel = await tool.execute({ action: 'click', hwnd, x: useX, y: useY, label: 1, snapId: A.snapId });
    ok('a label from a superseded snapId is stale_ref', oldLabel.refusal === 'stale_ref',
      `${oldLabel.refusal} ${oldLabel.text}`);
    // Two snapshots are retained: A is now three generations back and must be gone as a diff base.
    const oldSince = await tool.execute({ action: 'snapshot', hwnd, sinceSnapId: A.snapId });
    ok('a sinceSnapId that was dropped is stale_ref (not an empty diff)', oldSince.refusal === 'stale_ref',
      `${oldSince.refusal} ${oldSince.text}`);
    const badLabel = await tool.execute({ action: 'click', hwnd, x: useX, y: useY, label: 999, snapId: C.snapId });
    ok('a label that was never printed is stale_ref', badLabel.refusal === 'stale_ref',
      `${badLabel.refusal} ${badLabel.text}`);
    const mismatch = await tool.execute({ action: 'click', hwnd, x: useX + 4000, y: useY, label: (C.elements || [])[0]?.label ?? 1, snapId: C.snapId });
    ok('a label whose point disagrees with its rect is refused', mismatch.ok === false
      && ['unreachable', 'stale_ref'].includes(mismatch.refusal), `${mismatch.refusal} ${mismatch.text}`);
  }

  // ---- 6. the "0 element(s)" answer is a state, not a failure -------------------------------
  {
    const w = await tool.execute({ action: 'windows' });
    const lines = (w.text || '').split('\n').slice(1).filter(Boolean);
    let found = false;
    for (const line of lines.slice(0, 12)) {
      const h = line.trim().split(/\s+/)[0];
      if (h === hwnd) continue;
      const s = await tool.execute({ action: 'snapshot', hwnd: h });
      if (s.ok === true && s.count === 0 && /^snapshot ok: 0 element\(s\)/.test(s.text || '')) {
        ok('a window that exposes nothing is reported as "0 element(s)", not as uia_tree_empty', true);
        ok('  ... and says why zero is a real state', /real state/.test(s.text || ''), (s.text || '').split('\n').slice(-1)[0]);
        found = true;
        break;
      }
    }
    if (!found) skip('0-element real state', 'no window on this desktop currently exposes zero drivable elements');
  }

  // ---- 7. retention: 12 captures keep only shotsKeep --------------------------------------
  {
    const { CONFIG_DEFAULTS } = await import('../lib/config.js');
    const keep = CONFIG_DEFAULTS.shotsKeep;
    for (let i = 0; i < keep + 2; i += 1) await tool.execute({ action: 'screenshot', hwnd });
    const last = await tool.execute({ action: 'screenshot', hwnd });
    const dir = last.file ? join(last.file, '..') : '';
    const pngs = dir ? readdirSync(dir).filter((f) => f.toLowerCase().endsWith('.png')) : [];
    ok(`retention keeps at most shotsKeep=${keep} PNGs (took ${keep + 3})`,
      pngs.length <= keep, `files=${pngs.length}`);
    ok('every retained PNG is non-empty and starts with the PNG magic', pngs.every((f) => {
      const p = join(dir, f);
      const b = readFileSync(p);
      return statSync(p).size > 0 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;
    }), pngs.join(','));
  }

  for (const fn of disposers) { try { await fn(); } catch { /* best effort */ } }
} finally {
  cleanup();
}

console.log('');
console.log(`snapshot-test: ${pass} passed, ${failures.length} failed, ${skips.length} skipped`);
if (failures.length) { console.log(`failed: ${failures.join(', ')}`); process.exit(1); }
process.exit(0);
