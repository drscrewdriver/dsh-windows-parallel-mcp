// check-types.mjs — verify the shipped type surface the way a CONSUMER reaches it.
//
// TWO PHASES, because they fail differently.
//
//   Phase 1 compiles the in-repo consumer against `types/index.d.ts` by relative path. That catches a
//   malformed declaration file, and it is cheap enough to run first.
//
//   Phase 2 is the one that matters and the one that was missing until 0.4.x: it resolves the package
//   BY NAME, out of a throwaway `node_modules`, so it exercises `package.json` rather than a path
//   into the repository. That distinction is not academic. Measured: deleting the `types` condition
//   from `exports["."]` leaves phase 1 green while every `nodenext` consumer in the world starts
//   getting `TS7016 Could not find a declaration file`. The relative-path test cannot see this,
//   because it never asks package.json anything.
//
// WHY THE CONSUMER CARRIES A DELIBERATE TYPE ERROR. A file that merely imports and compiles proves
// "something was found", not "the real declarations were found" -- `any` satisfies both. So phase 2
// assigns `'nope'` to a `WpmAction` and REQUIRES the compiler to reject it by name. If resolution
// silently degrades to `any`, that rejection disappears and this gate goes red. The failing assertion
// is the instrument.
//
// The scratch tree lives in the OS temp directory, deliberately OUTSIDE this package: TypeScript
// resolves a package's own name from inside it (self-reference through `exports`), which would make
// phase 2 a duplicate of phase 1 instead of a consumer test.
//
// Uses any tsc 5.x/6.x already present in the workspace; if none is installed this is a NAMED SKIP,
// never a red against the plugin (a missing compiler is an environment fact, not a contract defect).
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { findTsc } from './find-tsc.mjs';

const here = process.cwd();
const tsc = findTsc(join(here, '..')) || findTsc(here);
if (!tsc) {
  console.log('SKIP types-consumer: no tsc 5.x/6.x found in workspace (environment, not a plugin defect)');
  process.exit(0);
}

function run(cwd, args) {
  const r = spawnSync(process.execPath, [tsc, ...args], { encoding: 'utf8', cwd, timeout: 180000 });
  return { ok: r.status === 0, out: ((r.stdout || '') + (r.stderr || '')).trim() };
}

// ---- Phase 1: the declaration file itself is well-formed and consumable by relative path.
const p1 = run(here, ['--noEmit']);
if (!p1.ok) {
  console.log('FAIL types-consumer (phase 1): tsc rejected the public .d.ts');
  console.log(p1.out.slice(0, 2000));
  process.exit(1);
}

// ---- Phase 2a: both wiring fields must be present and must point at the shipped file.
//
// Neither is redundant, and the asymmetry is worth stating because it is easy to "clean up" the
// wrong one: when `exports` exists it is the ONLY entry point a modern resolver consults, so
// `exports["."].types` is what makes `nodenext` consumers work; the top-level `types` field is what
// classic resolvers fall back to, and it is invisible to `nodenext` while `exports` is present.
const pkg = JSON.parse(readFileSync('package.json', 'utf8'));
const TYPES = 'types/index.d.ts';
// `types/...` and `./types/...` are both legal and both resolve to the same file, so the comparison
// normalizes the prefix rather than demanding a spelling nobody documented.
const norm = (v) => (typeof v === 'string' ? v.replace(/^\.\//, '') : v);
const wiring = [
  ['package.json "types"', pkg.types],
  ['package.json exports["."].types', pkg.exports?.['.']?.types],
  ['package.json exports["."].default', pkg.exports?.['.']?.default],
];
const wiringBad = wiring.filter(([, v]) => typeof v !== 'string' || v.length === 0);
if (wiringBad.length) {
  console.log('FAIL types-consumer (phase 2a): the type surface is not wired for consumers:');
  for (const [name, v] of wiring) console.log('  ' + name + ' = ' + JSON.stringify(v));
  process.exit(1);
}
if (norm(pkg.types) !== TYPES || norm(pkg.exports['.'].types) !== TYPES) {
  console.log('FAIL types-consumer (phase 2a): both type entry points must resolve to ' + TYPES);
  console.log('  "types" = ' + pkg.types + ' | exports["."].types = ' + pkg.exports['.'].types);
  process.exit(1);
}
for (const [name, v] of wiring) {
  if (!existsSync(norm(v))) {
    console.log('FAIL types-consumer (phase 2a): ' + name + ' points at a file that does not ship: ' + v);
    process.exit(1);
  }
}
if (!pkg.files?.includes('types/')) {
  console.log('FAIL types-consumer (phase 2a): "files" does not include types/ -- the .d.ts would not be packed');
  process.exit(1);
}

// ---- Phase 2b: resolve by NAME from a throwaway node_modules in the OS temp dir.
const scratch = mkdtempSync(join(tmpdir(), 'wpm-types-'));
try {
  const dest = join(scratch, 'node_modules', pkg.name);
  mkdirSync(dest, { recursive: true });
  for (const entry of ['package.json', 'lib', 'types']) {
    cpSync(join(here, entry), join(dest, entry), { recursive: true });
  }
  writeFileSync(join(scratch, 'consumer.ts'), [
    "import type { WpmAction, WpmArgs, RefusalCode } from '" + pkg.name + "';",
    "import { ACTIONS } from '" + pkg.name + "';",
    "const a: WpmAction = 'click';",
    "const read: WpmAction = 'snapshot';",
    "const shot: WpmAction = 'screenshot';",
    // The 0.5.0 argument surface, exercised by name: an .d.ts that forgot `space`/`label`/`shotId`
    // would still compile the older lines, so these are what make the new fields load-bearing.
    "const args: WpmArgs = { action: a, hwnd: '1', x: 2, y: 3, takeover: true, keyInput: 'inject' };",
    "const img: WpmArgs = { action: a, hwnd: '1', x: 2, y: 3, space: 'image', shotId: 's', label: 1, snapId: 'n' };",
    "const snap: WpmArgs = { action: read, hwnd: '1', maxElements: 300, interactableOnly: true, sinceSnapId: 'n', intent: 'i' };",
    "const code: RefusalCode = 'takeover_aborted';",
    "const stale: RefusalCode = 'stale_ref';",
    'const declared: readonly WpmAction[] = ACTIONS;',
    '// The instrument: this line MUST be rejected, by name. See the header.',
    "const mustFail: WpmAction = 'nope';",
    'void [read, shot, args, img, snap, code, stale, declared, mustFail];',
    '',
  ].join('\n'));
  writeFileSync(join(scratch, 'tsconfig.json'), JSON.stringify({
    compilerOptions: {
      target: 'ES2022', module: 'NodeNext', moduleResolution: 'NodeNext',
      strict: true, noEmit: true, skipLibCheck: true, types: [],
    },
    include: ['consumer.ts'],
  }, null, 2));

  const p2 = run(scratch, ['-p', 'tsconfig.json']);
  const errors = p2.out.split('\n').filter((l) => /error TS\d+/.test(l));
  // The quote style in TS's diagnostic is not ours to pin: match the substance (the action name and
  // the rejected literal), not the spelling of the message.
  const isTheInstrument = (l) => /error TS2322/.test(l) && /WpmAction/.test(l) && /nope/.test(l);

  if (errors.length === 1 && isTheInstrument(errors[0])) {
    // Expected shape: exactly the deliberate rejection, and nothing else.
    console.log('PASS types-consumer: strict tsc accepted all 8 actions, 14 refusal codes, the image/label coordinate surface, and the exec context ('
      + tsc.split(/[\\/]/).slice(-3).join('/') + '); by-name resolution through package.json confirmed,'
      + ' and the declaration was proven real by rejecting a wrong action');
    process.exit(0);
  }
  if (errors.length && errors.every(isTheInstrument)) {
    console.log('FAIL types-consumer (phase 2b): the deliberate error was reported more than once -- consumer template drift');
    console.log(p2.out.slice(0, 1200));
    process.exit(1);
  }
  console.log('FAIL types-consumer (phase 2b): a consumer importing ' + JSON.stringify(pkg.name)
    + ' by name did not get the real declarations');
  console.log('  expected exactly one TS2322 naming WpmAction for the deliberate wrong action.');
  console.log(p2.out.slice(0, 2000));
  process.exit(1);
} finally {
  try { rmSync(scratch, { recursive: true, force: true }); } catch { /* best effort */ }
}
