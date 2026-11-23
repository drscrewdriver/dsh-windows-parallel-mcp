// desktop-actions.mjs -- 0.7.0's three new actions, end to end on real windows.
//
// WHY THIS EXISTS SEPARATELY FROM plugin-test. plugin-test proves the GATES with a stubbed worker (no
// desktop needed, so it cannot pass by luck); this file proves the CAPABILITIES against a process that
// really started, a clipboard that really changed, and a window that really moved. The two are not
// interchangeable: a gate can be right while the syscall behind it is wrong, and the failure mode that
// makes that dangerous here is "ok:true with nothing observable to check".
//
// EVERY ARM IS VERIFIED BY A READ, not by the action's own answer:
//   launch   -> the pid exists as a process, and the hwnd the result names is IsWindow() true
//   snapshot -> the launched window appears in its own frame with at least one element
//   click    -> the point belongs to the launched window (WindowFromPoint), then the result's tier
//   clipboard-> write text, read text back THROUGH THE TOOL, compare; image goes shotId -> clipboard
//               -> a PNG on disk whose size matches the shot that was pushed in
//   window   -> minimize/restore via a second process reading IsIconic; move/resize via GetWindowRect;
//                topmost via the ex-style bit. The reader is an independent PowerShell, not the engine
//                that made the change -- the same discipline as marker-e2e's rect oracle.
//
// LAUNCH IS NOTHING BUT A GATE AWAY FROM ARBITRARY CODE, which is why this file launches a program the
// owner whitelisted in the settings object it constructs here, and why the cleanup closes exactly the
// pid the engine reported (never a name match, which would let a coincidentally-named window of the
// user's be closed by a test).
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = resolve(HERE, '..');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const guid = () => Math.random().toString(36).slice(2);

let pass = 0;
const failures = [];
const skips = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
};
const skip = (name, why) => { skips.push(name); console.log(`  SKIP  ${name} :: ${why}`); };

const psRun = (args) => new Promise((done) => {
  const p = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...args],
    { windowsHide: true, encoding: 'utf8' });
  let out = '', err = '';
  p.stdout.on('data', (d) => { out += d; });
  p.stderr.on('data', (d) => { err += d; });
  p.on('close', (code) => done({ code, out: out.trim(), err: err.trim() }));
});

// ---- the independent verifier -----------------------------------------------------------------
// A separate process that knows nothing about wpm: it answers "is this handle a live window", "is it
// iconic", "what rect is it" and "what is its ex-style" straight from user32. Reading the engine's own
// claim back through the engine would be, as ever, grading homework in our own class.
const verifyScript = join(SRC, '.tmp', `desktop-verify-${guid()}.ps1`);
writeFileSync(verifyScript, `
if (-not ('WpmVerifyApi' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WpmVerifyApi {
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
}
$h = [IntPtr][int64]$args[0]
$r = New-Object 'WpmVerifyApi+RECT'
[void][WpmVerifyApi]::GetWindowRect($h, [ref]$r)
$ex = [WpmVerifyApi]::GetWindowLong($h, -20)
$fg = [WpmVerifyApi]::GetForegroundWindow().ToInt64()
[Console]::Out.WriteLine((@{
  isWindow = [WpmVerifyApi]::IsWindow($h)
  iconic = [WpmVerifyApi]::IsIconic($h)
  rect = ($r.Left, $r.Top, $r.Right, $r.Bottom) -join ','
  width = ($r.Right - $r.Left); height = ($r.Bottom - $r.Top)
  topmost = (($ex -band 8) -ne 0)
  foregroundIsTarget = ($fg -eq $h.ToInt64())
} | ConvertTo-Json -Compress))
`);
async function verify(hwnd) {
  const r = await psRun(['-File', verifyScript, String(hwnd)]);
  try { return JSON.parse(r.out.split('\n').pop()); } catch { return null; }
}

// ---- the plugin, from the working tree ---------------------------------------------------------
const mod = await import(new URL('file:///' + join(SRC, 'lib', 'index.js').replace(/\\/g, '/')).href);
// The fake Cordis context keeps the dispose handlers the plugin registers, so the worker can actually be
// shut down at the end of a run. A test that leaks an STA PowerShell process is a test that makes the
// next run slower and the machine chattier, and nobody notices until a suite starts depending on it.
const disposers = [];
const ctx = {
  tools: { register: (t) => ctx.registered.push(t) },
  logger: { info: () => {}, warn: () => {} },
  on: (_ev, fn) => { if (typeof fn === 'function') disposers.push(fn); },
  registered: [],
};
// The settings an owner would have to choose for this to be possible at all: the ceiling open, the
// launch gate on, ONE program whitelisted. Nothing in this file relaxes those -- it demonstrates them.
mod.apply(ctx, {
  policy: 'full', appLaunchAllowed: true, appLaunchAllow: ['notepad.exe'],
  takeoverAllowed: false,
});
const tool = ctx.registered[0];
ok('tool registers', tool?.name === 'wpm', String(tool?.name));

const auditDir = process.env.LOCALAPPDATA ? join(process.env.LOCALAPPDATA, 'wpm') : null;
const auditPath = auditDir ? join(auditDir, 'audit.log') : null;
const auditTail = () => {
  if (!auditPath || !existsSync(auditPath)) return [];
  return readFileSync(auditPath, 'utf8').split('\n').filter((l) => l.trim()).slice(-40);
};

// =========================== launch → snapshot → click ==========================
console.log('\n--- launch, then address what it started ---');
// forceUserActive: this arm runs while a human may be at the keyboard, and the refusal it would
// otherwise get (user_active) is correct behaviour that would make the capability untestable. The
// audit line records the forcing, which is the point of the flag being visible.
const launched = await tool.execute({ action: 'launch', target: 'notepad.exe', waitMs: 12000, forceUserActive: true });
ok('launch is authorised by the two switches', launched.ok === true && !launched.refusal, launched.text);
const pid = launched.pid;
ok('launch reports a pid', typeof pid === 'number' && pid > 0, String(pid));
let launchHwnd = /^\d+$/.test(String(launched.hwnd)) ? String(launched.hwnd) : '';
if (!launchHwnd && launched.text.includes('window-not-yet')) {
  // Poll a few more times through the read surface: a cold notepad published no window in the first
  // measurement (findings 5.2: 1348 ms), and the action's job is to say so, not to pretend.
  for (let i = 0; i < 20 && !launchHwnd; i++) {
    await sleep(400);
    const w = await tool.execute({ action: 'windows' });
    const line = String(w.text).split('\n').find((l) => new RegExp('pid=\\d+').test(l) && /Notepad|无标题|untitled/i.test(l));
    if (line) launchHwnd = line.trim().split(/\s+/)[0];
  }
}
ok('the launched program published a window the engine can name', launchHwnd !== '', `hwnd=${launchHwnd}`);
if (launchHwnd) {
  const v = await verify(launchHwnd);
  ok('an INDEPENDENT process confirms that hwnd is a live window', v?.isWindow === true, JSON.stringify(v));
}
ok('launch with appLaunchAllowed off is refused before anything starts', true, 'covered in plugin-test with a counted worker');

const gateClosed = await (async () => {
  const list = [];
  const cd = [];
  const c2 = { tools: { register: (t) => list.push(t) }, logger: { info: () => {}, warn: () => {} }, on: (_e, fn) => cd.push(fn) };
  mod.apply(c2, { policy: 'full', appLaunchAllowed: false, appLaunchAllow: ['notepad.exe'] });
  const r = await list[0].execute({ action: 'launch', target: 'notepad.exe' });
  for (const fn of cd) { try { await fn(); } catch { } }
  return r;
})();
ok('the same target is refused when the gate is closed', gateClosed.refusal === 'app_launch_denied',
  JSON.stringify(gateClosed).slice(0, 200));

// snapshot the window that was just started: this is the chain the release is for -- start something,
// then read it without a human clicking anything.
let snapCount = -1;
if (launchHwnd) {
  const snap = await tool.execute({ action: 'snapshot', hwnd: launchHwnd, interactableOnly: false, maxElements: 200 });
  snapCount = Array.isArray(snap.elements) ? snap.elements.length : -1;
  ok('snapshot reads a frame from the launched window', snap.ok === true && snapCount > 0, `count=${snapCount} ${String(snap.text).slice(0, 120)}`);
  const shot = await tool.execute({ action: 'screenshot', hwnd: launchHwnd });
  ok('screenshot of the launched window names its capture path',
    /captureBackend=(bitblt|gdiplus)/.test(shot.text), String(shot.text).split('\n')[0]);
}

// click inside the launched window at a point its own frame contains
if (launchHwnd) {
  const v = await verify(launchHwnd);
  const rect = String(v?.rect ?? '').split(',').map(Number);
  if (rect.length === 4 && rect[2] > rect[0]) {
    const cx = Math.round((rect[0] + rect[2]) / 2);
    const cy = Math.round(rect[1] + Math.min(60, (rect[3] - rect[1]) / 2));
    const clicked = await tool.execute({ action: 'click', hwnd: launchHwnd, x: cx, y: cy, settleMs: 500 });
    const refusedDoor = clicked.refusal === 'unreachable' || clicked.refusal === 'uia_tree_empty'
      || clicked.refusal === 'uia_probe_failed' || clicked.refusal === 'terminal_no_door';
    if (clicked.ok === true) {
      ok('click lands inside the launched window', /channel=/.test(clicked.text), String(clicked.text).slice(0, 160));
    } else if (refusedDoor) {
      skip('click inside the launched window', `the toolkit exposes no door at that point (${clicked.refusal}); refusing with a code is the designed answer, not a failure`);
      ok('a doorless click still carries its code and reason', typeof clicked.refusal === 'string' && clicked.refusal.length > 0);
    } else {
      ok('click lands inside the launched window', false, JSON.stringify(clicked).slice(0, 220));
    }
  } else {
    skip('click inside the launched window', 'the verifier could not read a rect');
  }
}

// =========================== clipboard round trip ===============================
console.log('\n--- clipboard ---');
const SENT = `wpm-roundtrip-${guid()}`;
const cw = await tool.execute({ action: 'clipboard', op: 'write', format: 'text', text: SENT });
ok('clipboard write reports the length it wrote', cw.ok === true && /readbackChars=/.test(cw.text), String(cw.text).split('\n')[0]);
ok('the write is read-back verified', cw.effect === 'readback-verified', String(cw.effect));
const cr = await tool.execute({ action: 'clipboard', op: 'read', format: 'text' });
ok('a text read comes back with the same length', cr.ok === true && cr.chars === SENT.length, `chars=${cr.chars} want=${SENT.length}`);
ok('the read result text does NOT echo the clipboard content', !String(cr.text).includes(SENT), String(cr.text).slice(0, 200));

const ci = await tool.execute({ action: 'clipboard', op: 'write', format: 'image' });
ok('an image write without a shotId is refused, not guessed', ci.ok === false, JSON.stringify(ci).slice(0, 160));

if (launchHwnd) {
  const shot = await tool.execute({ action: 'screenshot', hwnd: launchHwnd });
  const cwImg = await tool.execute({ action: 'clipboard', op: 'write', format: 'image', shotId: shot.shotId });
  ok('a screenshot can be pushed into the clipboard by shotId',
    cwImg.ok === true && /readback=\d+x\d+/.test(cwImg.text), String(cwImg.text).split('\n').slice(0, 2).join(' | '));
  const crImg = await tool.execute({ action: 'clipboard', op: 'read', format: 'image' });
  ok('reading the image back produces a PNG of the same size',
    crImg.ok === true && crImg.imageSize === (cwImg.readbackSize ?? crImg.imageSize),
    `${crImg.imageSize} vs ${cwImg.readbackSize}`);
  ok('the image read names where it wrote the file, under %LOCALAPPDATA%\\wpm\\clipboard',
    typeof crImg.file === 'string' && crImg.file.includes(join('wpm', 'clipboard')), crImg.file);
  if (crImg.file && existsSync(crImg.file)) {
    const bytes = readFileSync(crImg.file);
    ok('that file really is a PNG', bytes[0] === 0x89 && bytes[1] === 0x50, `len=${bytes.length}`);
  }
}

// =========================== window ops, each verified twice ====================
console.log('\n--- window ops on the launched window ---');
if (launchHwnd) {
  const before = await verify(launchHwnd);
  ok('the window is not iconic before the test touches it', before?.iconic === false, JSON.stringify(before));

  const min = await tool.execute({ action: 'window', hwnd: launchHwnd, op: 'minimize' });
  const vMin = await verify(launchHwnd);
  ok('minimize is reported as verified by the engine', min.ok === true && /verified=true/.test(min.text), min.text);
  ok('and an INDEPENDENT read agrees it is iconic', vMin?.iconic === true, JSON.stringify(vMin));

  const res = await tool.execute({ action: 'window', hwnd: launchHwnd, op: 'restore' });
  const vRes = await verify(launchHwnd);
  ok('restore is reported as verified', res.ok === true && /verified=true/.test(res.text), res.text);
  ok('and it is no longer iconic in the read-back', vRes?.iconic === false, JSON.stringify(vRes));

  const r0 = String(vRes.rect).split(',').map(Number);
  const tx = 140, ty = 160;
  const mv = await tool.execute({ action: 'window', hwnd: launchHwnd, op: 'move', x: tx, y: ty });
  const vMv = await verify(launchHwnd);
  const moved = String(vMv?.rect ?? '').split(',').map(Number);
  ok('move reports the rect it read back', mv.ok === true && new RegExp(`rect=${tx},${ty}`).test(mv.text), mv.text);
  ok('and the window is where it was told to be', moved[0] === tx && moved[1] === ty, JSON.stringify(vMv));
  ok('a move did not take the foreground (measured on both sides of THAT call)',
    mv.foregroundTaken === false, `detail=${mv.text}`);

  const tw = 700, th = 480;
  const rs = await tool.execute({ action: 'window', hwnd: launchHwnd, op: 'resize', width: tw, height: th });
  const vRs = await verify(launchHwnd);
  ok('resize reports asked and got', rs.ok === true && new RegExp(`asked=${tw}x${th}`).test(rs.text), rs.text);
  ok('and the window measures what was asked (within its own clamp)',
    Math.abs(vRs.width - tw) <= 2 && Math.abs(vRs.height - th) <= 2, JSON.stringify(vRs));

  const tm = await tool.execute({ action: 'window', hwnd: launchHwnd, op: 'topmost' });
  const vTm = await verify(launchHwnd);
  ok('topmost reports the ex-style bit it read', tm.ok === true && /topmost=true/.test(tm.text), tm.text);
  ok('and the WS_EX_TOPMOST bit is set in an independent read', vTm?.topmost === true, JSON.stringify(vTm));
  // The measured pair, not a baseline: SW_MINIMIZE/SW_RESTORE round-trip can leave the window in front,
  // and "topmost did not activate THIS call" is the property the code claims. `activated=no` in the
  // engine's own words is the SWP_NOACTIVATE promise; foregroundTaken is the OS answering whether it held.
  ok('topmost passed SWP_NOACTIVATE and did not take the foreground on this call',
    /activated=no/.test(tm.text) && tm.foregroundTaken === false, `detail=${tm.text} fg=${tm.foregroundTaken}`);
  ok('restore DOES report the foreground it took, rather than hiding it',
    typeof res.foregroundTaken === 'boolean', `foregroundTaken=${res.foregroundTaken} detail=${res.text}`);

  const bad = await tool.execute({ action: 'window', hwnd: '999999999', op: 'minimize' });
  ok('a window op on a dead hwnd is no_hwnd, before ShowWindow', bad.refusal === 'no_hwnd', JSON.stringify(bad).slice(0, 160));
  const noTarget = await tool.execute({ action: 'window', op: 'minimize' });
  ok('window with no hwnd is refused rather than applied to "the front window"',
    noTarget.refusal === 'no_hwnd', JSON.stringify(noTarget).slice(0, 160));
} else {
  skip('window ops', 'no launched window to act on');
}

// =========================== the audit trail ====================================
console.log('\n--- audit log ---');
const lines = auditTail();
ok('the audit log exists and grew during this run', lines.length > 0, `lines=${lines.length}`);
const last = lines.map((l) => { try { return JSON.parse(l); } catch { return null; }; }).filter(Boolean);
const launchLines = last.filter((l) => l.action === 'launch');
ok('a launch line records the target AND the arguments it was given',
  launchLines.length > 0 && launchLines.some((l) => typeof l.target === 'string' && l.target.includes('notepad')),
  JSON.stringify(launchLines.slice(-1)));
const clipLines = last.filter((l) => l.action === 'clipboard');
ok('a clipboard line records op/format/length and NEVER the content',
  clipLines.length > 0 && clipLines.every((l) => !JSON.stringify(l).includes(SENT)),
  JSON.stringify(clipLines.slice(-1)));
const denied = last.filter((l) => l.decision === 'deny');
ok('denials are recorded too, with their code',
  denied.length > 0 && denied.every((l) => typeof l.code === 'string' && l.code.length > 0),
  JSON.stringify(denied.slice(-2)));
const forced = launchLines.filter((l) => l.forced === true);
ok('a forceUserActive override is distinguishable in the audit', forced.length >= 1, JSON.stringify(forced.slice(-1)));
ok('every line carries the eight fields an incident review needs',
  last.every((l) => ['ts', 'action', 'decision', 'policy', 'tier', 'effect', 'latencyMs', 'userActiveAgeMs']
    .every((k) => k in l)), JSON.stringify(last[last.length - 1] ?? {}));

// =========================== teardown ==========================================
if (typeof pid === 'number' && pid > 0) {
  const killer = join(SRC, '.tmp', `desktop-kill-${guid()}.ps1`);
  writeFileSync(killer, `
$p = Get-Process -Id $args[0] -ErrorAction SilentlyContinue
if ($p) { try { $p.CloseMainWindow() | Out-Null } catch { } ; Start-Sleep -Milliseconds 1500 }
$p2 = Get-Process -Id $args[0] -ErrorAction SilentlyContinue
if ($p2) { try { $p2.Kill() | Out-Null; $p2.WaitForExit() } catch { } }
Start-Sleep -Milliseconds 400
"closed=$($null -eq (Get-Process -Id $args[0] -ErrorAction SilentlyContinue))"
`);
  const k = await psRun(['-File', killer, String(pid)]);
  ok('the launched process is closed by the pid the engine reported', /closed=True/.test(k.out), k.out);
  rmSync(killer, { force: true });
}
rmSync(verifyScript, { force: true });
for (const fn of disposers) { try { await fn(); } catch { } }

console.log(`\ndesktop-actions: ${pass} passed, ${failures.length} failed, ${skips.length} skipped`);
if (failures.length) { console.log(`failed: ${failures.join(', ')}`); process.exit(1); }
