// engine.js — the sidecar client: one long-lived PowerShell worker, driven over JSON lines.
//
// WHY THE WORKER EXISTS AT ALL. The engine (src/engine/*.ps1) is PowerShell because the OS APIs it
// needs -- UIA COM, GetGUIThreadInfo, AttachThreadInput -- are cheapest there and cost zero install
// (findings.md TS-1). But UIA wants an STA apartment and a PowerShell process cannot both host that
// apartment and stay responsive while blocking on stdin. So the worker owns the apartment and the
// line protocol, and this file owns the process lifetime. Same division the sibling competitor
// measured to work.
//
// WHAT THIS FILE IS RESPONSIBLE FOR, and each one is a failure already seen in this repo or in the
// ecosystem:
//   * LAZY START. Spawning PowerShell + Add-Type + assembly load on plugin load would put that cost
//     in the host's boot path for a tool nobody has called yet. First call pays; nobody else does.
//   * ONE RESTART, THEN AN HONEST ERROR. A crashed worker must not become a permanently-dead tool
//     that reports nothing, and it must not become an infinite respawn loop either.
//   * NO SILENT STALL. Every request has a deadline. A worker that stops answering (STA thread
//     wedged inside a cross-process SendMessage is the realistic case) would otherwise leave the
//     model waiting forever with no diagnostic.
//   * STDOUT IS THE PROTOCOL AND NOTHING ELSE. A stray line means a broken parse; the reader
//     therefore keeps only lines that parse as an object with an `id`, and preserves everything else
//     as diagnostics rather than throwing it away.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

/** Absolute path of the engine directory shipped inside the package. */
export function engineRoot(from = HERE) {
  return resolve(from, '..', 'src', 'engine');
}

/** Resolve the worker script for this package. */
export function workerScript(from = HERE) {
  return join(engineRoot(from), 'worker.ps1');
}

/**
 * Locate a PowerShell executable. Windows PowerShell 5.1 is the floor: it ships with Windows, it has
 * UIAutomationClient, and it needs no installation — which is the project's only citable difference
 * against competitors that require uv/Python or an MSVC runtime (findings.md TS-1). pwsh is accepted
 * when the operator points at it, because it is a superset for these calls.
 */
export function resolvePowerShell(explicitPath, env = process.env) {
  if (explicitPath && existsSync(explicitPath)) return explicitPath;
  const win = env.SystemRoot ? join(env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe') : '';
  if (win && existsSync(win)) return win;
  return 'powershell.exe';
}

/**
 * A refusing-or-answering client for one worker process.
 *
 * Deliberately not an EventEmitter: there is exactly one consumer (the tool), and a second listener
 * surface would make "who restarts the worker" ambiguous.
 */
export class WorkerClient {
  /**
   * @param {object} options
   * @param {string} [options.powershellPath]
   * @param {string} [options.script]
   * @param {number} [options.requestTimeoutMs]
   * @param {(line: string) => void} [options.onStderr]
   * @param {(info: {restarted: boolean, code: number|null, signal: string|null}) => void} [options.onExit]
   */
  constructor(options = {}) {
    this.powershellPath = resolvePowerShell(options.powershellPath);
    this.script = options.script ?? workerScript();
    this.requestTimeoutMs = options.requestTimeoutMs ?? 20000;
    this.onStderr = options.onStderr ?? (() => {});
    this.onExit = options.onExit ?? (() => {});

    /** @type {import('node:child_process').ChildProcess | null} */
    this.child = null;
    /** Pending requests keyed by id. Every entry owns its own timer. */
    this.pending = new Map();
    this.seq = 0;
    /** Set once the worker has been started, so a restart is distinguishable from a first start. */
    this.started = false;
    this.restarts = 0;
    /** Last stderr lines, kept because a worker that dies usually explains itself there. */
    this.stderrTail = [];
    this.buffer = '';
  }

  get alive() {
    return this.child !== null && this.child.exitCode === null && !this.child.killed;
  }

  /**
   * Start the worker if it is not running. Costs one PowerShell launch on first call; a no-op
   * afterwards. Throws if the script is missing, because a missing engine is a broken install and
   * pretending otherwise would surface as a confusing refusal later.
   */
  start() {
    if (this.alive) return this;
    if (!existsSync(this.script)) {
      throw new Error(`dsh-windows-parallel-mcp: engine worker not found at ${this.script}`);
    }
    const args = [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA',
      '-File', this.script,
    ];
    const child = spawn(this.powershellPath, args, {
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child = child;
    this.buffer = '';
    this.stderrTail = [];

    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => this.#onStdout(chunk));
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      for (const line of chunk.split(/\r?\n/)) {
        if (!line.trim()) continue;
        this.stderrTail.push(line);
        if (this.stderrTail.length > 40) this.stderrTail.shift();
        this.onStderr(line);
      }
    });
    child.on('error', (err) => this.#failAll(`worker failed to start: ${err.message}`));
    child.on('exit', (code, signal) => {
      const wasStarted = this.started;
      this.child = null;
      // An exit with outstanding requests is a crash from the caller's point of view, and each of
      // those callers is told so with the worker's own last words attached -- a bare 'worker
      // exited' would send the reader looking in the wrong place.
      this.#failAll(this.#exitMessage(code, signal));
      if (wasStarted) {
        this.restarts += 1;
        this.onExit({ restarted: true, code, signal });
      }
    });
    this.started = true;
    return this;
  }

  #exitMessage(code, signal) {
    const tail = this.stderrTail.length ? ` :: ${this.stderrTail.slice(-3).join(' | ')}` : '';
    return `engine worker exited (code=${code ?? 'null'} signal=${signal ?? 'null'})${tail}`;
  }

  #onStdout(chunk) {
    this.buffer += chunk;
    let idx;
    // Only complete lines are protocol. A partial line stays buffered: JSON split across chunks is
    // normal, and parsing the fragment would produce a spurious malformed-response error.
    while ((idx = this.buffer.indexOf('\n')) >= 0) {
      const raw = this.buffer.slice(0, idx).replace(/\r$/, '');
      this.buffer = this.buffer.slice(idx + 1);
      if (!raw.trim()) continue;
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch {
        // Not protocol. Keep it as a diagnostic instead of teaching the caller a fake failure.
        this.stderrTail.push(`[unparsed stdout] ${raw}`);
        continue;
      }
      if (!msg || typeof msg !== 'object' || !('id' in msg)) {
        this.stderrTail.push(`[stdout without id] ${raw}`);
        continue;
      }
      const entry = this.pending.get(String(msg.id));
      if (!entry) continue; // a late answer for a request that already timed out
      this.pending.delete(String(msg.id));
      clearTimeout(entry.timer);
      entry.resolve(msg);
    }
  }

  #failAll(reason) {
    for (const [id, entry] of this.pending) {
      clearTimeout(entry.timer);
      entry.reject(new Error(reason));
      this.pending.delete(id);
    }
  }

  /**
   * Send one request and await its response object. Resolves with the whole envelope, so the caller
   * decides what a refusal means; this layer never turns a refusal into an exception.
   */
  request(payload) {
    this.start();
    const id = String(++this.seq);
    const line = JSON.stringify({ id, ...payload }) + '\n';
    const child = this.child;
    return new Promise((resolvePromise, rejectPromise) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        // The worker is presumed wedged. It is killed rather than left running: a wedged STA thread
        // inside a cross-process wait will not recover, and the next call deserves a clean process.
        // Restart is bounded by the `restarts` counter read by the tool layer.
        rejectPromise(new Error(
          `engine worker did not answer within ${this.requestTimeoutMs} ms (action=${payload.action}); the worker was killed and will be restarted on the next call`,
        ));
        try { child.kill(); } catch { /* already gone */ }
      }, this.requestTimeoutMs);
      this.pending.set(id, { resolve: resolvePromise, reject: rejectPromise, timer });
      child.stdin.write(line, 'utf8', (err) => {
        if (!err) return;
        this.pending.delete(id);
        clearTimeout(timer);
        rejectPromise(new Error(`could not write to the engine worker: ${err.message}`));
      });
    });
  }

  /** Clean shutdown: close stdin (the worker exits its read loop), then make sure it is gone. */
  async dispose() {
    const child = this.child;
    this.child = null;
    this.#failAll('engine worker disposed');
    if (!child) return;
    try { child.stdin.end(); } catch { }
    await new Promise((done) => {
      const t = setTimeout(() => { try { child.kill(); } catch { } done(); }, 1500);
      child.once('exit', () => { clearTimeout(t); done(); });
    });
  }
}
