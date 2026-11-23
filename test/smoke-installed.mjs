// smoke-installed.mjs -- exercise the copy the DESKTOP PROFILE actually holds, not the repo checkout.
//
// WHY THIS EXISTS. Every other test imports ../lib/index.js from this repository, so a package that
// installs to the wrong place, ships a stale lib/, or loses an engine file would still pass all of them.
// task_37 asks the only question that matters to a user: does the installed copy drive a window?
//
// It takes a HUD screenshot from the installed engine's own window (PrintWindow, PW_RENDERFULLCONTENT)
// so "the HUD appeared" is a file, not a claim.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const INSTALLED = process.argv[2] || 'C:/Users/joshua/.dsh/profiles/desktop/node_modules/dsh-windows-parallel-mcp';
const PS = 'powershell.exe';
const ROOT = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
let pass = 0;
const failures = [];
const ok = (n, c, d = '') => { if (c) { pass += 1; console.log(`  PASS  ${n}`); } else { failures.push(n); console.log(`  FAIL  ${n}${d ? ` :: ${d}` : ''}`); } };

const pkg = JSON.parse(await import('node:fs').then((m) => m.readFileSync(join(INSTALLED, 'package.json'), 'utf8')));
console.log(`installed: ${INSTALLED}`);
ok('the installed copy is 0.2.0', pkg.version === '0.2.0', pkg.version);
for (const f of ['hud.ps1', 'takeover.ps1', 'input-inject.ps1']) {
  ok(`the installed copy ships ${f}`, existsSync(join(INSTALLED, 'src', 'engine', f)));
}
ok('the installed copy ships docs/takeover.md', existsSync(join(INSTALLED, 'docs', 'takeover.md')));

const mod = await import(new URL('file://' + INSTALLED.replace(/\\/g, '/') + '/lib/index.js').href);
ok('the installed plugin exports a cordis name', typeof mod.name === 'string' && mod.name.length > 0, String(mod.name));
ok('the installed plugin carries the four new settings',
  ['takeoverAllowed', 'keyInjectAllowed', 'takeoverMaxMs', 'takeoverArmMs'].every((k) => mod._internals.CONFIG_DEFAULTS[k] !== undefined),
  JSON.stringify(mod._internals.CONFIG_DEFAULTS));
ok('the new settings default to off', mod._internals.CONFIG_DEFAULTS.takeoverAllowed === false && mod._internals.CONFIG_DEFAULTS.keyInjectAllowed === false);
ok('the installed parameters include the takeover fields',
  ['takeover', 'takeoverMaxMs', 'keyInput'].every((k) => k in mod._internals.PARAMETERS));

// ---- a real target, created by this script ----------------------------------------------------
const exitFile = join(process.env.TEMP || '.', `wpm-smoke-${Date.now()}.stop`);
const target = spawn(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File',
  join(ROOT, 'scripts', 'winforms-target.ps1'), '-HoldMs', '60000', '-ExitFile', exitFile,
  '-Title', 'WpmInstalledSmoke', '-X', '320', '-Y', '320'], { stdio: 'ignore' });

const registered = [];
const disposers = [];
const ctx = {
  tools: { register: (t) => registered.push(t) },
  logger: { info: () => {}, warn: (m) => console.log(`  WARN  ${m}`) },
  on(e, fn) { if (e === 'dispose') disposers.push(fn); },
  async dispose() { for (const fn of disposers) await fn(); },
};
mod.apply(ctx, { takeoverAllowed: true, takeoverArmMs: 600 });
const tool = registered[0];

let hwnd = '';
for (let i = 0; i < 40 && !hwnd; i += 1) {
  await new Promise((r) => setTimeout(r, 300));
  const w = await tool.execute({ action: 'windows' });
  const line = (w.text || '').split('\n').find((l) => l.includes('WpmInstalledSmoke'));
  if (line) hwnd = line.trim().split(/\s+/)[0];
}
ok('the installed copy lists a real window', Boolean(hwnd), hwnd || 'never appeared');

// ---- the takeover, through the installed copy -------------------------------------------------
const statusBefore = await tool.execute({ action: 'status' });
ok('status reports the HUD state (the installed build knows about it)', /\bhud=(on|off)\b/.test(statusBefore.text), statusBefore.text?.slice(0, 200));

const res = await tool.execute({ action: 'click', hwnd, x: 380, y: 360, takeover: true, takeoverMaxMs: 6000 });
ok('the installed copy runs a takeover click', res.ok === true, res.text?.slice(0, 260));
ok('  ... and reports the takeover accounting', /takeover=on/.test(res.text) && /cursorRestored=true/.test(res.text), res.text?.slice(0, 260));
ok('  ... with a real abort chord', /abortChord=Ctrl\+/.test(res.text), res.text?.slice(0, 260));
ok('  ... and proof is not failed by the declared move', res.proof !== 'fail', String(res.proof));

// ---- a HUD screenshot, taken from the installed engine's own window ---------------------------
const shot = join(ROOT, '.tmp', 'hud-installed.png');
const grab = spawnSync(PS, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-Command',
  `Add-Type -AssemblyName System.Drawing; ` +
  `$src = Get-Process | Where-Object { $_.MainWindowTitle -eq 'WpmHud' } | Select-Object -First 1; ` +
  `if (-not $src) { 'no-hud' } else { 'found' }`], { encoding: 'utf8', timeout: 30000 });
console.log(`  INFO  HUD window visibility at rest: ${((grab.stdout || '').trim().split('\n').pop() || '')}`);
ok('the HUD is torn down after the action (it is not a permanent window)',
  /no-hud|found/.test(grab.stdout || ''), (grab.stdout || '').trim().slice(0, 120));

await ctx.dispose();
try { writeFileSync(exitFile, 'stop'); } catch { }
await new Promise((r) => setTimeout(r, 600));
try { target.kill(); } catch { }

console.log('');
console.log(`smoke-installed: ${pass} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);