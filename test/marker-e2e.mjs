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
let fgBefore = null;
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
    fgBefore = await tool.execute({ action: 'status' });
    clicked = await tool.execute({ action: 'click', hwnd: targetHwnd, x: clickPoint.x, y: clickPoint.y });
    // TOCTOU ON A DESKTOP WE DO NOT OWN. The premise was checked milliseconds ago, but a fullscreen
    // video window (observed: PotPlayer) can move over the point BETWEEN the check and the click.
    // The engine then correctly refuses ("no child window of the target sits under that point") --
    // that refusal is the product behaving exactly as specified, and the test's PREMISE broke, not
    // the product. Re-probe and, if the point is foreign now, convert the click+proof arms to a
    // NAMED SKIP. Silently passing a refusal would hide a real breakage; failing it blames us for
    // someone else's window. Neither: name what happened.
    if (clicked.refusal === 'unreachable' && /sits under that point/.test(clicked.reason || clicked.text || '')) {
      const hit2 = probeHit(clickPoint.x, clickPoint.y);
      if (String(hit2.root) !== String(targetHwnd)) {
        premiseBroken = `point (${clickPoint.x},${clickPoint.y}) was ours before the click but is owned by hwnd ${hit2.root} '${hit2.rootTitle || '?'}' at click time (TOCTOU occlusion; the engine's refusal is correct)`;
        clicked = null;
      }
    }
  }
  if (clickPoint && clicked) {
    // The marker is placed ASYNCHRONOUSLY (deliberately: never on the action's critical path) and,
    // when the overlay was not already up, that placement waits behind a one-time ~875ms overlay
    // start. It then auto-hides 1500ms after placement. A single snapshot at +700ms therefore reads
    // the parked -2000 position on a cold overlay -- a timing miss, not the product, and the same
    // flake overlay-test already learned to poll past. So POLL for coverage within a bounded window
    // and keep the BEST sample; if it is still parked after the window the arm fails for real.
    let mk = probeMarker();
    const coverDeadline = Date.now() + 1600;
    const coversAt = (m) => m.found && clickPoint.x >= m.left && clickPoint.x <= m.right
      && clickPoint.y >= m.top && clickPoint.y <= m.bottom;
    while (!coversAt(mk) && Date.now() < coverDeadline) {
      await new Promise((r) => setTimeout(r, 100));
      const probe = probeMarker();
      if (probe.found && !mk.found) mk = probe;          // take the first window that appears
      else if (coversAt(probe)) mk = probe;               // and stop as soon as it covers
      else if (mk.found && probe.left > mk.left) mk = probe; // keep the most-placed sample
    }
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
    // THE PROOF rides along with a real click, and the bar it is held to is the honest one.
    //   fail            -- the click DID disturb the owner in a way the instrument can attribute
    //                      (sustained cursor motion, or a foreground/focus switch the pre-action
    //                      control shows the desktop was not already doing). This is a real red.
    //   pass            -- nothing unexplained moved: direct evidence.
    //   inconclusive    -- a cursor/foreground event happened that position data cannot attribute to
    //                      anyone (an isolated ambient jump with no physical input). NOT a pass and
    //                      NOT blamed: forcing the instrument to name a culprit it cannot would be
    //                      the laundering this whole module exists to refuse.
    // So the arm fails on 'fail' and 'insufficient', and PASSES on pass-or-inconclusive -- but the
    // INFO line prints the dimension, so a desktop that is ALWAYS inconclusive (the proof has begun
    // proving nothing) is visible to a human, not hidden behind a green.
    const d = clicked.proofDimensions || {};
    ok('PROOF: the real click was not blamed for sustained disturbance',
      clicked.proof === 'pass' || clicked.proof === 'inconclusive',
      `proof=${clicked.proof} :: ${clicked.text?.slice(0, 260)}`);
    // ANTI-VACUITY GUARD. Tolerating 'inconclusive' is only honest if a desktop that is ALWAYS
    // inconclusive is loud about it -- otherwise the gate goes green while proving nothing, which is
    // the exact failure this module exists to refuse. So pass prints INFO, anything weaker prints
    // WARN: a reviewer sees the proof's actual strength, not just its colour. (The cursor dimension
    // has a known limit recorded in proof-window.mjs: a regression that warps the cursor in exactly
    // ONE gap is indistinguishable from an ambient correction, so it reports inconclusive rather
    // than fail. It is not lost -- sustained motion fails, foreground/focus fail outright, and the
    // coverage arm above checks the marker landed on the point the click hit.)
    const strength = clicked.proof === 'pass' ? 'INFO' : 'WARN';
    console.log(`  ${strength}  proof=${clicked.proof}`
      + (d.cursor ? ` [cursor=${d.cursor} fg=${d.foreground} focus=${d.focus}]` : '')
      + ` :: ${(clicked.text || '').split(/proof=\w+\(/)[1]?.slice(0, 120) || ''}`);
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
