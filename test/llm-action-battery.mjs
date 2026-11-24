// llm-action-battery.mjs -- every action, driven the way the model drives it, on a real target.
//
// WHY THIS EXISTS. The unit tests prove the pieces; this proves the product path: import the tool
// from the INSTALLED location (the desktop profile's node_modules link), create a real window, and
// verify effects the way the engine's own discipline requires -- from the owning app's state file,
// never from the API's return value. Cross-process read-back was measured blind in this repo
// (WM_GETTEXT lied), so an action battery that trusts `ok:true` would be measuring its own optimism.
//
// ARMS, each falsifiable:
//   windows  -- the target appears with a resolvable hwnd
//   status   -- foreground sampled before AND after each action: no action may leave it somewhere
//               the target does not own. The target itself is allowed (an app may claim focus while
//               handling a message); anything else is a regression, not desktop noise.
//   type     -- app-side state file shows the appended text
//   click    -- button caption becomes Press(1) in the state file (the app's own report its handler ran)
//   focus    -- WinForms exposes no UIA pattern, so naming an element MUST refuse (unreachable),
//               and must refuse WITHOUT touching the desktop
//   elevated -- if a high-integrity window exists right now, click MUST refuse with elevated_target
//               (measured live: Task Manager reads 0x3000 and the engine refuses it before acting)
// Cleanup is part of the test: the target is closed through its own exit file and swept.
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = resolve(HERE, '..');
// THE CHECKOUT BY DEFAULT, the installed copy only when asked for. The original default was the desktop
// profile's node_modules -- "the surface the host actually loads", which is the right thing to want --
// but nothing checked WHICH release sat there, and it sat at 0.2.0 while the repo was 0.8.1. Two arms
// were recorded as baseline failures for weeks on that basis (findings §11.1/§11.4): the battery was
// measuring an old engine, so its red described code nobody was editing and its green would not have
// described the code under review either. The version assertion below is what makes the choice safe.
const PKG = process.env.WPM_PKG ?? SRC;

let pass = 0;
const failures = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ps = (file, args) => spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-File', file, ...args], { windowsHide: true, stdio: 'ignore' });

const guid = () => Math.random().toString(36).slice(2);
const title = 'WpmBatteryTarget';
const stateF = join(tmpdir(), `wpm-battery-state-${guid()}.txt`);
const exitF = join(tmpdir(), `wpm-battery-${guid()}.stop`);
// Signal file the fixture watches: when it appears, the OWNING process brings its window to the
// front and deletes the file. Only the owner may do this -- the foreground lock refuses
// SetForegroundWindow from any other process -- which is why the battery cannot raise it itself.
const reGrabF = join(tmpdir(), `wpm-battery-regrab-${guid()}.signal`);
const targetScript = join(SRC, 'scripts', 'winforms-target.ps1');

// THE SURFACE UNDER TEST MUST BE THIS REPOSITORY'S CODE. A battery that silently measures an older
// install reports failures the current code does not have -- and passes it has not earned.
const repoVersion = JSON.parse(readFileSync(join(SRC, 'package.json'), 'utf8')).version;
const underTest = JSON.parse(readFileSync(join(PKG, 'package.json'), 'utf8')).version;
if (underTest !== repoVersion) {
  console.log('  FAIL  the surface under test is not this repository');
  console.log(`        under test: ${PKG} (${underTest})`);
  console.log(`        this repo:  ${SRC} (${repoVersion})`);
  console.log(`        point WPM_PKG at the checkout, or install ${repoVersion} into the profile first`);
  process.exit(1);
}
console.log(`package: ${PKG} (version ${underTest})`);
const mod = await import(pathToFileURL(join(PKG, 'lib', 'index.js')).href);
const registered = [];
// Collected, not ignored: the tool registers a dispose handler that stops its sidecar. A battery that
// leaves one running leaks a long-lived PowerShell between runs -- and the second consecutive run is
// exactly where a leak of that shape shows up.
const disposers = [];
const ctx = {
  tools: { register: (t) => registered.push(t) },
  logger: { info: () => {}, warn: () => {} },
  on: (event, fn) => { if (event === 'dispose') disposers.push(fn); },
};
mod.apply(ctx, {});
const tool = registered[0];
ok('tool registers from the installed path', tool?.name === 'wpm', String(tool?.name));

const proc = ps(targetScript, ['-HoldMs', '120000', '-ExitFile', exitF, '-StateFile', stateF, '-Title', title, '-X', '120', '-Y', '120', '-ReGrabFile', reGrabF, '-Topmost']);

// A battery that hangs is a battery whose red never arrives. The slowest measured run is about 40s;
// anything past four minutes means a request never settled, and exiting with a named failure beats
// leaving a topmost target on someone's desktop while the harness waits forever.
const hardTimer = setTimeout(() => {
  console.log('  FAIL  the battery did not finish within 240s (a request never settled)');
  try { proc.kill(); } catch { /* already gone */ }
  process.exit(1);
}, 240000);

// ---- find the target ----------------------------------------------------------------------
let hwnd = '';
for (let i = 0; i < 50 && !hwnd; i++) {
  await sleep(400);
  const r = await tool.execute({ action: 'windows' });
  const line = String(r.text).split('\n').find((l) => l.includes(title));
  if (line) hwnd = line.trim().split(/\s+/)[0];
}
ok('windows finds the created target', hwnd !== '' && /^\d+$/.test(hwnd), `hwnd=${hwnd}`);
if (!hwnd) { console.log('cannot continue without a target'); proc.kill(); process.exit(1); }

const readState = () => {
  if (!existsSync(stateF)) return null;
  const last = readFileSync(stateF, 'utf8').trim().split('\n').pop();
  return last ? last.split('\t') : null;
};
let state = null;
for (let i = 0; i < 30 && !state; i++) { state = readState(); if (!state) await sleep(200); }
ok('app-side oracle is alive', state !== null, `state=${JSON.stringify(state)}`);
if (!state) { proc.kill(); process.exit(1); }
const [edit0, rich0, btn0] = state;

// ---- the quiet-tier claim, action by action -------------------------------------------------
// WHY NOT "before the battery / after the battery". That is what this file used to assert, and it
// measured "who holds the foreground at the end" rather than "did we take it": the fixture's own
// Show() activates its window, the OS hands the foreground back on its own schedule, and a click makes
// the application claim focus while handling the message. Measured 2026-11-24 against 0.8.1: the
// end-of-run sample landed on a different window on 3 of 3 runs, and on none of them had the engine
// touched that window.
//
// The claim worth checking is narrower and falsifiable: NO ACTION LEAVES THE FOREGROUND ANYWHERE THE
// TARGET DOES NOT OWN. "The target itself" is allowed because an app may take focus while handling a
// message -- measured: type leaves it alone, click makes the target the foreground and the engine
// says focusTaken=true rather than pretending otherwise.
const fgOf = async () => String((await tool.execute({ action: 'status' })).text).match(/foreground=(\S+)/)?.[1];
const fgJournal = [];
const step = async (name, run) => {
  const before = await fgOf();
  const result = await run();
  const afterFg = await fgOf();
  fgJournal.push(`${name}: ${before} -> ${afterFg}`);
  ok(`foreground after ${name} is unchanged or the target`, afterFg === before || afterFg === hwnd,
    `before=${before} after=${afterFg} target=${hwnd}`);
  return result;
};

// ---- BRING THE TARGET INTO VIEW, BUT NEVER INTO THE FOREGROUND ---------------------------
// The clicking arm needs the button pixels to belong to the target, and the fixture provides that
// with -Topmost: Z-order only, no foreground permission, nothing the foreground lock can refuse.
// That distinction is the whole point -- a background process CANNOT raise itself (measured
// 2026-11-24: the owner's own Grab was refused and the foreground stayed on the browser), and asking
// the engine to click through a covered point was measured to deliver the message and never run the
// application's handler. Visibility is the test's problem to solve; truthfulness about the click is
// the product's promise to keep.

// ---- type through the quiet door ----------------------------------------------------------
const typed = await step('type', () => tool.execute({ action: 'type', hwnd, text: 'XYZ' }));
ok('type reports the quiet tier', typed.ok === true && /channel=message/.test(typed.text), typed.text);
let after = null;
for (let i = 0; i < 25 && !after; i++) { await sleep(200); const s = readState(); if (s && s[0] !== edit0) after = s; }
// The message tier types with WM_CHAR, which INSERTS AT THE CARET -- an unfocused TextBox keeps the
// caret at position 0, so 'XYZ' landed as 'XYZabc', not 'abcXYZ'. The append wording in the first
// version of this assertion was the test's assumption, not the engine's documented behaviour; the
// engine's tool description now says 'insert at the caret' explicitly. What is verified here is
// that the text landed at all -- from the app's own state file, never from the API's answer.
ok('TYPE LANDED IN THE APP: state file contains the inserted text', after !== null && after[0].includes('XYZ'),
  `before=${edit0} after=${after?.[0]}`);

// ---- click the button: coordinates from the child window's own rect -------------------------
// The first version located the button through UIA FindFirst(Name='targetButton') and found
// nothing: WinForms surfaces elements with Name = the VISIBLE CAPTION ('Press') and AutomationId
// = the child hwnd, so a control-Name lookup is a category error on this toolkit. The child window
// HAS a real HWND here, and GetWindowRect works cross-process for geometry (unlike GetWindowText,
// which is the read that was measured blind). Coordinates are a read; the ACTION still goes
// through the message door.
const rectScript = join(SRC, '.tmp', `battery-rect-${guid()}.ps1`);
// Built as one template literal: the earlier array-of-single-quoted-lines form kept colliding with
// PowerShell's own quotes, and a quoting fix in a test is a bug farm. Inside, all PS strings are
// double-quoted and the type name is escaped once.
writeFileSync(rectScript, `
. (Join-Path $PSScriptRoot "..\\src\\engine\\win.ps1")
$h = [IntPtr][int64]$args[0]
foreach ($c in @([WpmWin]::Children($h))) {
  $kc = [WpmWin]::Cls([IntPtr]$c)
  if ($kc -like "WindowsForms10.BUTTON*") {
    $r = New-Object "WpmWin+RECT"
    [void][WpmWin]::GetWindowRect([IntPtr]$c, [ref]$r)
    [Console]::Out.WriteLine([string]([int](($r.Left + $r.Right) / 2)) + "," + [string]([int](($r.Top + $r.Bottom) / 2)))
    exit 0
  }
}
exit 1
`);
const rectOut = await new Promise((done) => {
  const p = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', rectScript, hwnd], { encoding: 'utf8' });
  let out = '';
  p.stdout.on('data', (d) => { out += d; });
  p.on('close', (code) => done(code === 0 ? out.trim().split('\n').pop() : ''));
});
rmSync(rectScript, { force: true });
const [cx, cy] = String(rectOut).split(',').map(Number);
ok('button center resolved from its child-window rect', Number.isFinite(cx) && Number.isFinite(cy), `rect=${rectOut}`);

// ---- the clicking arm, with the target genuinely on top ------------------------------------
const clicked = await step('click', () => tool.execute({ action: 'click', hwnd, x: Math.round(cx), y: Math.round(cy), settleMs: 600 }));
ok('click reports the quiet tier', clicked.ok === true && /channel=message/.test(clicked.text), clicked.text);
let btnNow = btn0;
for (let i = 0; i < 20; i++) { await sleep(200); const s = readState(); if (s && s[2] !== btn0) { btnNow = s[2]; break; } }
ok('CLICK RAN THE APP HANDLER: caption moved to Press(n)', /Press\(\d+\)/.test(btnNow), `caption=${btnNow}`);

// ---- focus must refuse on this toolkit, without touching anything --------------------------
const focused = await step('focus', () => tool.execute({ action: 'focus', hwnd, elementName: 'targetButton' }));
ok('focus on a pattern-less toolkit refuses', focused.ok === false && focused.refusal === 'unreachable', JSON.stringify(focused).slice(0, 160));

// ---- the elevated arm: only if one exists right now ----------------------------------------
const listR = await tool.execute({ action: 'windows' });
const elevatedLine = String(listR.text).split('\n').find((l) => /任务管理器|Task Manager/.test(l));
if (elevatedLine) {
  const eh = elevatedLine.trim().split(/\s+/)[0];
  const e = await step('elevated-refusal', () => tool.execute({ action: 'click', hwnd: eh, x: 200, y: 200 }));
  ok('elevated window refuses with elevated_target BEFORE acting',
    e.ok === false && e.refusal === 'elevated_target', JSON.stringify(e).slice(0, 200));
} else {
  console.log('  SKIP  elevated arm: no high-integrity window at run time (measured live 2026-11-20: Task Manager -> elevated_target refusal)');
}

// ---- what the per-action journal saw --------------------------------------------------------
// Printed, not asserted: the assertions already ran one per action, and this line is what makes a
// future red diagnosable without re-running with a poller attached.
console.log(`  -- foreground journal: ${fgJournal.join(' | ')}`);

// ---- cleanup ------------------------------------------------------------------------------
writeFileSync(exitF, 'stop');
await sleep(1200);
if (!proc.killed && proc.exitCode === null) proc.kill();
rmSync(exitF, { force: true });
rmSync(stateF, { force: true });
rmSync(reGrabF, { force: true });
const sweep = await tool.execute({ action: 'windows' });
ok('no battery window survives', !String(sweep.text).includes(title));

clearTimeout(hardTimer);
for (const dispose of disposers) { try { await dispose(); } catch { /* teardown is not a verdict */ } }

console.log(`\nllm-action-battery: ${pass} passed, ${failures.length} failed`);
if (failures.length) { console.log(`failed: ${failures.join(', ')}`); process.exit(1); }
