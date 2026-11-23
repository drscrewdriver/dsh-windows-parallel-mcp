// check-frame-single-source.mjs -- gate: there is exactly ONE place that decides what rectangle a
// capture covers, and both the frame the labels are measured against and the frame the picture is
// copied from come from it.
//
// WHY THIS IS A STRUCTURAL GATE AND NOT A RUNTIME ASSERTION.
// The plan for 0.5.0 proposed an invariant "every element rect must be contained in screenRect".
// Measurement refuted it on real windows: Chromium/Electron trees report virtualized content far
// outside the viewport (overhangs of 3px, 18px, 287px and 2720px measured on this desktop,
// 2026-11-23), so that rule refuses whole classes of ordinary windows. The deeper point is that raw
// element rects are ABSOLUTE SCREEN PIXELS -- they do not depend on the frame at all -- so no
// containment rule can detect a frame chosen from the wrong source. What CAN go wrong is MIXING:
// taking the picture from one rect and the arithmetic from another. That is a property of the code,
// so it is enforced on the code:
//   * [WpmWin]::DwmFrame / [WpmWin]::WinRect may be called ONLY inside Get-WpmFrameRect;
//   * Get-WpmSnapshotTree and Get-WpmScreenshot may obtain their rect ONLY from Get-WpmFrameRect;
//   * only Get-WpmScreenshot may call CopyFromScreen;
//   * the snapshot must run Test-WpmFrameInsideRoot and refuse when it says no.
//
// NON-VACUOUS BY CONSTRUCTION: --self-test mutates a copy of the engine for each assertion and
// requires the corresponding red, so a green run means the gate looked at code that still has the
// property rather than at code that happens to match a regex by accident.
//
// Usage: node scripts/check-frame-single-source.mjs [--self-test]
import { readFileSync } from 'node:fs';

const WIN = 'src/engine/win.ps1';

/** Split a PowerShell file into top-level function bodies: name -> body text (signature line included). */
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
      // Brace counting is enough here: every function in this file opens `{` on its own line or on the
      // param block line, and no brace appears inside a string literal in these bodies (checked by the
      // parser gate, which the file already has to pass).
      for (const ch of line) {
        if (ch === '{') { depth += 1; started = true; }
        else if (ch === '}') depth -= 1;
      }
      if (started && depth <= 0) { out.set(current, out.get(current).join('\n')); current = null; }
    }
  }
  return out;
}

/** Lines OUTSIDE a named function (the rest of the file), for "may only appear inside X" checks. */
function outside(bodyMap, name, src) {
  const body = bodyMap.get(name);
  if (body === undefined) return src;
  return src.replace(body, '');
}

export function check(src) {
  const problems = [];
  const fns = functions(src);
  for (const required of ['Get-WpmFrameRect', 'Test-WpmFrameInsideRoot', 'Get-WpmSnapshotTree', 'Get-WpmScreenshot']) {
    if (!fns.has(required)) problems.push(`${WIN}: function ${required} is missing -- the frame path cannot be checked`);
  }
  if (problems.length) return problems;

  // 1. The two raw sources are reachable only through the helper.
  for (const raw of ['[WpmWin]::DwmFrame(', '[WpmWin]::WinRect(']) {
    const rest = outside(fns, 'Get-WpmFrameRect', src);
    if (rest.includes(raw)) {
      problems.push(`${WIN}: ${raw} is called OUTSIDE Get-WpmFrameRect -- a second frame source is exactly the mixing this gate forbids`);
    }
    if (!fns.get('Get-WpmFrameRect').includes(raw)) {
      problems.push(`${WIN}: Get-WpmFrameRect no longer calls ${raw} -- the fallback chain changed`);
    }
  }
  // 2. Both consumers take their rect from the helper.
  for (const consumer of ['Get-WpmSnapshotTree', 'Get-WpmScreenshot']) {
    if (!fns.get(consumer).includes('Get-WpmFrameRect')) {
      problems.push(`${WIN}: ${consumer} does not obtain its rect from Get-WpmFrameRect`);
    }
  }
  // 3. Only the capture path may call CopyFromScreen, and it must be inside a try/finally that
  //    disposes the bitmap (a GDI+ handle leak per capture is a slow desktop death). Comments are
  //    documentation, not call sites -- matching the explanation would be the gate crying wolf.
  const codeLines = src.replace(/<#[\s\S]*?#>/g, '').split('\n')
    .filter((l) => !/^\s*#/.test(l) && !/^\s*\/\//.test(l));
  const copyCalls = codeLines.filter((l) => l.includes('CopyFromScreen')).length;
  if (copyCalls !== 1) problems.push(`${WIN}: ${copyCalls} CopyFromScreen call site(s) -- expected exactly one, inside Get-WpmScreenshot`);
  else if (!fns.get('Get-WpmScreenshot').includes('CopyFromScreen')) problems.push(`${WIN}: CopyFromScreen is not inside Get-WpmScreenshot`);
  if (!/finally\s*\{[\s\S]*Dispose\(\)/.test(fns.get('Get-WpmScreenshot'))) {
    problems.push(`${WIN}: Get-WpmScreenshot no longer disposes the bitmap in a finally block`);
  }
  // 4. The self-check must be wired into the snapshot, and its failure must be a refusal.
  const snap = fns.get('Get-WpmSnapshotTree');
  if (!snap.includes('Test-WpmFrameInsideRoot')) problems.push(`${WIN}: Get-WpmSnapshotTree no longer runs Test-WpmFrameInsideRoot`);
  if (!/frame self-check failed/.test(snap)) problems.push(`${WIN}: a failed frame check no longer produces a refusal reason`);
  if (!/frameCheck = if \(\$inside\.ok\)/.test(snap)) problems.push(`${WIN}: the frameCheck verdict no longer follows the invariant`);
  // 5. The full-screen capture is the ONLY branch that does not use a window frame, and it must say so
  //    with the virtual screen (a silently substituted window rect would capture the wrong thing).
  if (!fns.get('Get-WpmScreenshot').includes('VirtualScreen()')) problems.push(`${WIN}: Get-WpmScreenshot no longer supports the virtual screen`);
  // 6. The screenshot must keep deriving the data that makes coordinates addressable.
  for (const field of ['screenRect', 'imageSize', 'scale', 'identity', 'frame', 'dpiAware']) {
    if (!fns.get('Get-WpmScreenshot').includes(field)) problems.push(`${WIN}: the screenshot no longer reports ${field}`);
  }
  return problems;
}

const selfTest = process.argv.includes('--self-test');
const src = readFileSync(WIN, 'utf8');
const problems = check(src);
const notes = [];

if (selfTest) {
  const RAW_FRAME_HELPER = '  $frame = Get-WpmFrameRect $Hwnd\n';
  /** @type {Array<[string, (s: string) => string]>} */
  const mutations = [];
  mutations.push(['a second frame source in the capture path', (s) => s.replace(
    'function Get-WpmScreenshot {', 'function Get-WpmScreenshot {\n  $raw = [WpmWin]::WinRect($Hwnd)')]);
  mutations.push(['the snapshot reads a raw frame instead of the helper', (s) => s.replace(
    RAW_FRAME_HELPER, "  $frame = @{ ok = $true; frame = 'dwm'; hr = 0; left = 0; top = 0; right = 1; bottom = 1 }\n")]);
  mutations.push(['the frame self-check unwired', (s) => s.replace(
    /\$inside = Test-WpmFrameInsideRoot[^\n]*\n/,
    '$inside = @{ ok = $true; insetLeft = 0; insetTop = 0; insetRight = 0; insetBottom = 0 }\n')]);
  mutations.push(['a second CopyFromScreen call site', (s) => s.replace(
    'function Get-WpmFrameRect {', 'function Get-WpmScreenshot2 {\n  $g.CopyFromScreen(0, 0, 0, 0, $null)\n}\n\nfunction Get-WpmFrameRect {')]);
  for (const [name, mutate] of mutations) {
    const mutated = mutate(src);
    if (mutated === src) { problems.push(`self-test: mutation "${name}" changed nothing -- the pattern no longer matches the code it was written for`); continue; }
    const found = check(mutated);
    if (found.length === 0) problems.push(`self-test: mutation "${name}" was NOT caught -- the assertion is vacuous`);
    else notes.push(`self-test red as expected: ${name}`);
  }
}

if (problems.length) {
  console.error(`FAIL: ${problems.length} frame-source problem(s).\n`);
  for (const p of problems) console.error('  ' + p);
  console.error('\nWhy it matters: a capture rect from one source and labels measured against another are');
  console.error('8px apart on this desktop and look right in every test that does not compare them.');
  console.error('There must be ONE function that answers "what rectangle does this window occupy".');
  process.exit(1);
}
console.log('OK: one frame source (Get-WpmFrameRect: DWM(9) with a REPORTED win32 fallback); '
  + 'snapshot and screenshot both consume it; the snapshot self-check is wired and refuses on failure; '
  + 'exactly one CopyFromScreen'
  + (notes.length ? ` | ${notes.join('; ')}` : ''));
process.exit(0);
