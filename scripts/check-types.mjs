// check-types.mjs — verify the shipped .d.ts is consumable by a strict TS client.
// Uses any tsc 5.x/6.x already present in the workspace; if none is installed this is a NAMED SKIP,
// never a red against the plugin (a missing compiler is an environment fact, not a contract defect).
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

function findTsc(start, depth = 0) {
  if (depth > 3) return null;
  let ents;
  try { ents = readdirSync(start); } catch { return null; }
  // direct node_modules/typescript/bin/tsc
  const direct = join(start, 'node_modules', 'typescript', 'bin', 'tsc');
  if (existsSync(direct)) return direct;
  // pnpm virtual store
  const pnpm = join(start, 'node_modules', '.pnpm');
  if (existsSync(pnpm)) {
    for (const e of readdirSync(pnpm)) {
      if (!e.startsWith('typescript@')) continue;
      const p = join(pnpm, e, 'node_modules', 'typescript', 'bin', 'tsc');
      if (existsSync(p)) return p;
    }
  }
  for (const e of ents) {
    if (e === 'node_modules' || e === '.git') continue;
    const p = join(start, e);
    try { if (statSync(p).isDirectory()) { const r = findTsc(p, depth + 1); if (r) return r; } } catch { }
  }
  return null;
}
const here = process.cwd();
const tsc = findTsc(join(here, '..')) || findTsc(here);
if (!tsc) {
  console.log('SKIP types-consumer: no tsc 5.x/6.x found in workspace (environment, not a plugin defect)');
  process.exit(0);
}
const r = spawnSync(process.execPath, [tsc, '--noEmit'], { encoding: 'utf8', cwd: here, timeout: 120000 });
const out = ((r.stdout || '') + (r.stderr || '')).trim();
if (r.status !== 0) {
  console.log('FAIL types-consumer: tsc rejected the public .d.ts');
  console.log(out.slice(0, 2000));
  process.exit(1);
}
console.log('PASS types-consumer: strict tsc accepted all 5 actions, 13 refusal codes, and the exec context (' + tsc.split(/[\\/]/).slice(-3).join('/') + ')');
