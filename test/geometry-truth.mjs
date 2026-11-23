// geometry-truth.mjs -- the core acceptance for 0.5.0: a screenshot whose coordinates are DATA, and a
// click the CALLER hands back in image pixels without multiplying anything.
//
// WHAT THIS PINS, in the order the arms run:
//   1. the target reports its own button centres in PHYSICAL pixels (app-side oracle, as in
//      uia-click-truth.mjs -- reading our own Invoke back through UIA would grade homework in class);
//   2. `screenshot`'s screenRect equals an INDEPENDENT DwmGetWindowAttribute recompute -- computed by
//      test/geometry-oracle.ps1, which shares no code with src/engine -- and NOT the GetWindowRect
//      rect, which is exactly 8px larger on this desktop (the invisible shadow);
//   3. the PNG on disk decodes, its IHDR size equals the reported imageSize, and it is not blank;
//   4. `preview` reports the element name the TARGET says it put at that point ("Bravo"), before
//      anything is clicked, so confirmation never depends on a picture;
//   5. the round trip: convert Bravo's self-reported centre into IMAGE coordinates, hand them to
//      `click` with space:"image", and require bravo 0->1 with alpha untouched -- three times;
//   6. the reverse arms: a shotId that was never issued is stale_ref, and a point outside the target
//      is refused instead of redirected;
//   7. `label` driving: the snapshot's number for Bravo, used with its snapId, fires the same handler.
//
// NON-VACUITY is asserted, not assumed: the same rect comparison is run against a 10px-shifted DWM
// rect and must FAIL, and a generated all-white PNG must be reported blank -- so neither instrument
// can be green by construction.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const ROOT = process.cwd();
const PS = process.env.SystemRoot
  ? join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  : 'powershell.exe';
const ORACLE = join(ROOT, 'test', 'geometry-oracle.ps1');

let pass = 0;
const failures = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Run the independent oracle. Returns parsed JSON, or null when it could not run. */
function oracle(mode, extra = []) {
  const r = spawnSync(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ORACLE, '-Mode', mode, ...extra],
    { encoding: 'utf8', timeout: 60000 });
  const raw = ((r.stdout || '') + (r.stderr || '')).trim().split('\n').filter(Boolean).reverse();
  for (const line of raw) {
    try { return JSON.parse(line); } catch { /* keep looking: Add-Type noise is possible */ }
  }
  return null;
}

const near = (a, b, tol = 2) => Math.abs(a - b) <= tol;
const sameRect = (a, b, tol = 2) => a && b
  && near(a.left, b.left, tol) && near(a.top, b.top, tol)
  && near(a.right, b.right, tol) && near(a.bottom, b.bottom, tol);

const appOracle = join(tmpdir(), `wpm-geo-truth-${Date.now()}.json`);
if (existsSync(appOracle)) rmSync(appOracle);
const TASK = `WpmGeometryTruth_${process.pid}`;
const runner = join(tmpdir(), `wpm-geo-${Date.now()}.cmd`);
writeFileSync(runner, [
  '@echo off',
  `"${PS}" -NoProfile -ExecutionPolicy Bypass -STA -File "${join(ROOT, 'test', 'uia-click-target.ps1')}" -HoldMs 240000 -X 620 -Y 420 -OutFile "${appOracle}"`,
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

  const usable = (s) => Boolean(s)
    && Number.isFinite(s?.alphaPoint?.x) && s.alphaPoint.x > 0
    && Number.isFinite(s?.bravoPoint?.x) && s.bravoPoint.x > 0;
  let snap = null;
  for (let i = 0; i < 60 && !usable(snap); i += 1) {
    await sleep(500);
    if (!existsSync(appOracle)) continue;
    try { snap = JSON.parse(readFileSync(appOracle, 'utf8')); } catch { snap = null; }
  }
  ok('the two-button target came up and published both centres', usable(snap), JSON.stringify(snap?.bravoPoint));
  if (!usable(snap)) throw new Error('target never published usable geometry');

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
  ok('the product can see the target window', Boolean(hwnd), hwnd || 'never appeared');
  if (!hwnd) throw new Error('target not visible to the product');

  // ---- 2. the frame, recomputed independently -------------------------------------------------
  const frame = oracle('frame', ['-Hwnd', hwnd]);
  ok('the independent DWM oracle answered', Boolean(frame && frame.dwm), JSON.stringify(frame));
  const dwm = frame?.dwm;
  const win32 = frame?.win32;
  const win32Bigger = dwm && win32
    && win32.left <= dwm.left && win32.top <= dwm.top
    && win32.right >= dwm.right && win32.bottom >= dwm.bottom
    && (win32.left < dwm.left || win32.right > dwm.right || win32.bottom > dwm.bottom || win32.top > dwm.top);
  ok('GetWindowRect is LARGER than the DWM frame (the invisible shadow -- the trap this test exists for)',
    win32Bigger, JSON.stringify({ dwm, win32 }));

  // ---- 3. screenshot: coordinates as data ----------------------------------------------------
  const shot = await tool.execute({ action: 'screenshot', hwnd });
  ok('screenshot succeeded', shot.ok === true, `${shot.refusal} ${shot.text}`);
  ok('screenshot reports frame=dwm and dpiAware=true', shot.frame === 'dwm' && shot.dpiAware === true,
    `frame=${shot.frame} dpiAware=${shot.dpiAware}`);
  ok('default is unscaled: scale=1 and identity=true', shot.scale === 1 && shot.identity === true,
    `scale=${shot.scale} identity=${shot.identity}`);
  ok('screenRect equals the INDEPENDENT DWM recompute (<=2px)', sameRect(shot.screenRect, dwm, 2),
    `product=${JSON.stringify(shot.screenRect)} oracle=${JSON.stringify(dwm)}`);
  // NON-VACUITY: the very same comparison must reject the GetWindowRect rect and a +10px shift.
  ok('  ... and the same comparison REJECTS the GetWindowRect rect (non-vacuous)',
    !sameRect(shot.screenRect, win32, 2));
  ok('  ... and rejects a +10px shifted DWM rect (non-vacuous)',
    !sameRect(shot.screenRect, { left: dwm.left + 10, top: dwm.top + 10, right: dwm.right + 10, bottom: dwm.bottom + 10 }, 2));
  ok('the PNG landed on disk', typeof shot.file === 'string' && existsSync(shot.file), String(shot.file));

  const region = [snap.bravoPoint.x - shot.screenRect.left - 60, snap.bravoPoint.y - shot.screenRect.top - 25,
    snap.bravoPoint.x - shot.screenRect.left + 60, snap.bravoPoint.y - shot.screenRect.top + 25].map(Math.round).join(',');
  const img = oracle('image', ['-File', shot.file, '-Region', region]);
  ok('the independent image oracle decoded the PNG', img?.ok === true, JSON.stringify(img));
  ok('PNG magic is 89 50 4E 47', /^89 50 4E 47/.test(img?.magic || ''), String(img?.magic));
  ok('the image is not blank', (img?.nonBlank ?? 0) > 0, `nonBlank=${img?.nonBlank}/${img?.samples}`);
  ok('the BUTTON region is not blank (the picture really contains the target)',
    (img?.regionNonBlank ?? 0) > 0, `regionNonBlank=${img?.regionNonBlank}`);
  ok('imageSize matches the decoded PNG', shot.imageSize?.width === img?.width && shot.imageSize?.height === img?.height,
    `product=${JSON.stringify(shot.imageSize)} oracle=${img?.width}x${img?.height}`);
  // NON-VACUITY of the image arm: an all-white PNG must read blank.
  const blank = join(tmpdir(), `wpm-blank-${Date.now()}.png`);
  oracle('makeblank', ['-File', blank, '-Width', String(img?.width || 100), '-Height', String(img?.height || 100)]);
  const blankReport = oracle('image', ['-File', blank]);
  ok('the blank-image instrument works: an all-white PNG reads blank (non-vacuous)',
    blankReport?.ok === true && blankReport.nonBlank === 0, JSON.stringify(blankReport));

  // ---- 4. preview FIRST: the name must come from the OS, before any click --------------------
  const beforeAny = readApp();
  const pv = await tool.execute({ action: 'preview', hwnd, x: snap.bravoPoint.x, y: snap.bravoPoint.y });
  ok('preview answered ok', pv.ok === true, `${pv.refusal} ${pv.text}`);
  ok('preview names the element the TARGET put under that point ("Bravo")',
    /^Bravo/.test(pv.preview?.name || ''), JSON.stringify(pv.preview));
  ok('preview reports a control type and a rect',
    typeof pv.preview?.controlType === 'string' && pv.preview.controlType.length > 0,
    JSON.stringify(pv.preview));
  const afterPv = readApp();
  ok('a preview click does NOT bump either counter (it is a preview, not an action)',
    afterPv.alpha === beforeAny.alpha && afterPv.bravo === beforeAny.bravo,
    `alpha ${beforeAny.alpha}->${afterPv.alpha} bravo ${beforeAny.bravo}->${afterPv.bravo}`);
  ok('the preview text carries no proof window (there is no action to prove)',
    !/proof=/.test(pv.text || ''), (pv.text || '').slice(0, 120));

  // ---- 5. the round trip, three times -------------------------------------------------------
  let alphaBaseline = afterPv.alpha;
  for (let round = 1; round <= 3; round += 1) {
    const current = readApp();
    const shotN = await tool.execute({ action: 'screenshot', hwnd });
    const rectN = shotN.screenRect;
    const sizeN = shotN.imageSize;
    // The TEST does the conversion independently of the engine: image = (screen - rect) * (img/screen).
    const scaleX = sizeN.width / (rectN.right - rectN.left);
    const scaleY = sizeN.height / (rectN.bottom - rectN.top);
    const imgX = Math.round((current.bravoPoint.x - rectN.left) * scaleX);
    const imgY = Math.round((current.bravoPoint.y - rectN.top) * scaleY);
    const clicked = await tool.execute({
      action: 'click', hwnd, x: imgX, y: imgY, space: 'image', shotId: shotN.shotId, settleMs: 500,
    });
    await sleep(1200);
    const after = readApp();
    ok(`round ${round}: the image-space click was accepted`, clicked.ok === true, `${clicked.refusal} ${clicked.text}`);
    ok(`round ${round}: it reports coordSpace=image and the screen point it converted to`,
      clicked.coordSpace === 'image' && typeof clicked.screenPoint === 'string',
      JSON.stringify({ coordSpace: clicked.coordSpace, screenPoint: clicked.screenPoint, imagePoint: clicked.imagePoint }));
    ok(`round ${round}: THE POINT IS THE CONTRACT -- bravo fired exactly once`,
      after.bravo === current.bravo + 1, `bravo ${current.bravo}->${after.bravo}`);
    ok(`round ${round}: alpha was not touched`, after.alpha === alphaBaseline, `alpha ${after.alpha} vs ${alphaBaseline}`);
  }

  // ---- 6. reverse arms ----------------------------------------------------------------------
  const beforeBad = readApp();
  const badShot = await tool.execute({ action: 'click', hwnd, x: 10, y: 10, space: 'image', shotId: 'shot-never-issued' });
  ok('an unissued shotId is refused with stale_ref', badShot.refusal === 'stale_ref', `${badShot.refusal} ${badShot.text}`);
  const outside = await tool.execute({ action: 'click', hwnd, x: 5, y: 5, settleMs: 300 });
  ok('a point outside the target is still refused (the conversion did not loosen ownership)',
    outside.ok === false && outside.refusal === 'unreachable', `${outside.refusal} ${outside.text}`);
  const afterBad = readApp();
  ok('  ... and neither reverse arm fired a handler',
    afterBad.bravo === beforeBad.bravo && afterBad.alpha === beforeBad.alpha,
    `alpha ${afterBad.alpha} bravo ${afterBad.bravo}`);

  // ---- 7. label driving --------------------------------------------------------------------
  const frameShot = await tool.execute({ action: 'snapshot', hwnd, intent: 'find the Bravo button' });
  ok('snapshot answered', frameShot.ok === true, `${frameShot.refusal} ${frameShot.text}`);
  ok('the snapshot printed a snapId', typeof frameShot.snapId === 'string' && frameShot.snapId.length > 0, String(frameShot.snapId));
  ok('its intent travels with the frame', /intent=find the Bravo button/.test(frameShot.text || ''), (frameShot.text || '').slice(0, 200));
  const rows = Array.isArray(frameShot.elements) ? frameShot.elements : [];
  const bravoRow = rows.find((e) => /^Bravo/.test(e.name || '') && (e.patterns || []).includes('invoke'));
  ok('the frame contains Bravo as an invokable, numbered element', Boolean(bravoRow),
    rows.slice(0, 6).map((e) => `${e.label}:${e.controlType}:${e.name}`).join(' | '));
  if (bravoRow) {
    ok('labels are continuous from 1', rows.every((e, i) => e.label === i + 1),
      rows.slice(0, 5).map((e) => e.label).join(','));
    const beforeLabel = readApp();
    const useX = Math.round((bravoRow.rect.left + bravoRow.rect.right) / 2);
    const useY = Math.round((bravoRow.rect.top + bravoRow.rect.bottom) / 2);
    const byLabel = await tool.execute({ action: 'click', hwnd, x: useX, y: useY, label: bravoRow.label, snapId: frameShot.snapId, settleMs: 500 });
    await sleep(1200);
    const afterLabel = readApp();
    ok('a label click fires the handler the label names', byLabel.ok === true && afterLabel.bravo === beforeLabel.bravo + 1,
      `${byLabel.refusal} bravo ${beforeLabel.bravo}->${afterLabel.bravo}`);
    ok('  ... through the UIA pattern path, not a coordinate click', /channel=uia/.test(byLabel.text || ''), (byLabel.text || '').slice(0, 140));
    ok('  ... and alpha stayed untouched', afterLabel.alpha === beforeLabel.alpha, `alpha ${afterLabel.alpha}`);
  }

  for (const fn of disposers) { try { await fn(); } catch { /* best effort */ } }
} finally {
  cleanup();
}

console.log('');
console.log(`geometry-truth: ${pass} passed, ${failures.length} failed`);
if (failures.length) { console.log(`failed: ${failures.join(', ')}`); process.exit(1); }
process.exit(0);
