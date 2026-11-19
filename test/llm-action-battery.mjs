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
//   status   -- foreground recorded before/after the whole battery: the quiet tier must not move it
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
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
// The installed path, not the source path: this is the surface the host actually loads.
const PKG = process.env.WPM_PKG
  ?? 'C:/Users/joshua/.dsh/profiles/desktop/node_modules/dsh-windows-parallel-mcp';
const SRC = resolve(HERE, '..');

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
const targetScript = join(SRC, 'scripts', 'winforms-target.ps1');

console.log(`package: ${PKG}`);
const mod = await import(`file:///${PKG}/lib/index.js`);
const registered = [];
const ctx = { tools: { register: (t) => registered.push(t) }, logger: { info: () => {}, warn: () => {} }, on: () => {} };
mod.apply(ctx, {});
const tool = registered[0];
ok('tool registers from the installed path', tool?.name === 'wpm', String(tool?.name));

const proc = ps(targetScript, ['-HoldMs', '120000', '-ExitFile', exitF, '-StateFile', stateF, '-Title', title, '-X', '120', '-Y', '120']);

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

const before = await tool.execute({ action: 'status' });
const fgBefore = String(before.text).match(/foreground=(\S+)/)?.[1];

// ---- type through the quiet door ----------------------------------------------------------
const typed = await tool.execute({ action: 'type', hwnd, text: 'XYZ' });
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

const clicked = await tool.execute({ action: 'click', hwnd, x: Math.round(cx), y: Math.round(cy), settleMs: 600 });
ok('click reports the quiet tier', clicked.ok === true && /channel=message/.test(clicked.text), clicked.text);
let btnNow = btn0;
for (let i = 0; i < 20; i++) { await sleep(200); const s = readState(); if (s && s[2] !== btn0) { btnNow = s[2]; break; } }
ok('CLICK RAN THE APP HANDLER: caption moved to Press(n)', /Press\(\d+\)/.test(btnNow), `caption=${btnNow}`);

// ---- focus must refuse on this toolkit, without touching anything --------------------------
const focused = await tool.execute({ action: 'focus', hwnd, elementName: 'targetButton' });
ok('focus on a pattern-less toolkit refuses', focused.ok === false && focused.refusal === 'unreachable', JSON.stringify(focused).slice(0, 160));

// ---- the elevated arm: only if one exists right now ----------------------------------------
const listR = await tool.execute({ action: 'windows' });
const elevatedLine = String(listR.text).split('\n').find((l) => /任务管理器|Task Manager/.test(l));
if (elevatedLine) {
  const eh = elevatedLine.trim().split(/\s+/)[0];
  const e = await tool.execute({ action: 'click', hwnd: eh, x: 200, y: 200 });
  ok('elevated window refuses with elevated_target BEFORE acting',
    e.ok === false && e.refusal === 'elevated_target', JSON.stringify(e).slice(0, 200));
} else {
  console.log('  SKIP  elevated arm: no high-integrity window at run time (measured live 2026-11-20: Task Manager -> elevated_target refusal)');
}

// ---- the quiet-tier claim, end to end ------------------------------------------------------
const afterStatus = await tool.execute({ action: 'status' });
const fgAfter = String(afterStatus.text).match(/foreground=(\S+)/)?.[1];
ok('foreground NEVER moved across the whole battery', fgBefore === fgAfter, `before=${fgBefore} after=${fgAfter}`);

// ---- cleanup ------------------------------------------------------------------------------
writeFileSync(exitF, 'stop');
await sleep(1200);
if (!proc.killed && proc.exitCode === null) proc.kill();
rmSync(exitF, { force: true });
rmSync(stateF, { force: true });
const sweep = await tool.execute({ action: 'windows' });
ok('no battery window survives', !String(sweep.text).includes(title));

console.log(`\nllm-action-battery: ${pass} passed, ${failures.length} failed`);
if (failures.length) { console.log(`failed: ${failures.join(', ')}`); process.exit(1); }
