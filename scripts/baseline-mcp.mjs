#!/usr/bin/env node
// baseline-mcp.mjs — task_3 baseline observation of the shipped pre-emptive engine.
//
// WHAT THIS IS FOR. G0 asks for a measured cost of the existing approach, not a
// narrative about it. The two DSH bundles in this ecosystem (dsh-windows-mcp,
// dsh-codex-style-computer-use) drive CursorTouch/Windows-MCP, so talking to that
// server over MCP stdio observes exactly the behaviour users get today. R2 is a claim
// about one dimension: real cursor movement, foreground switches, keyboard focus
// changes during a batch of actions. So the baseline is measured with the SAME sampler,
// the same attribution split and the same window discipline the proof will use --
// otherwise it is two different questions wearing one word.
//
// DELIBERATE OMISSION. No `type` action: SendInput-based typing lands wherever the caret
// is, and on this desktop the caret is sometimes the user's own editor. Clicks, moves and
// window switches are enough to measure the three dimensions under test, and every target
// is a window this script created.
//
// Usage: node scripts/baseline-mcp.mjs [--hz 20] [--out file.json] [--keep]
import { spawn, spawnSync } from 'node:child_process';
import { writeFileSync, existsSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { start as startSampler, stop as stopSampler, killEarly, summarize, softwareCursorEvidence, lastAgeFromRecord } from '../src/lib/sampler.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : d; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- minimal MCP stdio client ------------------------------------------------------
// Hand-written rather than pulled from @modelcontextprotocol/sdk because a baseline probe
// must not need an install step: the point of measuring this ecosystem is that anyone can
// re-run the measurement. Newline-delimited JSON-RPC 2.0 over stdio.
class McpStdio {
  constructor(child) {
    this.child = child;
    this.nextId = 1;
    this.pending = new Map();
    this.buf = '';
    this.stderr = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (txt) => this._feed(txt));
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (txt) => { this.stderr += txt; if (this.stderr.length > 200000) this.stderr = this.stderr.slice(-120000); });
  }
  _feed(txt) {
    this.buf += txt;
    let i;
    while ((i = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, i).trim();
      this.buf = this.buf.slice(i + 1);
      if (!line) continue;
      let msg; try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id !== undefined && this.pending.has(msg.id)) {
        const { resolve, reject, timer } = this.pending.get(msg.id);
        clearTimeout(timer);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message + ' (code ' + msg.error.code + ')'));
        else resolve(msg.result);
      }
    }
  }
  request(method, params, timeoutMs = 120000) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`timeout on ${method} after ${timeoutMs}ms`)); }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }
  notify(method, params) {
    this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
  }
}

function findWindow(titlePart) {
  // EnumWindows, not Get-Process MainWindowTitle: the target host runs with its console
  // hidden, and then MainWindowHandle resolves to the console (empty title) instead of
  // the form. The matrix already looks windows up this way, so baseline and matrix mean
  // the same thing by "the target window".
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', join(ROOT, 'scripts', 'find-window.ps1'), '-TitlePart', titlePart],
    { encoding: 'utf8', windowsHide: true });
  const t = (r.stdout || '').trim().split('\n').pop();
  if (!t) return null;
  try { return JSON.parse(t); } catch { return null; }
}

async function main() {
  const hz = Number(opt('hz', 20));
  const log = [];
  const step = async (name, fn) => {
    const at = Date.now();
    try { const v = await fn(); log.push({ step: name, at, durationMs: Date.now() - at, ok: true }); return v; }
    catch (e) { log.push({ step: name, at, durationMs: Date.now() - at, ok: false, error: String(e && e.message || e).slice(0, 300) }); return null; }
  };

  // 1. a target window this run owns: WinForms control, unique title, real Edit+Button.
  //    It steals the foreground on launch, which is why the sampler starts AFTER it.
  //    The exit flag must NOT exist yet: the target host closes itself as soon as the
  //    file is present, so pre-creating it (to "reset" cleanup) kills the window inside
  //    one timer tick -- which looks exactly like a launch failure.
  const exitFile = join(tmpdir(), 'wpm-baseline-' + Date.now() + '.stop');
  try { if (existsSync(exitFile)) rmSync(exitFile, { force: true }); } catch {}
  const targetProc = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
    '-File', join(ROOT, 'scripts', 'winforms-target.ps1'), '-HoldMs', '240000', '-ExitFile', `"${exitFile}"`],
    { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  targetProc.stderr.setEncoding('utf8');
  const procErr = [];
  targetProc.stderr.on('data', (b) => procErr.push(b));

  let target = null;
  for (let i = 0; i < 45 && !target; i++) { await sleep(400); target = findWindow('WpmWinFormsTarget'); }
  if (!target) { try { targetProc.kill(); } catch {} throw new Error('no WinForms target window appeared; cannot measure a baseline'); }
  console.error('[target] ' + JSON.stringify(target));
  await sleep(2500);   // let the launch's foreground change settle before any measuring

  // 2. the upstream engine, over MCP stdio
  const server = spawn('uvx', ['--python', '3.14', '--from', 'windows-mcp', 'windows-mcp', 'serve'],
    { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  const mcp = new McpStdio(server);
  let sampler = null;

  try {
    await step('initialize', () => mcp.request('initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'wpm-baseline-probe', version: '0.0.0' },
    }));
    mcp.notify('notifications/initialized', {});

    const list = await step('tools/list', () => mcp.request('tools/list', {}));
    const tools = (list && list.tools) || [];
    // What the CURRENT engines expose. Read as the mirror of A3: a parameter named
    // something like `physical` means "off by default, the model may set it" -- which is
    // a policy, not a contract.
    const schemaText = (t) => JSON.stringify(t.inputSchema || {});
    const schemaAudit = {
      toolCount: tools.length,
      names: tools.map((t) => t.name),
      withPhysicalParam: tools.filter((t) => /physical/i.test(schemaText(t))).map((t) => t.name),
      withHwndParam: tools.filter((t) => /\bhwnd\b|windowHandle|handle/i.test(schemaText(t))).map((t) => t.name),
      screenCoordinateOnly: tools.filter((t) => /\bloc\b|\blocs\b|coordinate/i.test(schemaText(t))).map((t) => t.name),
    };

    const call = (name, args, timeoutMs = 90000) => mcp.request('tools/call', { name, arguments: args }, timeoutMs)
      .then((r) => ({
        isError: !!(r && r.isError),
        text: ((r && r.content) || []).filter((c) => c.type === 'text').map((c) => c.text).join('\n').slice(0, 500),
        imageParts: ((r && r.content) || []).filter((c) => c.type === 'image').length,
      }));

    // 3. the measured window starts here
    sampler = await startSampler({ hz, tag: 'baseline' });

    // Wait for a physically quiet stretch before each gated action. Without this the
    // engine's own control gate answers `USER_CONTROL` / `PHYSICAL_INPUT_HELD` and the
    // action never executes -- and a "zero disturbance" reading taken over actions that
    // never ran is the same self-deception A2 exists to prevent for our own engine.
    const quietWait = async (label) => {
      for (let i = 0; i < 40; i++) {
        const age = lastAgeFromRecord(sampler);
        if (age >= 1500) return { waited: true, ageMs: age, label };
        await sleep(300);
      }
      return { waited: false, ageMs: lastAgeFromRecord(sampler), label };
    };

    const seq = [];
    const gated = (label, fn) => seq.push([label, async () => {
      const w = await quietWait(label);
      return { ...(await fn()), gateWait: w };
    }]);
    const ungated = (label, fn) => seq.push([label, fn]);

    gated('App switch to target', () => call('App', { mode: 'switch', name: 'WpmWinFormsTarget' }));
    ungated('Snapshot', () => call('Snapshot', {}));
    ungated('Screenshot', () => call('Screenshot', { display: [0] }));
    gated('Click control point', () => call('Click', { loc: [220, 200] }));
    gated('MoveMouse', () => call('MoveMouse', { loc: [640, 420] }));
    gated('Click again', () => call('Click', { loc: [220, 200] }));
    ungated('Screenshot after', () => call('Screenshot', { display: [0] }));
    const results = [];
    for (const [label, fn] of seq) {
      const r = await step(label, fn);
      // gateWait is carried through: without it the report says "action failed" while
      // hiding WHY (the engine's own control gate refused), and the reader cannot tell a
      // refusal apart from a crash.
      results.push({
        label,
        ok: !!r && !r.isError,
        isError: r ? r.isError : null,
        text: r ? r.text : 'step failed',
        gateWait: r ? r.gateWait : undefined,
      });
      await sleep(400);
    }

    // The engine's own shutdown is inside the window: a control-gate indicator or
    // handoff overlay appears at the end of a call sequence, and measuring after the
    // kill would miss it.
    await step('server-shutdown', async () => { try { server.kill(); } catch {} return true; });
    await sleep(1200);

    const stopped = await stopSampler(sampler);
    const summary = summarize(stopped.rows);
    if (summary.error) throw new Error('sampler died mid-window: ' + summary.error);

    const out = {
      generatedAt: new Date().toISOString(),
      engine: 'CursorTouch/Windows-MCP via uvx (kernel of dsh-windows-mcp and dsh-codex-style-computer-use)',
      target,
      samplerFile: stopped.file,
      samplerStoppedCleanly: stopped.graceful,
      schemaAudit,
      steps: log,
      actions: results,
      probe: summary,
      // The number the parallel claim is measured against: disturbance with NO physical
      // input in the same gap, i.e. attributable to the engine rather than the human.
      softwareCaused: softwareCursorEvidence(summary),
      serverStderrTail: mcp.stderr.slice(-1200),
    };
    const f = opt('out');
    if (f) writeFileSync(f, JSON.stringify(out, null, 2));
    console.log(JSON.stringify(out, null, 2));
  } finally {
    try { server.kill(); } catch {}
    if (sampler) killEarly(sampler);
    if (!argv.includes('--keep')) {
      spawnSync('powershell.exe', ['-NoProfile', '-Command', `Set-Content -LiteralPath '${exitFile}' -Value 'exit' -Force`], { windowsHide: true });
      await sleep(800);
      try { targetProc.kill(); } catch {}
      try { if (existsSync(exitFile)) { /* removed by the target host */ } } catch {}
    }
  }
  return 0;
}

main().then((c) => process.exit(c), (e) => { console.error('BASELINE FAIL: ' + (e && e.stack || e)); process.exit(1); });
