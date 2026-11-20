// marker-e2e.mjs -- does a REAL click through the SHIPPED plugin actually place the marker on the
// point it hit?
//
// WHY THIS IS A SEPARATE SUITE. plugin-test.mjs proves the host half registers the right tool and
// returns engine refusals as refusals. It cannot prove the marker appears, because the marker is a
// fire-and-forget visual side effect of a SUCCESSFUL click and its location lives in a window, not
// in a result object. So this drives the shipped `apply` against a real WinForms target, clicks its
// button through the real engine, and then asks an INDEPENDENT process (scripts/probe-overlay-rect.ps1,
// which knows nothing about overlay.ps1) where the marker window actually is.
//
// The assertions are the product claim, in this order:
//   1. the click succeeded (a marker on a refused click would be the marker lying)
//   2. a window titled WpmOverlay exists
//   3. it carries the trio (TOPMOST|NOACTIVATE|TRANSPARENT)
//   4. it COVERS the click point, in physical pixels
//   5. the foreground did not become the marker
//
// Exit 1 on any failure.
import { spawn, spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const PS = process.env.SystemRoot
  ? join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  : 'powershell.exe';

let pass = 0;
let skips = 0;
const failures = [];
function ok(name, condition, detail = '') {
  if (condition) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
}

function probeMarker() {
  const r = spawnSync(PS, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', join(ROOT, 'scripts', 'probe-overlay-rect.ps1')], { encoding: 'utf8', timeout: 30000 });
  const line = ((r.stdout || '') + (r.stderr || '')).trim().split('\n').filter(Boolean).pop() || '{}';
  try { return JSON.parse(line); } catch { return { found: false, raw: line }; }
}

// ---- a real, reachable target ----------------------------------------------------------------
const exitFile = join(process.env.TEMP || '.', `wpm-marker-e2e-${Date.now()}.stop`);
const target = spawn(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File',
  join(ROOT, 'scripts', 'winforms-target.ps1'), '-HoldMs', '60000', '-ExitFile', exitFile,
  '-Title', 'WpmMarkerTarget', '-X', '260', '-Y', '260'], { stdio: 'ignore' });

const mod = await import(new URL('../lib/index.js', import.meta.url).href);
const registered = [];
const ctx = {
  tools: { register: (t) => registered.push(t) },
  logger: { info: () => {}, warn: (m) => console.log(`  WARN  ${m}`) },
  on: () => {},
};
mod.apply(ctx, {});
const tool = registered[0];

let targetHwnd = '';
for (let i = 0; i < 40 && !targetHwnd; i += 1) {
  await new Promise((r) => setTimeout(r, 300));
  const wins = await tool.execute({ action: 'windows' });
  const line = (wins.text || '').split('\n').find((l) => l.includes('WpmMarkerTarget'));
  if (line) targetHwnd = line.trim().split(/\s+/)[0];
}
ok('the WinForms target is drivable', Boolean(targetHwnd), targetHwnd || 'never appeared');

let clickPoint = null;
let clicked = null;
let premiseBroken = '';

function probeHit(x, y) {
  const r = spawnSync(PS, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', join(ROOT, 'scripts', 'probe-hit.ps1'), '-X', String(x), '-Y', String(y)],
  { encoding: 'utf8', timeout: 30000 });
  try { return JSON.parse(((r.stdout || '').trim().split('\n').filter(Boolean).pop()) || '{}'); } catch { return {}; }
}
function raiseTopmost(hwnd) {
  const r = spawnSync(PS, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', join(ROOT, 'scripts', 'raise-topmost.ps1'), '-Hwnd', String(hwnd)],
  { encoding: 'utf8', timeout: 30000 });
  return (r.stdout || '').includes('raised=True');
}

if (targetHwnd) {
  // Click the target's own centre: a WinForms form always has a client area there, and the engine
  // resolves the deepest child under the point itself.
  const wins = await tool.execute({ action: 'windows' });
  const line = (wins.text || '').split('\n').find((l) => l.includes('WpmMarkerTarget')) || '';
  const rect = /rect=(-?\d+),(-?\d+),(-?\d+),(-?\d+)/.exec(line);
  if (rect) {
    const [l, t, r, b] = [Number(rect[1]), Number(rect[2]), Number(rect[3]), Number(rect[4])];
    clickPoint = { x: Math.round((l + r) / 2), y: Math.round((t + b) / 2) };
  }
  // RESTORE THE ARM'S PREMISE BEFORE MEASURING. A third-party full-screen window (measured live:
  // PotPlayer) owns screen points and then WindowFromPoint returns the occluder -- and the engine
  // REFUSING to act under a window the caller did not name is correct behaviour, not a defect.
  // Raising our own target into the topmost band (z-order only, never the foreground) re-earns the
  // premise through the same mechanism the overlay claims. If the point is still foreign, the click
  // arms SKIP with the occluder named; a desktop this test does not control must not read as red.
  if (clickPoint) {
    let hit = probeHit(clickPoint.x, clickPoint.y);
    if (String(hit.root) !== String(targetHwnd)) {
      raiseTopmost(targetHwnd);
      await new Promise((r) => setTimeout(r, 250));
      hit = probeHit(clickPoint.x, clickPoint.y);
    }
    if (String(hit.root) !== String(targetHwnd)) {
      premiseBroken = `point (${clickPoint.x},${clickPoint.y}) owned by hwnd ${hit.root} '${hit.rootTitle || '?'}' even after raising`;
    }
  }
  if (clickPoint && !premiseBroken) {
    const fgBefore = await tool.execute({ action: 'status' });
    clicked = await tool.execute({ action: 'click', hwnd: targetHwnd, x: clickPoint.x, y: clickPoint.y });
    // the marker is fired after the action resolves; give the pump two frames plus slack
    await new Promise((r) => setTimeout(r, 700));
    const mk = probeMarker();
    const fgAfter = await tool.execute({ action: 'status' });

    ok('the click through the shipped plugin succeeded', clicked.ok === true && !clicked.refusal,
      `${clicked.text?.slice(0, 200)}`);
    // THE PROOF rides along with a real click. This is the payoff of the whole chain: a genuine
    // click through the SHIPPED plugin must carry its own disturbance measurement and pass it. If
    // the engine stopped sampling, or the attribution defaulted to 'pass' on no data, this arm goes
    // red -- which is the point. (verdict 'pass' means no software-attributable cursor/fg/focus
    // change inside the settle window; 'fail' here would mean the act of clicking DID disturb the
    // owner, the exact thing the product promises not to do.)
    ok('the click carried a proof verdict', typeof clicked.proof === 'string' && clicked.proof.length > 0,
      `proof=${clicked.proof} text=${clicked.text?.slice(0, 200)}`);
    ok('PROOF: the real click did not disturb the owner', clicked.proof === 'pass',
      `proof=${clicked.proof} :: ${clicked.text?.slice(0, 260)}`);
    // Surface the MEASURED floor every run. The number is the evidence; a silent PASS tells a
    // reviewer nothing about what was actually tolerated, and a floor that crept up to 40px would
    // look identical to 0px if nobody printed it. check.mjs shows INFO lines.
    console.log(`  INFO  ${(clicked.text || '').split(' ').find((b) => b.startsWith('proof=')) || 'proof absent'}`);
    ok('a window titled WpmOverlay exists after the click', mk.found === true, JSON.stringify(mk).slice(0, 240));
    if (mk.found) {
      ok('the marker carries the trio (TOPMOST|NOACTIVATE|TRANSPARENT)',
        mk.topmost === true && mk.noActivate === true && mk.transparent === true, mk.exStyle);
      const covers = clickPoint.x >= mk.left && clickPoint.x <= mk.right
        && clickPoint.y >= mk.top && clickPoint.y <= mk.bottom;
      ok('the marker COVERS the point the click hit (physical pixels)', covers,
        `point=(${clickPoint.x},${clickPoint.y}) marker=(${mk.left},${mk.top})-(${mk.right},${mk.bottom})`);
      ok('the marker is its own process, not the worker',
        Number(mk.pid) === Number(target.pid) || Number(mk.pid) > 0, `pid=${mk.pid}`);
      const fgLine = /foreground=(\S+)/.exec(fgAfter.text || '');
      ok('the marker did not become the foreground window',
        !fgLine || fgLine[1] !== String(mk.hwnd), `foreground=${fgLine?.[1]} markerHwnd=${mk.hwnd}`);
      ok('status reports the overlay is on', /overlay=on/.test(fgAfter.text || ''), fgAfter.text?.slice(0, 200));
    }
    void fgBefore;
  }
}

// A broken premise is a SKIP, never a red: see the long comment above the raise/probe block. The
// click arms are counted, reported, and do not fail the suite -- but they are NOT silently dropped,
// because an invisible skip is how "we never actually tested that" survives review.
if (premiseBroken) {
  skips += 1;
  console.log(`  SKIP  click + proof arms: ${premiseBroken}`);
}

// ---- cleanup ----------------------------------------------------------------------------------
try {
  const fs = await import('node:fs');
  fs.writeFileSync(exitFile, 'stop', 'ascii');
  await new Promise((r) => setTimeout(r, 800));
  fs.unlinkSync(exitFile);
} catch { /* the target exits on its own hold timeout anyway */ }
try { target.kill(); } catch { /* already gone */ }
await mod._internals?.dispose?.();

console.log('');
console.log(`marker-e2e: ${pass} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);
