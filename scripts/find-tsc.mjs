// find-tsc.mjs — locate a TypeScript compiler already present in the workspace, or say so.
//
// WHY THIS IS ITS OWN MODULE. Two gates need the same answer: `check-types.mjs` (does a strict
// client accept the shipped .d.ts?) and `check-jsdoc.mjs` (do the JSDoc annotations in lib/ agree
// with it?). Duplicating the search would let the two gates disagree about which compiler they
// tested against -- the same class of drift this repo refuses elsewhere.
//
// WHY A SEARCH AND NOT A DEPENDENCY. This package's outline is "zero install dependencies", and
// that is a product promise, not an accident: `clone && install` must not pull a toolchain. A
// missing compiler is therefore an ENVIRONMENT FACT, never a defect in the plugin -- every caller
// must turn `null` into a NAMED SKIP rather than a red gate.
//
// The search deliberately does not reach past three levels up: a compiler twenty directories away
// in an unrelated checkout is a coincidence, and building a gate on a coincidence is how a gate
// becomes a machine-specific pass.
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Find `typescript/bin/tsc` under `start`, descending at most `depth` levels.
 * @param {string} start Directory to search from.
 * @param {number} [depth] Remaining descent budget.
 * @returns {string|null} Absolute path of the tsc entry script, or null.
 */
export function findTsc(start, depth = 0) {
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

/**
 * The `@types` directory that belongs to a located compiler, or null.
 *
 * WHY IT MUST BE DERIVED, NOT CONFIGURED. A repo file cannot name an absolute path into somebody
 * else's checkout -- that is a machine-specific constant that breaks on the next clone and lies in
 * CI. The compiler sits at `<root>/node_modules/typescript/bin/tsc`, and the ambient types that
 * compiler is meant to be used with sit at `<root>/node_modules/@types`; deriving it from the
 * compiler's own location keeps `tsconfig.checkjs.json` free of host paths while still resolving
 * `process`, `node:fs` and friends.
 * @param {string} tsc Absolute path of the tsc entry script.
 * @returns {string|null} Absolute path of the sibling `@types` directory, or null when absent.
 */
export function typesFor(tsc) {
  const nodeModules = join(tsc, '..', '..', '..');
  const at = join(nodeModules, '@types');
  try { if (statSync(at).isDirectory()) return at; } catch { return null; }
  return null;
}
