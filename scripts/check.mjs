// check.mjs — the local gate: parse every PowerShell file, verify encodings, syntax-check
// every JS/MJS file, and confirm no file lost its UTF-8 BOM in editing.
//
// WHY ONE COMMAND. Each of these checks was written because a specific run was already
// wasted by the corresponding failure:
//   * check-ps-parse  -- `desktop\'s` terminated a string and the parser blamed a line 50
//     away; discovered only after an 8-minute experiment had been arranged around the script.
//   * check-ps-bom    -- PS 5.1 decodes a BOM-less file as GBK, so the Chinese safety
//     vocabulary silently matched nothing for an entire run series. The `edit` tool drops the
//     BOM it rewrites, so this failure returns after ordinary edits and must be re-checked
//     rather than remembered.
//   * node --check    -- a `#` comment left over from a PowerShell copy-paste is a runtime
//     SyntaxError, not a linting preference.
// Running them separately meant running one and forgetting the others, which is how a green
// local run and a broken repo coexisted. Order is deliberate: the parse gate is the cheapest
// signal about the largest class of dead-experiment bugs, so it goes first.
import { spawnSync } from 'node:child_process';
import { readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const roots = ['scripts', 'src', 'test', 'worker', 'lib'].filter((r) => {
  try { return statSync(r).isDirectory(); } catch { return false; }
});

function walk(dir, exts, out = []) {
  let ents;
  try { ents = readdirSync(dir); } catch { return out; }
  for (const e of ents) {
    const p = join(dir, e);
    let st; try { st = statSync(p); } catch { continue; }
    if (st.isDirectory()) walk(p, exts, out);
    else if (exts.some((x) => e.endsWith(x))) out.push(p);
  }
  return out;
}

const results = [];
const run = (name, fn) => {
  const at = Date.now();
  const r = fn();
  results.push({ name, ok: r.ok, ms: Date.now() - at, out: r.out });
  return r.ok;
};

let pass = true;

pass = run('powershell parse', () => {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', 'scripts/check-ps-parse.ps1', ...roots], { encoding: 'utf8' });
  return { ok: r.status === 0, out: ((r.stdout || '') + (r.stderr || '')).trim() };
}) && pass;

pass = run('powershell encoding (BOM/UTF-8)', () => {
  const r = spawnSync(process.execPath, ['scripts/check-ps-bom.mjs', ...roots], { encoding: 'utf8' });
  return { ok: r.status === 0, out: ((r.stdout || '') + (r.stderr || '')).trim() };
}) && pass;

// The parser cannot see bare static calls (`CHW::ByKind(...)` where `[CHW]::ByKind` is
// required), so the parse gate above passes files that die at runtime. Five occurrences in
// four files in one session, each discovered only after the experiment had started.
pass = run('powershell static-call syntax', () => {
  const r = spawnSync(process.execPath, ['scripts/check-ps-calls.mjs', ...roots], { encoding: 'utf8' });
  return { ok: r.status === 0, out: ((r.stdout || '') + (r.stderr || '')).trim() };
}) && pass;

// The refusal vocabulary lives in three places (what fires / what is promised / what is explained)
// and the action contract is what a model branches on. Both are cheap to check and expensive to
// discover wrong at runtime, so they are gates rather than review items.
pass = run('refusal vocabulary (code = schema = docs)', () => {
  const r = spawnSync(process.execPath, ['scripts/check-refusals.mjs'], { encoding: 'utf8' });
  return { ok: r.status === 0, out: ((r.stdout || '') + (r.stderr || '')).trim() };
}) && pass;

pass = run('tool schema contract', () => {
  const r = spawnSync(process.execPath, ['test/schema-test.mjs'], { encoding: 'utf8' });
  return { ok: r.status === 0, out: ((r.stdout || '') + (r.stderr || '')).trim() };
}) && pass;

// THE CENTRAL CLAIM'S TEST. "Driving a window never disturbs the owner" is the whole reason the
// product exists, and it is only real if the attribution arithmetic is pinned against windows whose
// answer is known by construction -- including cases that FAIL, so a 'pass' cannot be a constant.
// This is the one gate that needs no desktop at all (pure synthetic samples), so it costs ~50ms and
// runs even when the human is working. It found two of its own test-authoring bugs (metric mixup
// between per-gap max and total path; a snap-back that was software motion masquerading as human).
pass = run('proof attribution (pure, synthetic windows)', () => {
  const r = spawnSync(process.execPath, ['test/proof-window-test.mjs'], { encoding: 'utf8' });
  const tail = ((r.stdout || '') + (r.stderr || '')).trim().split('\n').slice(-1)[0] || '(no output)';
  return { ok: r.status === 0, out: tail };
}) && pass;

// THE CURSOR GUARANTEE, ENFORCED WHERE IT IS DECIDABLE. The runtime sensor cannot blame cursor
// motion on our action: an idle baseline (nothing running) measured up to 3 unexplained gaps at 11px
// on this desktop. So the promise "the real cursor never moves because of us" is enforced by the
// SHIPPED ENGINE HAVING NO PRIMITIVE that moves it -- SetCursorPos / SendInput / mouse_event /
// keybd_event are all absent from every engine file. Zero false positives, zero desktop dependence.
// The gate was itself verified non-vacuous: injecting SetCursorPos into win.ps1 turns it red; removing
// it turns it green with no residue.
pass = run('no cursor-control primitive in the shipped engine', () => {
  const r = spawnSync(process.execPath, ['scripts/check-no-cursor-control.mjs'], { encoding: 'utf8' });
  const out = ((r.stdout || '') + (r.stderr || '')).trim();
  return { ok: r.status === 0, out: out.split('\n')[0] || '(no output)' };
}) && pass;

// THE TAKEOVER TIER'S STRUCTURE (R3). The cursor move and the keyboard injection are new capabilities;
// what makes them safe is not the calls but the ORDER and the enclosure around them: the HUD must exist
// first (G3), the primitives live in one file each (G1/G2), and the cursor move sits inside the
// try/finally that restores it (G4). Run in --self-test mode on purpose: this gate mutates a copy of the
// engine for each assertion and requires the corresponding red, because a gate that has never been red is
// a comment. Cheap (~10ms) and desktop-free.
pass = run('takeover path structure (G1-G5, self-tested)', () => {
  const r = spawnSync(process.execPath, ['scripts/check-takeover-path.mjs', '--self-test'], { encoding: 'utf8' });
  return { ok: r.status === 0, out: ((r.stdout || '') + (r.stderr || '')).trim() };
}) && pass;

// The package that gets installed is the product. A missing engine file or a swept-in .tmp/ both
// install cleanly and fail later, so the tarball is checked here rather than discovered at install.
pass = run('package tarball contents', () => {
  const r = spawnSync(process.execPath, ['scripts/check-pack.mjs'], { encoding: 'utf8' });
  return { ok: r.status === 0, out: ((r.stdout || '') + (r.stderr || '')).trim() };
}) && pass;

// The two process-level suites cost about a second each (one PowerShell start). They belong in the
// gate because a broken protocol or a broken projection is exactly as fatal as a syntax error, and
// because a test that only runs when someone remembers to run it is not a gate.
pass = run('host half + sidecar (process)', () => {
  const out = [];
  let good = true;
  // signal-test included: a shim that drops the call context (`exec`) silently disables host cancellation,
  // and that failure is invisible to every other arm here. It creates its own target window and types
  // through the message door, so it does not depend on what is on screen.
  for (const file of ['test/plugin-test.mjs', 'test/worker-smoke.mjs', 'test/signal-test.mjs']) {
    const r = spawnSync(process.execPath, [file], { encoding: 'utf8' });
    if (r.status !== 0) good = false;
    const tail = ((r.stdout || '') + (r.stderr || '')).trim().split('\n').slice(-1)[0] || '';
    out.push(`${file}: ${tail}`);
  }
  return { ok: good, out: out.join('\n') };
}) && pass;

// The overlay is the product's visible surface, and its promises are syscall answers rather than
// looks: the ex-style trio is ON the window, Show() does not take the foreground, a click at the
// marker lands on the window underneath, the global chord flips the ONE pause flag, and Stop
// leaves nothing behind. Written because the first version of this layer hung on Stop and would
// have shipped a "pause switch" that deadlocked -- the trace is in .tmp/ov-step.log.
// Desktop-sensitive arms SKIP rather than FAIL when real input happened in the same window, so
// this is safe to run while the owner is working. It costs ~12s, so it goes last.
pass = run('overlay promises (desktop, STA)', () => {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-STA', '-File', 'test/overlay-test.ps1'], { encoding: 'utf8', timeout: 180000 });
  const raw = ((r.stdout || '') + (r.stderr || '')).trim();
  const lines = raw.split('\n').map((l) => l.trim()).filter(Boolean);
  const notable = lines.filter((l) => /^(FAIL|SKIP|INFO)/.test(l));
  const tail = lines.filter((l) => /passed,/.test(l)).slice(-1)[0] || lines.slice(-1)[0] || '(no output)';
  return { ok: r.status === 0, out: notable.length ? `${tail} | ${notable.join(' | ')}` : tail };
}) && pass;

// The marker is a product claim ("the AI cursor shows the point that was acted on") and it lives in
// a window, not in a result object -- so it needs a real click through the SHIPPED plugin and an
// INDEPENDENT oracle for the window rect (scripts/probe-overlay-rect.ps1, which knows nothing about
// overlay.ps1). Cheap enough to gate: ~10s including a WinForms target. This is the arm that found
// the DPI defect (marker at 303,263 for a target of 470,410) and the cross-thread Invoke defect
// (1818ms), neither of which any unit test could see.
pass = run('marker end-to-end (real click, independent oracle)', () => {
  const r = spawnSync(process.execPath, ['test/marker-e2e.mjs'], { encoding: 'utf8', timeout: 180000 });
  const lines = ((r.stdout || '') + (r.stderr || '')).trim().split('\n').map((l) => l.trim()).filter(Boolean);
  const notable = lines.filter((l) => /^(FAIL|WARN|SKIP|INFO)/.test(l));
  const tail = lines.filter((l) => /passed,/.test(l)).slice(-1)[0] || lines.slice(-1)[0] || '(no output)';
  return { ok: r.status === 0, out: notable.length ? `${tail} | ${notable.join(' | ')}` : tail };
}) && pass;

// THE POINT IS THE CONTRACT for a click. The UIA tier used to invoke the first descendant carrying
// a pattern, ignoring x/y entirely, and answered ok:true -- a wrong action reported as a right one.
// This arm drives a real two-button WPF target and reads the counters the APP writes, because
// reading our own Invoke back through UIA would be grading homework in our own class. It fails in
// both directions: point-at-Bravo must bump Bravo (not Alpha), and a point outside the target must
// refuse (not redirect). ~15s including the target.
pass = run('uia click acts on the point (two buttons, app-side oracle)', () => {
  const r = spawnSync(process.execPath, ['test/uia-click-truth.mjs'], { encoding: 'utf8', timeout: 240000 });
  const lines = ((r.stdout || '') + (r.stderr || '')).trim().split('\n').map((l) => l.trim()).filter(Boolean);
  const notable = lines.filter((l) => /^(FAIL|WARN|SKIP|INFO)/.test(l));
  const tail = lines.filter((l) => /passed,/.test(l)).slice(-1)[0] || lines.slice(-1)[0] || '(no output)';
  return { ok: r.status === 0, out: notable.length ? `${tail} | ${notable.join(' | ')}` : tail };
}) && pass;

const js = [].concat(...roots.map((rt) => walk(rt, ['.mjs', '.js'])));
const jsFail = [];
for (const f of js) {
  const r = spawnSync(process.execPath, ['--check', f], { encoding: 'utf8' });
  if (r.status !== 0) jsFail.push(f + '\n    ' + (r.stderr || '').split('\n').slice(0, 3).join('\n    '));
}
pass = run('javascript syntax', () => ({
  ok: jsFail.length === 0,
  out: jsFail.length ? jsFail.join('\n') : `${js.length} file(s) checked`,
})) && pass;

for (const r of results) {
  console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}  (${r.ms}ms)`);
  if (r.out) console.log('      ' + r.out.split('\n').join('\n      '));
}
console.log(pass ? '\nGATE GREEN' : '\nGATE RED -- fix before running any experiment: a dead run costs minutes, this costs seconds.');
process.exit(pass ? 0 : 1);
