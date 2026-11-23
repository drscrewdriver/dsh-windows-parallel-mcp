// check-jsdoc.mjs — the JSDoc annotations in lib/ must be true statements about lib/.
//
// WHY THIS GATE EXISTS, GIVEN check-types.mjs ALREADY RUNS. They answer different questions.
// check-types.mjs proves a CLIENT can consume the shipped .d.ts; it says nothing about whether the
// IMPLEMENTATION agrees with that .d.ts. Without this gate the annotations are decoration: they
// drift silently, and the drift is discovered by whichever user hits it first. With it, the
// hand-written contract in types/index.d.ts becomes load-bearing from the inside too -- lib/index.js
// imports WpmArgs/RefusalCode from that file via @typedef, so renaming a field there turns THIS red.
//
// WHY allowJs + checkJs AND NOT A .ts REWRITE. Measured on this repository (findings §7): migrating
// lib/ to TypeScript sources costs 162 residual errors, breaks the `.gitignore` invariant that lib/
// is source rather than build output, cannot emit the `.mjs` file proof-window needs, and replaces a
// hand-written public contract (WpmAction/RefusalCode/WpmArgs) with a weaker generated one. The same
// code under checkJs costs 105 mechanical annotations and changes no runtime byte.
//
// WHY THE SAME NAMED SKIP AS check-types.mjs. No compiler in the workspace is an environment fact,
// not a defect in this plugin. A red gate that means "this machine lacks tsc" trains people to
// ignore red.
//
// WHAT IT DELIBERATELY DOES NOT DO. It does not install, vendor, or declare a compiler. This package
// ships zero install dependencies and that is a product promise (see peers-*.js for the same
// reasoning at the module boundary). The compiler is borrowed when present, skipped when absent.
//
// peers-schemastery.js and peers-tools.js are excluded by an in-file `// @ts-nocheck`, NOT by leaving
// them out of this config: excluding them makes the importer (config.js) fail with TS2307, which
// would be a gate reporting a problem it created itself.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { findTsc, typesFor } from './find-tsc.mjs';

const here = process.cwd();
const tsc = findTsc(join(here, '..')) || findTsc(here);
if (!tsc) {
  console.log('SKIP jsdoc-types: no tsc 5.x/6.x found in workspace (environment, not a plugin defect)');
  process.exit(0);
}

// `--typeRoots` is passed on the command line, never written into tsconfig.checkjs.json: a repo file
// must not carry an absolute path into somebody else's checkout. When there is no sibling @types the
// flag is omitted and the compiler falls back to its own defaults -- which is exactly what a clean
// clone without ambient types should see, rather than a machine-specific pass or a fabricated one.
const args = [tsc, '-p', 'tsconfig.checkjs.json'];
const at = typesFor(tsc);
if (at) args.push('--typeRoots', at);

const r = spawnSync(process.execPath, args, { encoding: 'utf8', cwd: here, timeout: 180000 });
const out = ((r.stdout || '') + (r.stderr || '')).trim();
const errors = out.split('\n').filter((l) => /error TS\d+/.test(l));

if (r.status !== 0 && errors.length === 0) {
  console.log('FAIL jsdoc-types: tsc failed without a diagnosable error (config?):');
  console.log(out.slice(0, 2000));
  process.exit(1);
}
if (errors.length) {
  const files = [...new Set(errors.map((l) => (l.match(/^([^(]+)\(/) || [])[1]).filter(Boolean))];
  console.log(`FAIL jsdoc-types: ${errors.length} error(s) across ${files.length} file(s) -- the annotations in lib/ do not describe the code:`);
  for (const l of errors.slice(0, 25)) console.log('  ' + l);
  if (errors.length > 25) console.log(`  ... and ${errors.length - 25} more`);
  process.exit(1);
}
const files = JSON.parse(readFileSync('tsconfig.checkjs.json', 'utf8')).files || [];
console.log(`PASS jsdoc-types: ${files.length} file(s) under allowJs+checkJs+strict, 0 errors`
  + (at ? ` (ambient types via ${at.split(/[\\/]/).slice(-2).join('/')})` : ' (no ambient @types)'));
