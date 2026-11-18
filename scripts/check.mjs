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

const roots = ['scripts', 'src', 'test', 'worker'].filter((r) => {
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
