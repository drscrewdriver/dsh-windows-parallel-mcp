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
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync, rmSync, openSync, closeSync, readSync, statSync } from 'node:fs';
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

// Liveness is decided by the RECORD, not by a pid handle: under a host that reaps or
// re-parents process trees (CI harness, job objects), the pid Start-Process reported can
// stop being queryable while the sampler is still writing -- which would read as "dead"
// and would make a zero-motion result meaningless. So there is no pidAlive() here on
// purpose: a stale process handle is not evidence about the record.
function samplerState(live) {
  if (!live) return { state: 'none' };
  if (!existsSync(live.out)) return { state: 'booting', since: Date.now() - live.startedAt };
  const st = statSync(live.out);
  // Bytes only, never a re-read of the file: --status may be called while a proof run is
  // in progress, and scanning megabytes per poll burns CPU in the very window whose
  // quietness is under test. ~150 bytes per record.
  if (tailHasDone(live.out)) return { state: 'done', bytes: st.size };
  const age = Date.now() - st.mtimeMs;
  return { state: age < 3000 ? 'running' : 'stale', ageMs: Math.round(age), bytes: st.size };
}

function countRows(txt) {
  let n = 0;
  for (const l of txt.split('\n')) { const t = l.trim(); if (t && !t.startsWith('#')) n++; }
  return n;
}

function waitDone(live, ms) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (existsSync(live.out) && tailHasDone(live.out)) return true;
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 120);
  }
  return false;
}

// Tail-only check: a proof run can be several MB, and polling it whole would burn CPU in
// the very window whose stillness we are measuring.
function tailHasDone(file) {
  try {
    const size = statSync(file).size;
    const n = Math.min(size, 400);
    const fd = openSync(file, 'r');
    try {
      const buf = Buffer.alloc(n);
      readSync(fd, buf, 0, n, size - n);
      return /#done\s/.test(buf.toString('utf8'));
    } finally { closeSync(fd); }
  } catch { return false; }
}

function samplerArgs(hz, ms, out) {
  return ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', WORKER, '-Hz', String(hz), '-DurationMs', String(ms), '-Out', out, '-StopFile', STOPFILE];
}

function startSampler({ hz, ms, out, background }) {
  const args = samplerArgs(hz, ms, out);
  if (!background) {
    const errFd = openSync(out + '.err', 'a');
    const child = spawn('powershell.exe', args, { stdio: ['ignore', 'ignore', errFd], windowsHide: true });
    child.on('error', (e) => { writeFileSync(out + '.spawnerr', String(e && e.message)); });
    return child;
  }
  // A background sampler must outlive the short-lived Node command that starts it.
  // spawn(..., {detached:true}) does NOT work here: the sampler exits at once and the
  // JSONL stays 0 bytes. Start-Process is the documented Windows way to hand a process
  // to the session.
  // Two traps, both hit on this host:
  //  1. an unquoted '-NoProfile' binds to Start-Process as its own parameter, leaving
  //     the sampler with no script at all -- so every argument gets single quotes;
  //  2. if the sampler inherits the launcher's stdout handle, any caller that waits on
  //     the launcher (spawnSync with a pipe) blocks until the SAMPLER exits -- which is
  //     never, for a background run. Hence: the pid goes to a file, and the sampler's
  //     own stdio is redirected away from the launcher's handles.
  const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";
  const list = args.map(q).join(', ');
  const errFile = out + '.err';
  const pidFile = out + '.pid';
  const cmd = [
    `$p = Start-Process -FilePath powershell.exe -ArgumentList ${list}`,
    `-WindowStyle Hidden -RedirectStandardOutput ${q(out + '.sout')} -RedirectStandardError ${q(errFile)} -PassThru;`,
    `Set-Content -LiteralPath ${q(pidFile)} -Value $p.Id -NoNewline`,
  ].join(' ');
  spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', cmd], { encoding: 'utf8', windowsHide: true, stdio: 'ignore' });
  const deadline = Date.now() + 8000;
  while (!existsSync(pidFile) && Date.now() < deadline) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
  }
  if (!existsSync(pidFile)) throw new Error('sampler launch produced no pid: ' + cmd.slice(0, 200));
  const pid = Number(readFileSync(pidFile, 'utf8').trim());
  if (!pid) throw new Error('sampler pid unreadable in ' + pidFile);
  try { rmSync(pidFile, { force: true }); } catch {}
  return { pid };
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
  if (!existsSync(live.out)) {
    // A missing record file means the sampler never wrote anything -- which must never
    // be read as "zero motion observed".
    const ef = live.out + '.err';
    return { error: 'no sampler output file', file: live.out, samplerStderr: existsSync(ef) ? readFileSync(ef, 'utf8').trim().slice(0, 500) : '', tag: live.tag };
  }
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
    console.log(JSON.stringify({ live: !!live, sampler: live, samplerState: samplerState(live) }));
    return 0;
  }

  if (flag('stop')) {
    const live = readLive();
    if (!live) { console.log(JSON.stringify({ error: 'no live sampler', liveFile: LIVE })); return 2; }
    writeFileSync(STOPFILE, String(Date.now()));
    // The stop handshake is the `#done` record, not a pid: a reaped-but-still-writing
    // sampler would otherwise be reported as stopped before its last samples landed.
    const graceful = waitDone(live, 8000);
    let killed = false;
    if (!graceful && live.pid) { try { process.kill(live.pid); killed = true; } catch {} }
    const s = report(live);
    s.stoppedCleanly = graceful;
    if (killed) s.note = 'stop-file handshake timed out; sampler signalled';
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
