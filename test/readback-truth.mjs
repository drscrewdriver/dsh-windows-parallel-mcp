// readback-truth.mjs -- 0.6.0-A's independent oracle test: does `readback-verified` mean what it says?
//
// WHY AN ORACLE AT ALL. `effect=readback-verified` is a claim about an APPLICATION's state, made by
// reading the application through the same window messages that did the writing. A test that compares
// our write to our read grades homework in our own class -- and this repo has already been caught by
// exactly that shape: scripts/winforms-target.ps1 records an incident where WM_CHAR and WM_SETTEXT all
// returned success while WM_GETTEXT kept reporting the original 'abc'. Two opposite conclusions fit that
// evidence, and only the app's own self-report separates them.
//
// So the fixture (scripts/winforms-target.ps1) writes `$edit.Text` -- the live .NET value, read inside
// the owning process by its own timer -- into a state file every 400ms. Every arm here asserts BOTH:
//   (a) the value in our result text equals the value the app reported (the read is truthful), and
//   (b) `effect` follows the agreement between our prediction and that value (the upgrade is earned).
//
// NON-VACUITY, and this is the arm that matters. A predicate that is always true is worth nothing, so
// the run REQUIRES at least one mismatching write: text containing a bare LF into a control that keeps
// its own line-ending convention. If a future change makes every arm read back exactly as predicted,
// this test fails with a message saying the falsification arm stopped falsifying -- rather than passing
// for the wrong reason. That is the same discipline the structural gates apply with --self-test.
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = resolve(HERE, '..');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const guid = () => Math.random().toString(36).slice(2);

let pass = 0;
const failures = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
};
const psRun = (file, args) => new Promise((done) => {
  const p = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file, ...args],
    { windowsHide: true, encoding: 'utf8' });
  let out = '';
  p.stdout.on('data', (d) => { out += d; });
  p.on('close', (code) => done({ code, out: out.trim() }));
});

const title = 'WpmReadbackTarget';
const stateF = join(tmpdir(), `wpm-readback-state-${guid()}.txt`);
const exitF = join(tmpdir(), `wpm-readback-${guid()}.stop`);
const targetScript = join(SRC, 'scripts', 'winforms-target.ps1');

// ---- the tool, from the working tree (this is the half that formats the claim) ----------------
const mod = await import(new URL('file:///' + join(SRC, 'lib', 'index.js').replace(/\\/g, '/')).href);
const registered = [];
const ctx = { tools: { register: (t) => registered.push(t) }, logger: { info: () => {}, warn: () => {} }, on: () => {} };
mod.apply(ctx, {});
const tool = registered[0];
ok('tool registers', tool?.name === 'wpm', String(tool?.name));

const proc = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', targetScript, '-HoldMs', '150000', '-ExitFile', exitF, '-StateFile', stateF,
  '-Title', title, '-X', '140', '-Y', '140'], { windowsHide: true, stdio: 'ignore' });

// ---- find the target and prove the oracle is alive --------------------------------------------
let hwnd = '';
for (let i = 0; i < 60 && !hwnd; i++) {
  await sleep(300);
  const r = await tool.execute({ action: 'windows' });
  const line = String(r.text).split('\n').find((l) => l.includes(title));
  if (line) hwnd = line.trim().split(/\s+/)[0];
}
ok('target window found', /^\d+$/.test(hwnd), `hwnd=${hwnd}`);
const readState = () => {
  if (!existsSync(stateF)) return null;
  const last = readFileSync(stateF, 'utf8').trim().split('\n').pop();
  return last ? last.split('\t') : null;
};
let state = null;
for (let i = 0; i < 40 && !state; i++) { state = readState(); if (!state) await sleep(200); }
ok('app-side oracle is alive', state !== null, `first=${JSON.stringify(state)}`);
if (!hwnd || !state) { console.log('cannot continue without a target and an oracle'); proc.kill(); process.exit(1); }

/** Wait until the app itself reports `expect`, so an assertion never races the app's own commit. */
async function waitApp(expect, budgetMs = 5000) {
  const at = Date.now();
  let seen = null;
  while (Date.now() - at < budgetMs) {
    const s = readState();
    seen = s ? s[0] : null;
    if (seen === expect) return { hit: true, value: seen, waitedMs: Date.now() - at };
    await sleep(80);
  }
  return { hit: false, value: seen, waitedMs: Date.now() - at };
}
/** The value our result text claims the control holds. Delimited by the `readbackLen=` that always
 * follows, because a value may legitimately contain spaces -- a `\S+` capture would silently compare a
 * truncated claim and pass on the prefix. */
function claimedReadback(text) {
  const t = String(text);
  const m = t.match(/ readback=([\s\S]*?) readbackLen=(\d+)/);
  if (m) return { value: m[1], len: Number(m[2]), exact: m[1].length === Number(m[2]) };
  const u = t.match(/ readback=(unavailable|unmodelled[^ ]*)/);
  if (u) return u[1];
  return null;
}

// ---- A1: WM_SETTEXT (replace) -- the simplest agreement --------------------------------------
const a1 = await tool.execute({ action: 'type', hwnd, text: 'Readback-7', replace: true, settleMs: 500 });
ok('A1 replace ok', a1.ok === true && !a1.refusal, a1.text);
const o1 = await waitApp('Readback-7');
ok('A1 the app itself holds what we wrote', o1.hit, `app=${o1.value} waited=${o1.waitedMs}ms`);
ok('A1 our read equals the app report', claimedReadback(a1.text).value === o1.value, `claim=${JSON.stringify(claimedReadback(a1.text))} app=${o1.value}`);
ok('A1 the claim is exact, not prefix-truncated', claimedReadback(a1.text).exact === true, JSON.stringify(claimedReadback(a1.text)));
ok('A1 effect=readback-verified', /effect=readback-verified/.test(a1.text), a1.text);
ok('A1 proof still evaluated (no dimension lost)', /proof=/.test(a1.text), a1.text);

// ---- A2: caretPosition start -- predicted from the control's own selection -------------------
const a2 = await tool.execute({ action: 'type', hwnd, text: 'XY', caretPosition: 'start', settleMs: 500 });
const expect2 = 'XYReadback-7';
const o2 = await waitApp(expect2);
ok('A2 caret=start inserted at 0 (app-side)', o2.hit, `app=${o2.value} expect=${expect2}`);
ok('A2 our read equals the app report', claimedReadback(a2.text).value === o2.value, `claim=${JSON.stringify(claimedReadback(a2.text))} app=${o2.value}`);
ok('A2 effect=readback-verified', /effect=readback-verified/.test(a2.text), a2.text);
ok('A2 the applied selection is reported, not assumed', /applied=0,0/.test(a2.text), a2.text);

// ---- A3: caretPosition end -- the mapping that -1 does NOT provide ---------------------------
const a3 = await tool.execute({ action: 'type', hwnd, text: 'ZK', caretPosition: 'end', settleMs: 500 });
const expect3 = expect2 + 'ZK';
const o3 = await waitApp(expect3);
ok('A3 caret=end appended (app-side)', o3.hit, `app=${o3.value} expect=${expect3}`);
ok('A3 our read equals the app report', claimedReadback(a3.text).value === o3.value, `claim=${JSON.stringify(claimedReadback(a3.text))} app=${o3.value}`);
ok('A3 effect=readback-verified', /effect=readback-verified/.test(a3.text), a3.text);
// THE TAUTOLOGY CHECK. An engine that guessed "append" would have been right here, so this arm alone
// proves nothing; A2 is the arm that would break a naive append model, and A4 breaks everything.
ok('A3 caret=end reports the length it read, not a literal -1', /asked=\d+/.test(a3.text), a3.text);

// ---- A4: THE FALSIFICATION ARM -- a read-only control, through the character path ----------
// Measured 2026-11-23, and the measurement is the interesting part: a read-only WinForms edit refuses
// WM_CHAR silently (every character is accepted by the API, the value never moves) while WM_SETTEXT is
// still honoured -- so "the message worked" and "the field took it" genuinely diverge per message, not
// per control. That is exactly the case `readback-verified` must decline: the delivery report is true,
// our read is true (it equals the app's own self-report), and only the PREDICTION is wrong.
//
// Two earlier candidates were tried and REJECTED by measurement, which is why this arm is what it is:
// a bare LF is preserved verbatim by the control (so it agrees and cannot falsify), and WinForms
// enforces MaxLength in its own WM_CHAR handler rather than through EM_SETLIMITTEXT (so a programmatic
// WM_SETTEXT bypasses the limit and nothing truncates).
const roStateF = join(tmpdir(), `wpm-readback-ro-state-${guid()}.txt`);
const roExitF = join(tmpdir(), `wpm-readback-ro-${guid()}.stop`);
const roTitle = 'WpmReadbackRoTarget';
const roProc = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA',
  '-File', targetScript, '-HoldMs', '150000', '-ExitFile', roExitF, '-StateFile', roStateF,
  '-Title', roTitle, '-ReadOnlyEdit', '-X', '140', '-Y', '420'], { windowsHide: true, stdio: 'ignore' });
const readRoState = () => (existsSync(roStateF)
  ? (readFileSync(roStateF, 'utf8').trim().split('\n').pop() ?? '').split('\t')[0]
  : undefined);
let roHwnd = '';
for (let i = 0; i < 60 && !roHwnd; i++) {
  await sleep(300);
  const r = await tool.execute({ action: 'windows' });
  const line = String(r.text).split('\n').find((l) => l.includes(roTitle));
  if (line) roHwnd = line.trim().split(/\s+/)[0];
}
ok('A4 read-only target window found', /^\d+$/.test(roHwnd), `hwnd=${roHwnd}`);
let roSeed;
for (let i = 0; i < 40 && !(typeof roSeed === 'string' && roSeed.length > 0); i++) { roSeed = readRoState(); if (!(typeof roSeed === 'string' && roSeed)) await sleep(150); }
ok('A4 the read-only oracle is alive and reports its seed', typeof roSeed === 'string' && roSeed.length > 0, `seed=${JSON.stringify(roSeed)}`);

// A4a: the character path -- the one the control refuses.
const a4 = await tool.execute({ action: 'type', hwnd: roHwnd, text: 'xy', caretPosition: 'start', settleMs: 500 });
ok('A4a a refused write is still a success, not a refusal', a4.ok === true && !a4.refusal, a4.text);
ok('A4a no code outside the shipped vocabulary appears', ['', 'no_hwnd', 'paused', 'elevated_target',
  'unreachable', 'uia_tree_empty', 'uia_probe_failed', 'terminal_no_door', 'needs_facts',
  'takeover_unavailable', 'keyinject_unavailable', 'action_failed', 'restore_failed',
  'takeover_aborted', 'stale_ref'].includes(String(a4.refusal ?? '')), String(a4.refusal));
const claim4 = claimedReadback(a4.text);
const app4 = readRoState();
ok('A4a the control really refused (app-side still holds the seed)', app4 === roSeed, `app=${JSON.stringify(app4)} seed=${JSON.stringify(roSeed)}`);
ok('A4a our read equals the app report (the read is truthful)', claim4.value === app4, `claim=${JSON.stringify(claim4)} app=${JSON.stringify(app4)}`);
ok('A4a our read does NOT equal the predicted insertion (the model was the wrong part)',
  claim4.value !== 'xy' + roSeed, `claim=${JSON.stringify(claim4.value)} predicted=${JSON.stringify('xy' + roSeed)}`);
ok('A4a effect is NOT upgraded', !/effect=readback-verified/.test(a4.text), a4.text);
ok('A4a detail carries readbackMismatch=true', /readbackMismatch=true/.test(a4.text), a4.text);

// A4b: the SAME control, the message it does honour. This arm is here so the test cannot pass by
// accident: if the read-only control refused everything, "not upgraded" would prove nothing about the
// model -- it would just mean the field was unreadable. A write that lands on the same control must be
// upgraded, which pins the previous arm's refusal to the prediction and not to the read.
const WANT = 'RO-SETTEXT-LANDS';
const a4b = await tool.execute({ action: 'type', hwnd: roHwnd, text: WANT, replace: true, settleMs: 500 });
const app4b = await (async () => { const at = Date.now(); while (Date.now() - at < 5000) { if (readRoState() === WANT) return WANT; await sleep(80); } return readRoState(); })();
ok('A4b WM_SETTEXT is honoured by the same read-only control (app-side)', app4b === WANT, `app=${JSON.stringify(app4b)}`);
ok('A4b and the effect IS upgraded there', /effect=readback-verified/.test(a4b.text), a4b.text);
ok('A4b our read equals the app report again', claimedReadback(a4b.text).value === app4b,
  `claim=${JSON.stringify(claimedReadback(a4b.text))} app=${JSON.stringify(app4b)}`);

// ---- A5: the disabled arm, through the shipped projection -------------------------------------
// EnableWindow is driven from outside because the fixture has no disabled-window mode. The claim under
// test is the engine's: a disabled target must report disabled=true and lose the right to an effect,
// while staying a SUCCESS (it is a state of the target, not an error in the call -- no new code).
const enabler = join(SRC, '.tmp', `readback-enable-${guid()}.ps1`);
// EnableWindow is declared HERE, by the test, and deliberately NOT added to WpmWin: the product has no
// business enabling or disabling someone else's window, and a primitive that only a test needs must not
// become a syscall the engine can reach. IsWindowEnabled IS product-side (0.6.0 reports `disabled`), so
// the assertion reads through the shipped half and the setup acts through a local one.
writeFileSync(enabler, `
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WpmTestEnable {
    [DllImport("user32.dll")] public static extern bool EnableWindow(IntPtr h, bool e);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
}
"@
$h = [IntPtr][int64]$args[0]
if ($args[1] -eq 'off') { [void][WpmTestEnable]::EnableWindow($h, $false) } else { [void][WpmTestEnable]::EnableWindow($h, $true) }
[Console]::Out.WriteLine([string][WpmTestEnable]::IsWindowEnabled($h))
`);
const off = await psRun(enabler, [hwnd, 'off']);
ok('fixture window was disabled from outside', off.out.trim() === 'False', `IsWindowEnabled=${off.out.trim()}`);
const a5 = await tool.execute({ action: 'type', hwnd, text: 'DISABLED-ARM', replace: true, settleMs: 400 });
ok('A5 a disabled target is still a success, not a refusal', a5.ok === true && !a5.refusal, a5.text);
ok('A5 detail says disabled=true', /disabled=true/.test(a5.text), a5.text);
ok('A5 effect is pinned to unverified', /effect=unverified/.test(a5.text), a5.text);
const on = await psRun(enabler, [hwnd, 'on']);
ok('fixture window was re-enabled', on.out.trim() === 'True', `IsWindowEnabled=${on.out.trim()}`);
rmSync(enabler, { force: true });

// ---- the non-vacuity gate for the whole run ---------------------------------------------------
// At least one arm must have UPGRADED and at least one must have REFUSED to upgrade. A run where every
// single arm upgraded means the comparison stopped being a comparison -- most likely because somebody
// made `readback-verified` a synonym for "the call returned", which is the claim this file exists to
// keep honest.
const upgraded = [a1, a2, a3, a4, a5].filter((r) => /effect=readback-verified/.test(r.text)).length;
const notUpgraded = [a1, a2, a3, a4, a5].filter((r) => !/effect=readback-verified/.test(r.text)).length;
ok('some arms upgraded and some did not (the predicate discriminates)', upgraded >= 1 && notUpgraded >= 1,
  `upgraded=${upgraded} notUpgraded=${notUpgraded}`);
if (!(upgraded >= 1 && notUpgraded >= 1)) {
  console.log('  NOTE  the falsification arm stopped falsifying. Either the fixture changed how it stores');
  console.log('        text (then pick a different reformatting case -- the requirement is a mismatch that');
  console.log('        is real, not a contrived one), or readback-verified became unconditional.');
}

// ---- cleanup ----------------------------------------------------------------------------------
try { writeFileSync(roExitF, 'stop'); } catch { }
try { writeFileSync(exitF, 'stop'); } catch { }
await sleep(1200);
for (const p of [proc, roProc]) { if (!p.killed && p.exitCode === null) p.kill(); }
rmSync(exitF, { force: true });
rmSync(stateF, { force: true });
rmSync(roExitF, { force: true });
rmSync(roStateF, { force: true });
const sweep = await tool.execute({ action: 'windows' });
ok('no readback target survives the run', !String(sweep.text).includes(title) && !String(sweep.text).includes(roTitle));
void ctx;

console.log(`\nreadback-truth: ${pass} passed, ${failures.length} failed`);
if (failures.length) { console.log(`failed: ${failures.join(', ')}`); process.exit(1); }
