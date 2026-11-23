// check-shots.mjs -- gate: the screenshot directory cannot accumulate, and a "screenshot" with no
// picture in it cannot read as one.
//
// WHY THIS IS A GATE. Two failure shapes are invisible to every other check here:
//   * a capture path that writes the file but never prunes the directory, which quietly fills
//     %LOCALAPPDATA% (and the old shots are exactly the ones whose shotId a caller may still hold);
//   * a PNG that is 0 bytes or truncated, which still has the right NAME and path -- "the file exists"
//     is not "the file is a picture", and a caller reading it would be reading nothing.
// The runtime half validates the REAL directory when it exists; the structural half asserts the
// retention code and the %LOCALAPPDATA%\wpm\shots location are in the shipped engine; and --self-test
// proves both halves can go red (a gate that has never been red is a comment).
//
// Usage: node scripts/check-shots.mjs [--self-test]
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { CONFIG_DEFAULTS } from '../lib/config.js';

const WIN = 'src/engine/win.ps1';
const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/** Validate one PNG file. Returns null when it is a picture, else the reason it is not. */
export function pngProblem(file) {
  let st;
  try { st = statSync(file); } catch (e) { return `unreadable: ${e.message}`; }
  if (st.size === 0) return '0 bytes (an empty file named .png)';
  if (st.size < 8) return `${st.size} bytes (smaller than the PNG signature)`;
  const b = readFileSync(file);
  for (let i = 0; i < PNG_MAGIC.length; i += 1) {
    if (b[i] !== PNG_MAGIC[i]) return `bad magic at byte ${i} (saw 0x${b[i].toString(16)})`;
  }
  // A PNG also has to carry an IHDR chunk right after the signature: a file with the magic and
  // nothing else would pass a magic-only check.
  const ihdr = b.subarray(12, 16).toString('latin1');
  if (ihdr !== 'IHDR') return `no IHDR chunk after the signature (saw ${JSON.stringify(ihdr)})`;
  const width = b.readUInt32BE(16);
  const height = b.readUInt32BE(20);
  if (!width || !height) return `IHDR reports an empty image (${width}x${height})`;
  return null;
}

/** Validate a directory of shots. Returns a list of problem strings. */
export function validateDir(dir, keep) {
  const problems = [];
  if (!existsSync(dir)) return problems;            // nothing captured yet is not a failure
  const files = readdirSync(dir).filter((f) => f.toLowerCase().endsWith('.png'));
  if (files.length > keep) {
    problems.push(`${dir}: ${files.length} PNG(s) retained but shotsKeep=${keep} -- the retention pass is not pruning`);
  }
  for (const f of files) {
    const why = pngProblem(join(dir, f));
    if (why) problems.push(`${dir}/${f}: ${why}`);
  }
  return problems;
}

/** The structural half: the shipped engine has the location and the pruning. */
export function checkEngine(src = readFileSync(WIN, 'utf8')) {
  const problems = [];
  if (!/Get-WpmDataDir/.test(src) || !/'shots'/.test(src)) {
    problems.push(`${WIN}: no shots directory under the wpm data dir`);
  }
  if (!/LOCALAPPDATA/.test(src)) {
    problems.push(`${WIN}: the data dir no longer derives from %LOCALAPPDATA% (and the abort latch uses the same base)`);
  }
  if (!/Sort-Object LastWriteTimeUtc -Descending/.test(src)) {
    problems.push(`${WIN}: no newest-first ordering of the shots -- without it "retain the newest N" is undefined`);
  }
  if (!/for \(\$i = \$keepN; \$i -lt \$files\.Count; \$i\+\+\)/.test(src)) {
    problems.push(`${WIN}: the retention loop is gone (or no longer starts at keepN) -- the directory would grow without bound`);
  }
  if (!/Remove-Item -LiteralPath \$files\[\$i\]\.FullName/.test(src)) {
    problems.push(`${WIN}: the retention loop no longer deletes the older files`);
  }
  if (!/ImageFormat\]::Png/.test(src)) {
    problems.push(`${WIN}: the capture no longer saves as PNG`);
  }
  return problems;
}

const selfTest = process.argv.includes('--self-test');
const problems = [];
const notes = [];

// ---- structural: the real engine ------------------------------------------------------------
problems.push(...checkEngine());

// ---- structural, non-vacuity: mutations of the engine must be caught -------------------------
if (selfTest) {
  const base = readFileSync(WIN, 'utf8');
  const mutations = [
    ['retention loop removed', (s) => s.replace(/for \(\$i = \$keepN; \$i -lt \$files\.Count; \$i\+\+\) \{[\s\S]*?\n    \}/, '')],
    ['newest-first ordering removed', (s) => s.replace(/Sort-Object LastWriteTimeUtc -Descending/, '')],
    ['save format changed away from PNG', (s) => s.replace(/ImageFormat\]::Png/, 'ImageFormat]::Bmp')],
  ];
  for (const [name, mutate] of mutations) {
    const mutated = mutate(base);
    if (mutated === base) { problems.push(`self-test: mutation "${name}" changed nothing -- the pattern no longer matches the code it was written for`); continue; }
    const found = checkEngine(mutated);
    if (found.length === 0) problems.push(`self-test: mutation "${name}" was NOT caught -- the structural check is vacuous`);
    else notes.push(`self-test red as expected: ${name}`);
  }
}

// ---- runtime: the real directory, plus a planted-defect self-test ---------------------------
const keep = CONFIG_DEFAULTS.shotsKeep;
const realDir = process.env.LOCALAPPDATA ? join(process.env.LOCALAPPDATA, 'wpm', 'shots') : '';
let realChecked = 0;
if (realDir && existsSync(realDir)) {
  const found = validateDir(realDir, keep);
  realChecked = readdirSync(realDir).filter((f) => f.toLowerCase().endsWith('.png')).length;
  problems.push(...found);
}

if (selfTest) {
  const scratch = mkdtempSync(join(tmpdir(), 'wpm-shots-'));
  try {
    const good = join(scratch, 'good.png');
    writeFileSync(good, Buffer.from([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89,
    ]));
    writeFileSync(join(scratch, 'empty.png'), Buffer.alloc(0));
    writeFileSync(join(scratch, 'text.png'), 'this is not a picture');
    const flagged = validateDir(scratch, keep);
    if (flagged.length !== 2) problems.push(`self-test: expected exactly 2 planted defects (0-byte and non-PNG), got ${flagged.length}: ${flagged.join(' | ')}`);
    else notes.push('self-test red as expected: 0-byte PNG and non-PNG caught');
    if (pngProblem(good) !== null) problems.push('self-test: a valid 1x1 PNG was reported as broken -- the validator would reject real screenshots');
    // Retention: 3 files with a keep of 2 must be a problem.
    mkdirSync(join(scratch, 'many'));
    for (const n of ['a', 'b', 'c']) writeFileSync(join(scratch, 'many', `${n}.png`), readFileSync(good));
    if (validateDir(join(scratch, 'many'), 2).length === 0) problems.push('self-test: 3 files with keep=2 was NOT flagged -- the retention assertion is vacuous');
    else notes.push('self-test red as expected: retention overflow caught');
  } finally {
    try { rmSync(scratch, { recursive: true, force: true }); } catch { /* best effort */ }
  }
}

if (problems.length) {
  console.error(`FAIL: ${problems.length} screenshot hygiene problem(s).\n`);
  for (const p of problems) console.error('  ' + p);
  console.error('\nWhy it matters: a shots directory that never prunes fills %LOCALAPPDATA%, and a 0-byte');
  console.error('PNG is a file that exists without being a picture -- "the capture worked" would be a claim');
  console.error(`with nothing behind it. Directory checked: ${realDir || '(no LOCALAPPDATA)'}`);
  process.exit(1);
}
console.log(`OK: shots directory ${realDir || '(none)'} holds ${realChecked} PNG(s) (shotsKeep=${keep}); `
  + 'engine keeps %LOCALAPPDATA%\\wpm\\shots, orders newest-first, prunes, and saves PNG'
  + (notes.length ? ` | ${notes.join('; ')}` : ''));
process.exit(0);
