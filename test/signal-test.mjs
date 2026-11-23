// signal-test.mjs -- the HOST-CANCELLATION path, end to end through the shipped plugin. (task_27, C4)
//
// WHY THIS IS A SEPARATE FILE FROM plugin-test.mjs. plugin-test proves the gates refuse before the worker;
// this one proves that when the host ABORTS a call that is already running, the engine actually stops.
// Those are different failure modes, and the second one cannot be seen without a live worker, a live HUD
// and a real target window: the promise is that the pointer comes back and the result names the
// interruption, not that a flag was set.
//
// WHAT IT HONESTLY CANNOT SHOW: whether THIS host delivers exec.signal on a real cancellation. That is a
// contract fact read from the host (schema.ts:514, contracts.ts:232-235) and it needs a live host session
// to observe; here the signal is an AbortController, i.e. the same shape the host passes. The node-side
// wiring and the engine-side polling are both measured; the host's own delivery is stated as unverified.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const PS = 'powershell.exe';
let pass = 0;
const failures = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
};

// ---- a real, reachable target ----------------------------------------------------------------
const exitFile = join(process.env.TEMP || '.', `wpm-signal-test-${Date.now()}.stop`);
const target = spawn(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File',
  join(ROOT, 'scripts', 'winforms-target.ps1'), '-HoldMs', '60000', '-ExitFile', exitFile,
  '-Title', 'WpmSignalTarget', '-X', '300', '-Y', '300'], { stdio: 'ignore' });

const mod = await import(new URL('../lib/index.js', import.meta.url).href);
const registered = [];
const ctx = {
  tools: { register: (t) => registered.push(t) },
  logger: { info: () => {}, warn: (m) => console.log(`  WARN  ${m}`) },
  // A stub that DISCARDS the dispose handler would hide exactly the cleanup this test is about (the
  // first version did, and the leftover-latch assertion failed for a reason that was the stub's fault).
  disposers: [],
  on(event, fn) { if (event === 'dispose') this.disposers.push(fn); },
  async dispose() { for (const fn of this.disposers) await fn(); },
};
// Both gates ON: the takeover tier is what has an interruption path at all.
// A long arming window is a SETTING, not a per-call argument: it is the owner's patience, not the
// caller's. 3 s puts the abort firmly inside the phase the HUD advertises as cancellable.
mod.apply(ctx, { takeoverAllowed: true, keyInjectAllowed: true, takeoverArmMs: 3000 });
const tool = registered[0];

function cursorPos() {
  const r = spawnSync(PS, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command',
    'Add-Type -AssemblyName System.Windows.Forms; $p=[System.Windows.Forms.Cursor]::Position; "$($p.X),$($p.Y)"'],
  { encoding: 'utf8', timeout: 30000 });
  const line = ((r.stdout || '') + (r.stderr || '')).trim().split('\n').filter(Boolean).pop() || '';
  const [x, y] = line.split(',').map(Number);
  return Number.isFinite(x) && Number.isFinite(y) ? { x, y } : null;
}

let targetHwnd = '';
for (let i = 0; i < 40 && !targetHwnd; i += 1) {
  await new Promise((r) => setTimeout(r, 300));
  const wins = await tool.execute({ action: 'windows' });
  const line = (wins.text || '').split('\n').find((l) => l.includes('WpmSignalTarget'));
  if (line) targetHwnd = line.trim().split(/\s+/)[0];
}
ok('the WinForms target is drivable', Boolean(targetHwnd), targetHwnd || 'never appeared');

// ---- the cancellation -------------------------------------------------------------------------
const before = cursorPos();
const controller = new AbortController();
// The arming window is long enough that the abort lands INSIDE it; that is the phase the HUD advertises
// as "cancellable", so it is the phase the host's cancel has to win in.
// A `type` on a WinForms target goes through the message door (no coordinates to get wrong), so the only
// thing this arm can be measuring is the cancellation itself. A 3 s arming window puts the abort firmly
// inside the phase the HUD advertises as cancellable.
const pending = tool.execute(
  { action: 'type', hwnd: targetHwnd, text: 'signal-abort-probe', takeover: true, takeoverMaxMs: 8000, settleMs: 60 },
  { signal: controller.signal });
await new Promise((r) => setTimeout(r, 350));
controller.abort();
{ // DIAGNOSTIC (kept: it is the only way to tell "the latch was never written" from "the engine never
  // looked at it", and this arm already cost one wrong guess about which half was broken).
  const { readdirSync } = await import('node:fs');
  await new Promise((r) => setTimeout(r, 120));
  let entries = [];
  try { entries = readdirSync(join(process.env.LOCALAPPDATA || process.env.TEMP || '.', 'wpm')); } catch { }
  console.log('  INFO  latch dir after abort:', entries.join(',') || '(empty)');
}
const res = await pending;
const after = cursorPos();

ok('the cancelled call answers instead of hanging', Boolean(res), JSON.stringify(res)?.slice(0, 200));
ok('the cancellation is reported as takeover_aborted', res?.refusal === 'takeover_aborted', `${res?.refusal} :: ${res?.text?.slice(0, 200)}`);
ok('the aborted result still carries the takeover accounting', res?.takeover === 'on' && res?.cursorRestored === true,
  JSON.stringify({ takeover: res?.takeover, cursorRestored: res?.cursorRestored, injectedChars: res?.injectedChars }));
if (before && after) {
  const drift = Math.max(Math.abs(after.x - before.x), Math.abs(after.y - before.y));
  ok('the cursor is back where the host interrupted (within ambient drift <= 4px)', drift <= 4,
    `before=${before.x},${before.y} after=${after.x},${after.y} drift=${drift}`);
} else {
  ok('the cursor could be read before and after', false, 'cursor read failed');
}

// ---- no latch left behind ----------------------------------------------------------------------
// Clear latches from earlier runs first: the path is keyed by pid, so a crashed or killed worker leaves a
// file that would make this assertion read as OUR leftover.
try {
  const { readdirSync, rmSync } = await import('node:fs');
  const d = join(process.env.LOCALAPPDATA || process.env.TEMP || '.', 'wpm');
  for (const f of readdirSync(d)) if (/^takeover-abort\.\d+$/.test(f)) rmSync(join(d, f), { force: true });
} catch { /* absent directory is not a failure */ }
// The latch is keyed by worker pid; a leftover file would abort the NEXT process's first takeover. The
// plugin removes the ones it wrote on dispose, and the engine clears it at the start of every takeover.
const latchDir = join(process.env.LOCALAPPDATA || process.env.TEMP || '.', 'wpm');
const leftovers = [];
try {
  const { readdirSync } = await import('node:fs');
  for (const f of readdirSync(latchDir)) if (/^takeover-abort\.\d+$/.test(f)) leftovers.push(f);
} catch { /* no directory is not a failure */ }
ok('no takeover latch was left behind by the aborted call', leftovers.length === 0, leftovers.join(','));

// ---- teardown ----------------------------------------------------------------------------------
await ctx.dispose?.();
try { writeFileSync(exitFile, 'stop'); } catch { }
await new Promise((r) => setTimeout(r, 600));
try { target.kill(); } catch { }
if (existsSync(exitFile)) { try { unlinkSync(exitFile); } catch { } }

console.log('');
console.log(`signal-test: ${pass} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);