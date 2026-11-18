#!/usr/bin/env node
// reach-matrix.mjs — driver for the coverage gate (P0 / task_4) and the skeleton that
// test/e2e/parallel-proof.mjs (task_28) reuses.
//
// WHY ONE PROCESS HOLDS THE TARGETS. The shell wrapper on this host kills a command's
// entire process tree when the command exits. A window opened by a separate launch
// command is therefore gone before any act command can touch it, and a vanished window
// scores 'absent' -- the same code as 'this app ignores PostMessage'. Those mean opposite
// things, so PowerShell runs in a long-lived `resident` phase that opens the targets,
// waits, injects on command, then cleans up. Handshake files carry the sequencing.
//
// WHY THE PHASES ARE ORDERED THIS WAY. Launching an app steals the foreground; injecting
// into a window must not. Mixing them makes the result uninterpretable, so:
//   resident opens targets -> settle (focus calms on its own) -> sampler starts
//   -> resident injects    -> sampler stops                   -> resident cleans up
//
// Usage: node scripts/reach-matrix.mjs [--hz 20] [--settle 3000] [--out file.json]
//        node scripts/reach-matrix.mjs --cleanup-only
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync, openSync, statSync, closeSync, readSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const PS = join(ROOT, 'scripts', 'probe-reach.ps1');
const WORKER = join(ROOT, 'scripts', 'probe-worker.ps1');
const STATE = join(homedir(), '.dsh', 'windows-parallel-mcp');
const PROOF = join(STATE, 'proof');
const TARGETS = join(STATE, 'targets.json');
mkdirSync(PROOF, { recursive: true });

const F = {
  ready: join(tmpdir(), 'wpm-resident-ready'),
  act: join(tmpdir(), 'wpm-resident-act'),
  result: join(tmpdir(), 'wpm-resident-result.json'),
  done: join(tmpdir(), 'wpm-resident-done'),
  stop: join(STATE, 'stop'),
  log: join(STATE, 'resident.log'),
};

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : d; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const touch = (p) => writeFileSync(p, String(Date.now()));

function ps1(extra, opts = {}) {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', PS, ...extra, '-TargetsFile', TARGETS], { encoding: 'utf8', windowsHide: true, maxBuffer: 32 * 1024 * 1024, ...opts });
  const txt = (r.stdout || '').trim();
  if (!txt) throw new Error('powershell ' + extra.join(' ') + ': no output; stderr ' + (r.stderr || '').slice(0, 500));
  try { return JSON.parse(txt); } catch { throw new Error('powershell output not JSON: ' + txt.slice(0, 400)); }
}

function startResident() {
  const args = ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', PS, '-Phase', 'resident', '-TargetsFile', TARGETS,
    '-ReadyFile', F.ready, '-ActFile', F.act, '-ResultFile', F.result, '-DoneFile', F.done];
  const logFd = openSync(F.log, 'w');
  const child = spawn('powershell.exe', args, { stdio: ['ignore', 'ignore', logFd], windowsHide: true });
  const st = { child, exitCode: null };
  child.on('exit', (c) => { st.exitCode = c; });
  child.on('error', (e) => { st.exitCode = 'spawn-error:' + e.message; });
  st.tail = () => (existsSync(F.log) ? readFileSync(F.log, 'utf8').slice(-700) : '');
  return st;
}

function startSampler(hz) {
  const out = join(PROOF, `probe-${Date.now()}.jsonl`);
  const errFd = openSync(out + '.err', 'a');
  const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', WORKER, '-Hz', String(hz), '-DurationMs', '0', '-Out', out, '-StopFile', F.stop],
    { stdio: ['ignore', 'ignore', errFd], windowsHide: true });
  return { child, out, errFile: out + '.err' };
}

function tailHas(file, re) {
  try {
    const size = statSync(file).size;
    if (!size) return false;
    const n = Math.min(size, 512);
    const fd = openSync(file, 'r');
    try { const b = Buffer.alloc(n); readSync(fd, b, 0, n, size - n); return re.test(b.toString('utf8')); }
    finally { closeSync(fd); }
  } catch { return false; }
}

async function stopSampler(s) {
  touch(F.stop);
  const deadline = Date.now() + 9000;
  let graceful = false;
  while (Date.now() < deadline) { if (tailHas(s.out, /#done\s/)) { graceful = true; break; } await sleep(120); }
  if (!graceful) { try { s.child.kill(); } catch {} }
  const rows = readFileSync(s.out, 'utf8').split('\n').filter((l) => l.trim() && !l.trim().startsWith('#'));
  return { rows, graceful, file: s.out };
}

// Kept here so the driver can be read standalone; the authoritative rules are in
// src/kernel/proof.ts and this mirrors only the measurement plumbing.
function summarizeRows(rows) {
  const r = rows.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  if (r.length < 2) return { samples: r.length, error: 'insufficient samples' };
  let maxD = 0, fg = 0, fc = 0, unexplained = 0, unexplainedMax = 0, physEvents = 0, quietMs = 0;
  const lii = (x) => (typeof x.inputAgeMs === 'number' && x.inputAgeMs >= 0 ? x.ts - x.inputAgeMs : null);
  const fgEvents = [];
  for (let i = 1; i < r.length; i++) {
    const a = r[i], b = r[i - 1];
    const gap = a.ts - b.ts;
    const ea = lii(b), eb = lii(a);
    const human = ea !== null && eb !== null && eb > ea + Math.max(2, gap * 0.6);
    if (human) physEvents++; else quietMs += gap;
    const d = Math.hypot(a.cx - b.cx, a.cy - b.cy);
    if (d > maxD) maxD = d;
    if (!human && d > 0.5) { unexplained += d; if (d > unexplainedMax) unexplainedMax = d; }
    if (a.fg !== b.fg) { fg++; fgEvents.push({ at: a.ts, from: b.fg, to: a.fg, human }); }
    if (a.focus !== b.focus) fc++;
  }
  return {
    samples: r.length,
    windowMs: r[r.length - 1].ts - r[0].ts,
    cursorMaxDeltaPx: Math.round(maxD * 100) / 100,
    foregroundSwitches: fg,
    foregroundEvents: fgEvents.slice(0, 15),
    focusChanges: fc,
    physicalInputEvents: physEvents,
    quietMs,
    unexplainedCursorPathPx: Math.round(unexplained * 100) / 100,
    unexplainedCursorMaxDeltaPx: Math.round(unexplainedMax * 100) / 100,
    first: r[0], last: r[r.length - 1],
  };
}

async function loadKernel() {
  for (const p of ['../src/kernel/proof.js', '../src/kernel/proof.mjs']) {
    try { return await import(new URL(p, import.meta.url).href); } catch {}
  }
  return null;
}

async function main() {
  const hz = Number(opt('hz', 20));
  const settle = Number(opt('settle', 3000));

  if (argv.includes('--cleanup-only')) {
    console.log(JSON.stringify(ps1(['-Phase', 'cleanup']), null, 2));
    return 0;
  }

  for (const k of ['ready', 'act', 'result', 'done', 'stop']) { try { rmSync(F[k], { force: true }); } catch {} }

  const resident = startResident();
  let sampler = null;
  let failure = null;
  try {
    const rd = Date.now() + 120000;
    while (Date.now() < rd && !existsSync(F.ready) && resident.exitCode === null) await sleep(200);
    if (!existsSync(F.ready)) throw new Error('resident never became ready (exit=' + resident.exitCode + ') log=' + resident.tail());

    const payload = JSON.parse(readFileSync(TARGETS, 'utf8'));
    const live = payload.targets.filter((t) => t.hwnd && t.hwnd !== '0');
    console.error(`[resident] ${payload.targets.length} targets, ${live.length} live: ${live.map((t) => t.id).join(', ')}`);
    if (!live.length) throw new Error('no target window survived launch; every cell would score absent');

    await sleep(settle);

    sampler = startSampler(hz);
    const boot = Date.now() + 8000;
    while (Date.now() < boot && !existsSync(sampler.out)) await sleep(120);
    if (!existsSync(sampler.out)) throw new Error('sampler never created its record: ' + readFileSync(sampler.errFile, 'utf8').slice(0, 400));
    // Verify the instrument is recording BEFORE injecting. An unverified sampler turns a
    // whole measurement window into a silent false PASS.
    const warm = Date.now() + 8000;
    while (Date.now() < warm && statSync(sampler.out).size < 300) await sleep(120);
    if (statSync(sampler.out).size < 300) throw new Error('sampler record stayed empty -- instrument not working');

    touch(F.act);
    const ar = Date.now() + 240000;
    while (Date.now() < ar && !existsSync(F.result) && resident.exitCode === null) await sleep(200);
    if (!existsSync(F.result)) throw new Error(`no act result (resident exit=${resident.exitCode}) log=${resident.tail()}`);

    const act = JSON.parse(readFileSync(F.result, 'utf8'));
    const stopped = await stopSampler(sampler);
    const probe = summarizeRows(stopped.rows);
    if (probe.error) throw new Error('sampler died mid-run: ' + probe.error);

    const K = await loadKernel();
    const verdict = K && K.evaluateProof
      ? K.evaluateProof({ samples: stopped.rows, actions: act.cells, expectActions: act.cells.length })
      : { deferred: true, reason: 'kernel/proof.ts not built yet (task_15): raw numbers only, no verdict' };

    const out = {
      generatedAt: new Date().toISOString(),
      samplerStoppedGracefully: stopped.graceful,
      samplerFile: stopped.file,
      targets: payload.targets,
      probe, matrix: act, verdict,
    };
    const f = opt('out');
    if (f) writeFileSync(f, JSON.stringify(out, null, 2));
    console.log(JSON.stringify(out, null, 2));
  } catch (e) {
    failure = e;
  } finally {
    if (sampler) { try { sampler.child.kill(); } catch {} }
    touch(F.done);
    const d = Date.now() + 90000;
    while (Date.now() < d && resident.exitCode === null) await sleep(250);
    if (resident.exitCode === null) { try { resident.child.kill(); } catch {} }
  }
  if (failure) { console.error('DRIVER FAIL: ' + (failure.stack || failure.message)); return 1; }
  return 0;
}

main().then((c) => process.exit(c), (e) => { console.error('DRIVER FAIL: ' + (e && e.stack || e)); process.exit(1); });
