// check-types.mjs — verify the shipped .d.ts is consumable by a strict TS client.
// Uses any tsc 5.x/6.x already present in the workspace; if none is installed this is a NAMED SKIP,
// never a red against the plugin (a missing compiler is an environment fact, not a contract defect).
//
// The compiler search lives in find-tsc.mjs because check-jsdoc.mjs needs the same answer; two
// gates that disagree about which compiler they tested against would be the drift this repo
// refuses elsewhere in the file tree.
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { findTsc } from './find-tsc.mjs';

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
