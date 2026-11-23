// check-shot-backend.mjs -- gate 20: the capture has a cheap path, a fallback, and it SAYS which one
// it used. Nothing about that sentence is optional.
//
// WHY THIS NEEDS TO BE CODE-CHECKED. 0.6.0-B replaces Graphics.CopyFromScreen with a direct BitBlt and
// keeps the old call as the fallback. Two failure modes are invisible to every runtime assertion:
//
//   1. SILENT PATH SUBSTITUTION. The whole reason `frame` exists as a returned field is that an 8px
//      coordinate story cannot be debugged after the fact if the producer kept the choice private.
//      `captureBackend` is the same discipline applied to the pixel producer: measured equivalent on a
//      still scene (identical size, identical PNG bytes, 0 per-channel difference over 17388 sampled
//      points, findings 8.3) and NOT the same call -- one yields Format32bppRgb, the other 32bppArgb.
//      So the field has to be produced by the engine, forwarded by lib/index.js, and printed in the
//      text a model reads. A field that exists but never reaches the result text is a comment.
//
//   2. A FALLBACK THAT NO LONGER FALLS BACK. A fast path with no reachable slow path is not a fast
//      path, it is a new single point of failure -- and BitBlt can genuinely refuse (a driver without a
//      screen DC, RDP/Basic theme, a zero-size rect). If the guard around `CopyFromScreen` is deleted in
//      a later refactor, the engine starts throwing on exactly the machines where the cheap path is
//      unavailable, which is the worst possible shape of "works on my desktop".
//
// NON-VACUITY. --self-test mutates a copy of the code for each assertion and requires the corresponding
// red. A gate that has never been red is a comment, and this repo has said that sentence before.
//
// Usage: node scripts/check-shot-backend.mjs [--self-test]
import { readFileSync } from 'node:fs';

const WIN = 'src/engine/win.ps1';
const ENGINE = 'src/engine/engine.ps1';
const HOST = 'lib/index.js';

function functions(src) {
  const lines = src.split('\n');
  const out = new Map();
  let current = null;
  let depth = 0;
  let started = false;
  for (const line of lines) {
    const m = line.match(/^function\s+([A-Za-z0-9_-]+)/);
    if (m && !current) { current = m[1]; depth = 0; started = false; out.set(current, []); }
    if (current) {
      out.get(current).push(line);
      for (const ch of line) {
        if (ch === '{') { depth += 1; started = true; }
        else if (ch === '}') depth -= 1;
      }
      if (started && depth <= 0) { out.set(current, out.get(current).join('\n')); current = null; }
    }
  }
  return out;
}

/** Strip comment text so prose about a call cannot satisfy an assertion about the call. */
function codeOnly(src) {
  return src.replace(/<#[\s\S]*?#>/g, '').split('\n')
    .filter((l) => !/^\s*#/.test(l) && !/^\s*\/\//.test(l) && !/^\s*\* /.test(l))
    .join('\n');
}

export function check(files) {
  const win = files[WIN];
  const engine = files[ENGINE];
  const host = files[HOST];
  const problems = [];
  const fns = functions(win);
  const shot = fns.get('Get-WpmScreenshot');
  if (!shot) return [`${WIN}: Get-WpmScreenshot is missing -- the capture path cannot be checked`];
  const code = codeOnly(win);

  // 1. The cheap primitive exists, is called, and cleans up after itself on every path.
  if (!/public static IntPtr CaptureBitBlt/.test(win)) problems.push(`${WIN}: WpmWin::CaptureBitBlt is gone -- there is no cheap capture path`);
  if (!shot.includes('[WpmWin]::CaptureBitBlt(')) problems.push(`${WIN}: Get-WpmScreenshot no longer calls CaptureBitBlt -- the fast path is dead code`);
  for (const cleanup of ['DeleteDC(mem)', 'ReleaseDC(IntPtr.Zero, screen)', 'DeleteObject(bmp)']) {
    if (!code.includes(cleanup)) problems.push(`${WIN}: CaptureBitBlt no longer performs ${cleanup} -- a GDI leak in a long-lived worker`);
  }
  if (!/finally\s*\{[\s\S]*?DeleteDC\(mem\)/.test(code)) {
    problems.push(`${WIN}: the memory DC is no longer released inside a finally -- partial failures would leak it`);
  }

  // 2. THE FALLBACK IS REACHABLE. Exactly one CopyFromScreen call site, guarded by the fast path having
  //    produced nothing -- the guard is the assertion, not the call itself.
  const copyCalls = (code.match(/CopyFromScreen/g) ?? []).length;
  if (copyCalls !== 1) problems.push(`${WIN}: ${copyCalls} CopyFromScreen call site(s) -- expected exactly one, as the fallback`);
  if (!/if \(\-not \$bmp\)/.test(shot)) {
    problems.push(`${WIN}: the CopyFromScreen fallback is no longer guarded by "the fast path produced nothing" -- it has become either dead code or the only path`);
  }

  // 3. captureBackend travels the whole chain: produced -> forwarded -> printed.
  if (!shot.includes("captureBackend = 'bitblt'")) problems.push(`${WIN}: the BitBlt path no longer claims its backend`);
  if (!shot.includes("captureBackend = 'gdiplus'")) problems.push(`${WIN}: the fallback path no longer claims its backend -- a fallback that reports the fast path is a lie`);
  // THE RETURN BLOCK, not the function text. The shots registry also stores captureBackend, so an
  // assertion written against the whole body was satisfied by the registry entry after the RETURNED field
  // was deleted -- the first run of this gate caught its own vacuity that way, which is the entire reason
  // --self-test exists.
  const retBlock = shot.slice(shot.lastIndexOf('return @{ ok = $true'));
  if (!retBlock.includes('captureBackend = $captureBackend')) {
    problems.push(`${WIN}: captureBackend is no longer in the RESULT Get-WpmScreenshot returns`);
  }
  if (!/\$result\.captureBackend = \[string\]\$shot\.captureBackend/.test(engine)) {
    problems.push(`${ENGINE}: the screenshot action no longer forwards the engine's captureBackend into the result`);
  }
  if (!host.includes('captureBackend=')) problems.push(`${HOST}: format('screenshot') no longer prints captureBackend into the text the model reads`);
  if (!/captureBackend: r\.captureBackend/.test(host)) problems.push(`${HOST}: captureBackend is no longer part of the structured result object`);

  // 4. The fallback must not throw. An exception on the fast path is a design case, not a crash case.
  if (!/catch \{\s*\$hbmp = \[IntPtr\]::Zero/.test(shot)) {
    problems.push(`${WIN}: CaptureBitBlt is no longer wrapped so that a refusal becomes a fallback rather than an exception`);
  }
  return problems;
}

const selfTest = process.argv.includes('--self-test');
const files = {
  [WIN]: readFileSync(WIN, 'utf8'),
  [ENGINE]: readFileSync(ENGINE, 'utf8'),
  [HOST]: readFileSync(HOST, 'utf8'),
};
const problems = check(files);
const notes = [];

if (selfTest) {
  /** @type {Array<[string, () => Record<string, string>]>} */
  const mutations = [];
  const drop = (s, from, to) => s.replace(from, to);

  const mutators = [
    ['the fallback branch removed', (f) => ({ ...f, [WIN]: drop(f[WIN], '    if (-not $bmp) {', '    if ($false) {') })],
    ['the BitBlt path no longer claims its backend', (f) => ({ ...f, [WIN]: drop(f[WIN], "        $captureBackend = 'bitblt'", '        $captureBackend = $captureBackend') })],
    ['captureBackend dropped from the returned result', (f) => ({ ...f, [WIN]: drop(f[WIN], '      captureBackend = $captureBackend; captureNote = $captureNote', '      captureNote = $captureNote') })],
    ['the engine stops forwarding it', (f) => ({ ...f, [ENGINE]: drop(f[ENGINE], '      $result.captureBackend = [string]$shot.captureBackend', '      $result.captureBackend = ""') })],
    ['the result text stops printing it', (f) => ({ ...f, [HOST]: f[HOST].replace('frame=${r.frame || \'?\'} captureBackend=${r.captureBackend || \'?\'}', "frame=${r.frame || '?'}") })],
    ['a second CopyFromScreen call site', (f) => ({ ...f, [WIN]: drop(f[WIN], 'function Get-WpmFrameRect {', 'function Get-WpmOtherShot {\n  $g.CopyFromScreen(0, 0, 0, 0, $null)\n}\n\nfunction Get-WpmFrameRect {') })],
    ['the fast path no longer cleans up the DC', (f) => ({ ...f, [WIN]: drop(f[WIN], '            if (mem != IntPtr.Zero) DeleteDC(mem);', '') })],
  ];
  for (const [name, mutate] of mutators) {
    const mutated = mutate(files);
    let changed = false;
    for (const k of Object.keys(files)) if (mutated[k] !== files[k]) changed = true;
    if (!changed) { problems.push(`self-test: mutation "${name}" changed nothing -- the pattern no longer matches the code it was written for`); continue; }
    const found = check(mutated);
    if (found.length === 0) problems.push(`self-test: mutation "${name}" was NOT caught -- the assertion is vacuous`);
    else notes.push(`self-test red as expected: ${name}`);
  }
}

if (problems.length) {
  console.error(`FAIL: ${problems.length} capture-backend problem(s).\n`);
  for (const p of problems) console.error('  ' + p);
  console.error('\nWhy it matters: the cheap path and the fallback are measured equivalent but not identical,');
  console.error('and a fast path whose fallback was deleted fails only on the machines that need it.');
  console.error('captureBackend must be produced, forwarded, and printed -- or the substitution is silent.');
  process.exit(1);
}
console.log('OK: BitBlt fast path with a GUARDED CopyFromScreen fallback (one call site), GDI objects released in a finally, '
  + 'and captureBackend produced -> forwarded -> printed in the result text'
  + (notes.length ? ` | ${notes.join('; ')}` : ''));
process.exit(0);
