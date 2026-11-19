// sampler.mjs — the one implementation of "run the input-state sampler and read its
// record". Both reach-matrix.mjs and baseline-mcp.mjs import this.
//
// It exists as a module because the alternative was two copies of the start/stop/
// attribute logic, and a drift between them would mean the reachability numbers and the
// baseline numbers were measured by different instruments while carrying the same name.
//
// Contract every caller depends on:
//  * start() returns only after the sampler created its record AND wrote enough bytes
//    to prove it is alive. A caller that skipped this would score a dead sampler as
//    "zero cursor movement", i.e. a false PASS.
//  * stop() ends the window through the sampler's own `#done` handshake, not by killing
//    a pid: a reaped-but-still-writing sampler would otherwise lose its tail samples.
//  * summarize() attributes every event to physical input or not. It does NOT decide
//    pass/fail -- that is src/kernel/proof.ts's job.
import { spawn } from 'node:child_process';
import { openSync, readFileSync, statSync, closeSync, readSync, existsSync, rmSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const STATE = join(homedir(), '.dsh', 'windows-parallel-mcp');
export const PROOF_DIR = join(STATE, 'proof');
export const STOP_FILE = join(STATE, 'stop');
const WORKER = join(HERE, '..', '..', 'scripts', 'probe-worker.ps1');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

export async function start({ hz = 20, tag = 'run' } = {}) {
  rmSync(STOP_FILE, { force: true });
  const out = join(PROOF_DIR, `probe-${tag}-${Date.now()}.jsonl`);
  const errFd = openSync(out + '.err', 'a');
  const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', WORKER, '-Hz', String(hz), '-DurationMs', '0', '-Out', out, '-StopFile', STOP_FILE],
    { stdio: ['ignore', 'ignore', errFd], windowsHide: true });
  child.on('error', (e) => writeFileSync(out + '.spawnerr', String(e && e.message)));

  const boot = Date.now() + 10000;
  while (Date.now() < boot && !existsSync(out)) await sleep(150);
  if (!existsSync(out)) {
    const err = existsSync(out + '.err') ? readFileSync(out + '.err', 'utf8').slice(0, 500) : '';
    throw new Error('sampler never created its record; stderr: ' + err);
  }
  const warm = Date.now() + 8000;
  while (Date.now() < warm && statSync(out).size < 300) await sleep(150);
  if (statSync(out).size < 300) throw new Error('sampler record stayed under 300 bytes -- instrument not recording');
  return { child, out, hz, tag };
}

export async function stop(s, { timeoutMs = 9000 } = {}) {
  writeFileSync(STOP_FILE, String(Date.now()));
  const deadline = Date.now() + timeoutMs;
  let graceful = false;
  while (Date.now() < deadline) {
    if (tailHas(s.out, /#done\s/)) { graceful = true; break; }
    await sleep(120);
  }
  if (!graceful) { try { s.child.kill(); } catch {} }
  const rows = readFileSync(s.out, 'utf8').split('\n').filter((l) => l.trim() && !l.trim().startsWith('#'));
  rmSync(STOP_FILE, { force: true });
  return { rows, graceful, file: s.out };
}

export function killEarly(s) { try { s.child.kill(); } catch {} }

// Physical-input attribution. GetLastInputInfo returns "ms since last physical input",
// so its implied event timestamp is ts - ageMs; if that moved between two samples, a
// human touched the mouse or keyboard inside the gap and any cursor delta there belongs
// to the human, not to the software under test.
export function summarize(rows) {
  const r = rows.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  if (r.length < 2) return { samples: r.length, error: 'insufficient samples' };
  const lii = (x) => (typeof x.inputAgeMs === 'number' && x.inputAgeMs >= 0 ? x.ts - x.inputAgeMs : null);
  let maxD = 0, maxAt = r[0].ts, total = 0;
  let fg = 0, fc = 0, unexplained = 0, unexplainedMax = 0, unexplainedMaxAt = 0;
  let physEvents = 0, humanMs = 0, quietMs = 0, unexplainedFg = 0, unexplainedFc = 0;
  const fgEvents = [];
  for (let i = 1; i < r.length; i++) {
    const a = r[i], b = r[i - 1];
    const gap = a.ts - b.ts;
    const ea = lii(b), eb = lii(a);
    const human = ea !== null && eb !== null && eb > ea + Math.max(2, gap * 0.6);
    if (human) { physEvents++; humanMs += gap; } else quietMs += gap;

    const dx = a.cx - b.cx, dy = a.cy - b.cy;
    const d = Math.hypot(dx, dy);
    if (d > maxD) { maxD = d; maxAt = a.ts; }
    total += d;
    if (!human && d > 0.5) { unexplained += d; if (d > unexplainedMax) { unexplainedMax = d; unexplainedMaxAt = a.ts; } }

    if (a.fg !== b.fg) {
      fg++; if (!human) unexplainedFg++;
      fgEvents.push({ at: a.ts, from: b.fg, to: a.fg, human, gapMs: gap });
    }
    if (a.focus !== b.focus) { fc++; if (!human) unexplainedFc++; }
  }
  const round = (v) => Math.round(v * 100) / 100;
  return {
    samples: r.length,
    windowMs: r[r.length - 1].ts - r[0].ts,
    cursorMaxDeltaPx: round(maxD),
    cursorMaxDeltaAt: maxAt,
    cursorTotalPathPx: round(total),
    foregroundSwitches: fg,
    focusChanges: fc,
    attribution: {
      physicalInputEvents: physEvents,
      humanActiveMs: humanMs,
      quietMs,
      unexplainedCursorMaxDeltaPx: round(unexplainedMax),
      unexplainedCursorMaxDeltaAt: unexplainedMaxAt,
      unexplainedCursorPathPx: round(unexplained),
      unexplainedForegroundSwitches: unexplainedFg,
      unexplainedFocusChanges: unexplainedFc,
    },
    foregroundEvents: fgEvents.slice(0, 25),
    first: r[0],
    last: r[r.length - 1],
  };
}

// Cursor movement attributable to software, i.e. with no physical input in the same gap.
// R2.3 forbids exactly this quantity; the raw cursor delta cannot be the test, because a
// human is allowed to move the mouse during a proof run.
export function softwareCursorEvidence(summary) {
  const a = (summary && summary.attribution) || {};
  return {
    maxPx: a.unexplainedCursorMaxDeltaPx ?? null,
    pathPx: a.unexplainedCursorPathPx ?? null,
    foregroundSwitches: a.unexplainedForegroundSwitches ?? null,
    focusChanges: a.unexplainedFocusChanges ?? null,
    quietMs: a.quietMs ?? null,
  };
}

// One-shot GetLastInputInfo read. NOT used by the baseline driver: spawning PowerShell
// every 300ms to poll it creates processes that can themselves steal the foreground, so
// the instrument would contaminate the quantity under test. Read the live record instead
// via lastAgeFromRecord().
export function lastInputAgeMs() {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command',
    `Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class LI{[StructLayout(LayoutKind.Sequential)]public struct X{public int cbSize;public uint dwTime;}[DllImport("user32.dll")]public static extern bool GetLastInputInfo(ref X p);[DllImport("kernel32.dll")]public static extern uint GetTickCount();public static long Age(){X x=new X();x.cbSize=4+8;if(!GetLastInputInfo(ref x))return -1;return (long)(GetTickCount()-x.dwTime);}}'; [LI]::Age()`],
    { encoding: 'utf8' });
  const n = Number((r.stdout || '').trim().split('\n').pop());
  return Number.isFinite(n) ? n : -1;
}

// Age of the last PHYSICAL input, read from the running sampler's own record: the newest
// line already carries inputAgeMs, and tailing a file disturbs nothing. This is how a
// driver waits for a physically quiet stretch without becoming part of what it measures.
export function lastAgeFromRecord(s) {
  try {
    const size = statSync(s.out).size;
    if (size < 120) return -1;
    const n = Math.min(size, 400);
    const fd = openSync(s.out, 'r');
    try {
      const b = Buffer.alloc(n);
      readSync(fd, b, 0, n, size - n);
      const lines = b.toString('utf8').split('\n').filter((l) => l.trim() && !l.trim().startsWith('#'));
      const last = JSON.parse(lines[lines.length - 1] || 'null');
      return last && typeof last.inputAgeMs === 'number' ? last.inputAgeMs : -1;
    } finally { closeSync(fd); }
  } catch { return -1; }
}
