#!/usr/bin/env node
// proof-probe.mjs — standalone input-state probe for the parallel claim (P0 / task_2).
//
// Runs WITHOUT the plugin: it spawns a PowerShell 5.1 sampler (scripts/probe-worker.ps1)
// that polls GetCursorPos / GetForegroundWindow / GetGUIThreadInfo at a fixed period and
// appends JSONL. The probe observes; it never injects. That asymmetry is the point:
// proof.ts judges a run from this record, so if the measurement tool itself moved the
// cursor or grabbed focus, every PASS below would be worthless.
//
// The sampler writes its own file (not through a pipe) so a detached run survives the
// Node process that started it: a driver can `--start`, do its 50 actions, `--stop`.
//
// Usage:
//   node src/lib/proof-probe.mjs --start [--hz 20] [--tag label]   start background sampler
//   node src/lib/proof-probe.mjs --stop                            stop it, print summary
//   node src/lib/proof-probe.mjs --run --ms 10000 [--tag idle]     self-contained window
//   node src/lib/proof-probe.mjs --summarize <file.jsonl>          evaluate an old record
//   node src/lib/proof-probe.mjs --status                          is a sampler live?
//   node src/lib/proof-probe.mjs --move 300 --ms 3000              self-check: does it see motion
//
// Records: ~/.dsh/windows-parallel-mcp/proof/probe-<ts>.jsonl  (+ .err, live.json, stop)
import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync, rmSync, openSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(homedir(), '.dsh', 'windows-parallel-mcp');
const PROOF_DIR = join(ROOT, 'proof');
const LIVE = join(ROOT, 'live.json');
const STOPFILE = join(ROOT, 'stop');
const WORKER = join(HERE, '..', '..', 'scripts', 'probe-worker.ps1');
mkdirSync(PROOF_DIR, { recursive: true });

const argv = process.argv.slice(2);
const flag = (n) => argv.includes(`--${n}`);
const opt = (n, d) => {
  const i = argv.indexOf(`--${n}`);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function stamp() {
  const d = new Date();
  const p = (v) => String(v).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

function startSampler({ hz, ms, out, background }) {
  const psArgs = ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', WORKER, '-Hz', String(hz), '-DurationMs', String(ms), '-Out', out, '-StopFile', STOPFILE];
  const errFd = openSync(out + '.err', 'a');
  const child = spawn('powershell.exe', psArgs, {
    stdio: ['ignore', 'ignore', errFd],
    detached: background,
    windowsHide: true,
  });
  child.on('error', (e) => { writeFileSync(out + '.spawnerr', String(e && e.message)); });
  return child;
}

export function summarize(lines, { hz = 20 } = {}) {
  const rows = [];
  for (const l of lines) {
    const t = l.trim();
    if (!t || t.startsWith('#')) continue;
    const r = safeJson(t);
    if (r && typeof r.ts === 'number') rows.push(r);
  }
  if (rows.length < 2) return { samples: rows.length, error: 'insufficient samples' };

  // Attribution: GetLastInputInfo gives the timestamp of the last PHYSICAL input. An
  // event between two samples means a human touched the mouse or keyboard in that gap,
  // so any cursor motion / foreground switch there is the human's, not the agent's.
  // Motion with no physical input event in the gap is what the parallel claim forbids.
  const inputEpoch = (r) => (typeof r.inputAgeMs === 'number' && r.inputAgeMs >= 0 ? r.ts - r.inputAgeMs : null);
  let maxDelta = 0, maxDeltaAt = rows[0].ts, maxDx = 0, maxDy = 0, total = 0;
  let unexplainedMaxDelta = 0, unexplainedMaxAt = 0, unexplainedTotal = 0;
  let fgSwitches = 0, fgSwitchesHuman = 0, focusChanges = 0, focusChangesHuman = 0;
  let physicalEvents = 0, humanActiveMs = 0, quietMs = 0;
  const fgSet = new Set();
  for (let i = 1; i < rows.length; i++) {
    const r = rows[i], q = rows[i - 1];
    const gap = r.ts - q.ts;
    const a = inputEpoch(q), b = inputEpoch(r);
    const humanEvent = a !== null && b !== null && b > a + Math.max(2, gap * 0.6);
    if (humanEvent) { physicalEvents++; humanActiveMs += gap; } else { quietMs += gap; }

    const dx = r.cx - q.cx, dy = r.cy - q.cy, d = Math.hypot(dx, dy);
    if (d > maxDelta) { maxDelta = d; maxDeltaAt = r.ts; }
    if (Math.abs(dx) > Math.abs(maxDx)) maxDx = dx;
    if (Math.abs(dy) > Math.abs(maxDy)) maxDy = dy;
    total += d;
    if (!humanEvent && d > 0.5) {
      unexplainedTotal += d;
      if (d > unexplainedMaxDelta) { unexplainedMaxDelta = d; unexplainedMaxAt = r.ts; }
    }
    if (r.fg !== q.fg) { fgSwitches++; if (humanEvent) fgSwitchesHuman++; }
    if (r.focus !== q.focus) { focusChanges++; if (humanEvent) focusChangesHuman++; }
    fgSet.add(r.fg);
  }
  const round = (v) => Math.round(v * 100) / 100;
  return {
    samples: rows.length,
    windowMs: rows[rows.length - 1].ts - rows[0].ts,
    nominalHz: hz,
    cursorMaxDeltaPx: round(maxDelta),
    cursorMaxDeltaAt: maxDeltaAt,
    cursorMaxDx: maxDx, cursorMaxDy: maxDy,
    cursorTotalPathPx: round(total),
    foregroundSwitches: fgSwitches,
    foregroundWindowsSeen: fgSet.size,
    focusChanges: focusChanges,
    attribution: {
      physicalInputEvents: physicalEvents,
      humanActiveMs, quietMs,
      unexplainedCursorMaxDeltaPx: round(unexplainedMaxDelta),
      unexplainedCursorMaxDeltaAt: unexplainedMaxAt,
      unexplainedCursorPathPx: round(unexplainedTotal),
      unexplainedForegroundSwitches: fgSwitches - fgSwitchesHuman,
      unexplainedFocusChanges: focusChanges - focusChangesHuman,
    },
    first: rows[0], last: rows[rows.length - 1],
  };
}

function safeJson(t) { try { return JSON.parse(t); } catch { return null; } }

function readLive() {
  if (!existsSync(LIVE)) return null;
  try { return JSON.parse(readFileSync(LIVE, 'utf8')); } catch { return null; }
}

function report(live) {
  const s = summarize(readFileSync(live.out, 'utf8').split('\n'), { hz: live.hz });
  s.file = live.out;
  if (live.tag) s.tag = live.tag;
  const ef = live.out + '.err';
  if (existsSync(ef)) {
    const e = readFileSync(ef, 'utf8').trim();
    if (e) s.samplerStderr = e.slice(0, 500);
  }
  return s;
}

async function main() {
  if (flag('start')) {
    rmSync(STOPFILE, { force: true });
    const hz = Number(opt('hz', 20));
    const tag = opt('tag', 'manual');
    const out = join(PROOF_DIR, `probe-${stamp()}.jsonl`);
    const child = startSampler({ hz, ms: 0, out, background: true });
    const live = { pid: child.pid, out, hz, tag, startedAt: Date.now() };
    writeFileSync(LIVE, JSON.stringify(live, null, 2));
    console.log(JSON.stringify({ started: true, ...live }));
    return 0;
  }

  if (flag('status')) {
    const live = readLive();
    console.log(JSON.stringify({ live: !!live, sampler: live, samplerAlive: live ? pidAlive(live.pid) : false }));
    return 0;
  }

  if (flag('stop')) {
    const live = readLive();
    if (!live) { console.log(JSON.stringify({ error: 'no live sampler', liveFile: LIVE })); return 2; }
    writeFileSync(STOPFILE, String(Date.now()));
    const deadline = Date.now() + 6000;
    let gone = false;
    while (Date.now() < deadline) { if (!pidAlive(live.pid)) { gone = true; break; } await sleep(120); }
    if (!gone) { try { process.kill(live.pid); } catch {} await sleep(300); }
    const s = report(live);
    s.stoppedCleanly = gone;
    console.log(JSON.stringify(s, null, 2));
    rmSync(STOPFILE, { force: true }); rmSync(LIVE, { force: true });
    return 0;
  }

  if (flag('run')) {
    rmSync(STOPFILE, { force: true });
    const hz = Number(opt('hz', 20));
    const ms = Number(opt('ms', 10000));
    const tag = opt('tag', 'run');
    const out = join(PROOF_DIR, `probe-${stamp()}.jsonl`);
    const child = startSampler({ hz, ms, out, background: false });
    await sleep(ms + 1200);
    try { child.kill(); } catch {}
    const s = summarize(readFileSync(out, 'utf8').split('\n'), { hz });
    s.file = out; s.tag = tag;
    console.log(JSON.stringify(s, null, 2));
    return 0;
  }

  if (flag('move')) {
    // Self-test of the instrument: run the sampler, then nudge the *system* cursor by a
    // known delta and confirm the record shows motion. Without this, a zero-delta PASS
    // could just mean the probe is blind. This is the one place in the project where the
    // cursor is deliberately moved (SetCursorPos, restored right after) -- never during a
    // proof run.
    const want = Number(opt('move', 300));
    const ms = Number(opt('ms', 3500));
    const hz = Number(opt('hz', 20));
    const out = join(PROOF_DIR, `probe-${stamp()}-selftest.jsonl`);
    rmSync(STOPFILE, { force: true });
    const sampler = startSampler({ hz, ms, out, background: false });
    await sleep(700);
    const nudge = join(HERE, '..', '..', 'scripts', 'nudge-cursor.ps1');
    const mover = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', nudge, '-DeltaPx', String(want), '-HoldMs', String(Math.max(400, ms - 1500))],
      { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let mout = '';
    mover.stdout.on('data', (b) => { mout += b; });
    await sleep(ms + 800);
    try { sampler.kill(); } catch {}
    const s = summarize(readFileSync(out, 'utf8').split('\n'), { hz });
    s.file = out; s.tag = 'selftest-move'; s.expectedDeltaPx = want;
    s.motionDetected = s.cursorMaxDeltaPx >= want * 0.6;
    if (mout.trim()) s.nudgeEcho = mout.trim().slice(0, 200);
    console.log(JSON.stringify(s, null, 2));
    return 0;
  }

  if (flag('summarize')) {
    const f = opt('summarize');
    if (!f || !existsSync(f)) { console.log(JSON.stringify({ error: 'file not found', f })); return 2; }
    console.log(JSON.stringify(summarize(readFileSync(f, 'utf8').split('\n'), { hz: Number(opt('hz', 20)) }), null, 2));
    return 0;
  }

  console.log(JSON.stringify({ error: 'need --start | --stop | --run --ms N | --move N | --summarize <file> | --status', worker: WORKER, workerExists: existsSync(WORKER), proofDir: PROOF_DIR }));
  return 2;
}

main().then((c) => process.exit(c), (e) => { console.error(String(e && e.stack || e)); process.exit(1); });
