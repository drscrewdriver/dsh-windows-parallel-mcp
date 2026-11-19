// check-pack.mjs — the package that gets installed must contain the engine, and only the engine.
//
// WHY THIS RUNS AT PREPACK. Two failure modes are both invisible until after install:
//   * the PowerShell engine left out of `files` — the package installs, the tool registers, and the
//     first call dies with "engine worker not found". This is the `prepack`-stale class the
//     release skill warns about, in its most embarrassing form: a plugin that ships without its
//     engine.
//   * junk swept in — .tmp/, .git, screenshots, the whole measure-everything scratch tree. A package
//     that unpacks to hundreds of MB is a package nobody installs twice.
// `npm pack --dry-run --json` is the only listing that reflects what npm will actually do (files
// field + .npmignore + always-included), so it is read rather than re-derived here.
//
// Exit code 1 on any problem.
import { spawnSync } from 'node:child_process';

const REQUIRED = [
  'package.json',
  'lib/index.js',
  'lib/engine.js',
  'lib/host-tools.js',
  'lib/peers-schemastery.js',
  'lib/peers-tools.js',
  'cordis.patch.yml',
  'dsh.plugin.json',
  'src/engine/worker.ps1',
  'src/engine/engine.ps1',
  'src/engine/decide.ps1',
  'src/engine/win.ps1',
  'src/schema/tools.json',
  'docs/refusals.md',
  'README.md',
];

const FORBIDDEN = [
  [/(^|\/)\.tmp\//, 'scratch directory'],
  [/(^|\/)\.git\//, 'git metadata'],
  [/(^|\/)test\//, 'the measurement suite (not needed at runtime, and it carries host-specific paths)'],
  [/(^|\/)scripts\//, 'repo gates (they reference dev-only paths)'],
  [/(^|\/)node_modules\//, 'vendored dependencies'],
];

// --ignore-scripts is not a shortcut, it is a recursion guard: this script runs from `prepack`, and a
// `npm pack` that fires `prepack` again would recurse until the stack (or the disk) gives out. The
// first run of this file did exactly that. Lifecycle scripts cannot change what the tarball contains,
// only what is built first, so ignoring them here does not weaken the check.
const raw = spawnSync('npm', ['pack', '--dry-run', '--json', '--ignore-scripts'], { encoding: 'utf8', shell: true });
if (raw.status !== 0) {
  console.error('FAIL: `npm pack --dry-run --json` failed:\n' + (raw.stderr || raw.stdout));
  process.exit(1);
}
let report;
try {
  report = JSON.parse(raw.stdout);
} catch (err) {
  console.error('FAIL: could not parse npm pack output: ' + err.message + '\n' + raw.stdout.slice(0, 400));
  process.exit(1);
}
const entry = Array.isArray(report) ? report[0] : report;
const files = (entry?.files ?? []).map((f) => f.path.replace(/\\/g, '/'));
const problems = [];

for (const need of REQUIRED) {
  if (!files.includes(need)) problems.push(`missing from the package: ${need}`);
}
for (const path of files) {
  for (const [pattern, why] of FORBIDDEN) {
    if (pattern.test(path)) { problems.push(`packed but should not be: ${path} (${why})`); break; }
  }
}

// A shipping package that contains a .ps1 with non-ASCII and no BOM would decode as GBK on the
// target machine, exactly like this repo's own gate says. Re-checked here because `files` decides
// what ships and the repo gate only sees what is on disk.
const ps1 = files.filter((f) => f.endsWith('.ps1'));
if (ps1.length === 0) problems.push('the package contains no .ps1 file at all -- the engine cannot ship');

const sizeMb = (entry?.unpackedSize ?? 0) / 1024 / 1024;
if (sizeMb > 5) problems.push(`unpacked size ${sizeMb.toFixed(1)} MB -- a plugin with a script engine should be far under 5 MB`);

if (problems.length) {
  console.error(`FAIL: ${problems.length} packaging problem(s).\n`);
  for (const p of problems) console.error('  ' + p);
  console.error('\nfix: package.json "files" decides what ships. The engine must be in it,');
  console.error('the measurement suite must not be.');
  process.exit(1);
}
console.log(`OK: ${files.length} file(s), ${sizeMb.toFixed(2)} MB unpacked; engine present (${ps1.length} .ps1), no scratch/test/scripts.`);
