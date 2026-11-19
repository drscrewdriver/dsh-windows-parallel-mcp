// verify-install.mjs — install this package into a throwaway DSH profile and boot it.
//
// WHY THIS IS NOT PART OF THE DEFAULT GATE. It writes a profile under $DSH_HOME, so it is a deliberate
// act rather than something that runs on every `npm test`. But it is the only check that answers the
// question the product is actually judged on: *does this package activate when the host installs it?*
//
// THREE FAILURES IT EXISTS FOR, all found by running it and none visible to a unit test:
//   * `Config` exported as a factory -> "Cannot read properties of undefined (reading 'validate')"
//     and the plugin never activates;
//   * `async apply` -> "Invalid effect" and the plugin never activates;
//   * a patch row or `files` entry that is wrong -> install succeeds, nothing registers.
// In every one of those cases the profile boots "fine", one warning scrolls past, and the tool simply
// does not exist. That is the worst failure mode this product has, so it gets a real boot.
//
// The profile is created, checked, and REMOVED. If it already exists, the script refuses rather than
// deleting something it did not create.
//
// Usage: node scripts/verify-install.mjs [--profile <name>] [--keep]
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = resolve(HERE, '..');
const args = process.argv.slice(2);
const keep = args.includes('--keep');
const profileFlag = args.indexOf('--profile');
const profile = profileFlag >= 0 ? args[profileFlag + 1] : 'wpm-verify';

const DSH_HOME = process.env.DSH_HOME || join(process.env.USERPROFILE || process.env.HOME || '', '.dsh');
const profileDir = join(DSH_HOME, 'profiles', profile);

function findDshBin() {
  // Resolve the host CLI the way the launcher does. `dsh.cmd` is a Node shim and cannot be spawned
  // reliably from this shell on this host (it exits 126), so the JS entry is used directly.
  const candidates = [
    join(process.env.ProgramFiles || 'C:\\Program Files', 'nodejs', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'),
    join('C:\\nodejs', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'),
  ];
  for (const c of candidates) if (existsSync(c)) return c;
  return null;
}

const bin = findDshBin();
if (!bin) {
  console.error('SKIP: could not locate the dsh CLI entry (looked in the usual nodejs install locations).');
  process.exit(1);
}

if (existsSync(profileDir) && !keep) {
  console.error(`refusing to run: profile '${profile}' already exists at ${profileDir}.`);
  console.error('Remove it yourself, or pass a different --profile name. This script deletes what it creates,');
  console.error('and nothing else.');
  process.exit(1);
}

const run = (argv, timeout = 240000) => spawnSync(process.execPath, [bin, ...argv], {
  encoding: 'utf8', timeout, cwd: PKG_ROOT,
});

let failures = 0;
const ok = (name, pass, detail = '') => {
  if (pass) console.log(`  PASS  ${name}`);
  else { failures += 1; console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
};

try {
  console.log(`package: ${PKG_ROOT}`);
  console.log(`profile: ${profile} (${profileDir})`);

  const add = run(['plugin', '--profile', profile, 'add', PKG_ROOT]);
  ok('the host installs the package', add.status === 0, (add.stderr || add.stdout || '').slice(-300));
  if (add.status !== 0) throw new Error('install failed; nothing to boot');

  const bundleJson = join(profileDir, 'package.json');
  const bundled = existsSync(bundleJson) ? JSON.parse(readFileSync(bundleJson, 'utf8')) : {};
  const bundles = bundled?.dsh?.profile?.bundles ?? [];
  ok('the host added the bundle to the profile', bundles.includes('dsh-windows-parallel-mcp'), JSON.stringify(bundles));

  const dump = run(['--profile', profile, '--dump-config']);
  ok('the composed profile tree contains our row', /id:\s*windows-parallel/.test(dump.stdout || ''),
    (dump.stdout || '').slice(0, 200));

  // The decisive one. `headless` with a prompt boots the whole plugin graph; a plugin that fails to
  // activate is named in the warning block. Its ABSENCE from that block is the pass condition --
  // presence of "ok" output would be the wrong signal (this profile has no model credentials).
  const boot = run(['--profile', profile, 'headless', 'reply with the single word ok'], 180000);
  const output = `${boot.stdout || ''}${boot.stderr || ''}`;
  const namedInWarnings = /windows-parallel/.test(output);
  ok('the plugin activates when the host boots it', !namedInWarnings,
    output.split('\n').filter((l) => l.includes('windows-parallel')).slice(0, 3).join(' | '));

  console.log('\n--- boot output (first 12 lines) ---');
  console.log(output.split('\n').slice(0, 12).join('\n'));
} catch (err) {
  failures += 1;
  console.error(`  FAIL  ${err?.message ?? err}`);
} finally {
  if (!keep && existsSync(profileDir)) {
    rmSync(profileDir, { recursive: true, force: true });
    console.log(`\ncleaned up: removed ${profileDir}`);
  } else if (keep) {
    console.log(`\nkept: ${profileDir} (--keep)`);
  }
}

console.log(`\nverify-install: ${failures === 0 ? 'PASS' : 'FAIL'}`);
process.exit(failures === 0 ? 0 : 1);
