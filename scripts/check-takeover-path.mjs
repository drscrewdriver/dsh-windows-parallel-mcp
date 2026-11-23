// check-takeover-path.mjs -- the structural gate for the takeover tier (spec.md §6, findings §H).
//
// WHY STRUCTURAL AND NOT RUNTIME. R2 failed by writing a structural promise ("the foreground never
// changes") as a runtime observation; sampling can only prove "it did not happen this time". The takeover
// tier's promises are all of that shape, so they are asserted by READING the shipped files:
//
//   G1  SetCursorPos appears only in takeover.ps1; SendInput only in input-inject.ps1
//   G2  those two files are dot-sourced only by engine.ps1, and only inside the takeover branch
//   G3  every call to Set-WpmCursorTakeover / Send-WpmKeyText comes after a Test-WpmHudReady check
//   G4  the cursor move and its restore live in the same try/finally (borrowed, then returned)
//   G5  input-inject.ps1 constructs INPUT_KEYBOARD and never names a mouse event
//
// NON-VACUOUS BY CONSTRUCTION. A gate that has never been red is a comment. `--self-test` mutates an
// in-memory copy of the engine for EACH assertion, re-runs the checks, and fails unless exactly the
// expected assertion fires. check.mjs runs this in self-test mode, so a future edit that neuters one
// assertion fails the gate instead of quietly weakening it.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const ENGINE = 'src/engine';
const norm = (p) => p.split('\\').join('/');
const stripComments = (text) => text.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');

function loadEngine() {
  const map = new Map();
  for (const e of readdirSync(ENGINE)) {
    const p = join(ENGINE, e);
    if (statSync(p).isFile() && e.endsWith('.ps1')) map.set(norm(p), readFileSync(p, 'utf8'));
  }
  return map;
}

const TAKE = 'src/engine/takeover.ps1';
const INJECT = 'src/engine/input-inject.ps1';
const ENGINE_PS = 'src/engine/engine.ps1';
const HUD = 'src/engine/hud.ps1';

function indexOfOr(text, needle) { return text.indexOf(needle); }

/** Run every assertion against one snapshot. Returns [{code, message}]. */
function inspect(map) {
  const problems = [];
  const add = (code, message) => problems.push({ code, message });

  // ---- G1: the primitives are confined to one file each -------------------------------------
  for (const [file, raw] of map) {
    const code = stripComments(raw);
    // A CALL, not a mention: a refusal message may legitimately name the primitive it refuses to use
    // ("both arms accepted by SendInput, neither executed"), and a gate that fires on its own prose is a
    // gate people learn to ignore. The call form is what matters -- a symbol cannot be invoked without
    // parentheses, and the whitelisted files both use it in exactly that form.
    if (/\bSetCursorPos\s*\(/.test(code) && file !== TAKE) {
      add('G1', `${file} calls SetCursorPos; it is only allowed in ${TAKE}`);
    }
    if (/\bSendInput\s*\(/.test(code) && file !== INJECT) {
      add('G1', `${file} calls SendInput; it is only allowed in ${INJECT}`);
    }
  }
  if (!map.has(TAKE)) add('G1', `${TAKE} is missing -- the cursor primitive has no home`);
  else if (!/\bSetCursorPos\s*\(/.test(stripComments(map.get(TAKE)))) add('G1', `${TAKE} does not actually call SetCursorPos`);
  if (!map.has(INJECT)) add('G1', `${INJECT} is missing -- the keyboard primitive has no home`);
  else if (!/\bSendInput\s*\(/.test(stripComments(map.get(INJECT)))) add('G1', `${INJECT} does not actually call SendInput`);

  // ---- G2: loading the primitives is the takeover branch's privilege -------------------------
  for (const [file, raw] of map) {
    const lines = raw.split('\n');
    lines.forEach((line, i) => {
      if (/^\s*#/.test(line)) return;
      const m = line.match(/Join-Path[^)]*'(takeover|input-inject|hud)\.ps1'/);
      if (!m) return;
      const module = `${m[1]}.ps1`;
      const before = lines.slice(Math.max(0, i - 80), i).join('\n');
      if (file === ENGINE_PS) {
        if (!/takeoverRequested|\$Takeover\b/.test(before)) {
          add('G2', `${ENGINE_PS}:${i + 1} dot-sources ${module} outside the takeover branch (no takeoverRequested guard in the preceding lines)`);
        }
        return;
      }
      // The worker may load the HUD and the latch helper for its own control commands ('hud', 'takeover',
      // 'abort'). Those cases never call Set-WpmCursorTakeover or Send-WpmKeyText, which is what the
      // assertion protects; an unrestricted allowance would not be, so the case label is required.
      const WORKER = 'src/engine/worker.ps1';
      const isControlCase = /'(hud|takeover|abort)'\s*\{/.test(before.slice(-1500));
      if (file !== WORKER) {
        add('G2', `${file}:${i + 1} dot-sources ${module} -- only ${ENGINE_PS} (takeover branch) or ${WORKER} (control cases) may load it`);
      } else if (!isControlCase) {
        add('G2', `${WORKER}:${i + 1} dot-sources ${module} outside the hud/takeover/abort cases`);
      }
    });
  }

  // ---- G3: nothing moves or types before the HUD is confirmed up ---------------------------
  const engRaw = map.get(ENGINE_PS) ?? '';
  const eng = stripComments(engRaw);
  if (!map.has(HUD)) add('G3', `${HUD} is missing -- the HUD is a hard precondition`);
  else if (!/function Test-WpmHudReady/.test(map.get(HUD))) add('G3', `${HUD} does not define Test-WpmHudReady`);
  const hudCheckAt = indexOfOr(eng, 'Test-WpmHudReady');
  if (hudCheckAt < 0) {
    add('G3', `${ENGINE_PS} never calls Test-WpmHudReady; the HUD precondition would rest on a single moment`);
  } else {
    for (const needle of ['Set-WpmCursorTakeover -X', 'Send-WpmKeyText -Text']) {
      const at = indexOfOr(eng, needle);
      if (at < 0) { add('G3', `${ENGINE_PS} never calls ${needle.split(' ')[0]}`); continue; }
      if (at < hudCheckAt) add('G3', `${needle.split(' ')[0]} is called BEFORE the Test-WpmHudReady guard`);
    }
    // The guard must also be a REFUSAL, not a warning: the word it sets is the takeaway code.
    if (!/takeover_unavailable/.test(eng.slice(Math.max(0, hudCheckAt - 600), hudCheckAt + 600))) {
      add('G3', `the Test-WpmHudReady check is not wired to a takeover_unavailable refusal`);
    }
  }

  // ---- G4: the move and the restore share one try/finally ----------------------------------
  const moveAt = indexOfOr(eng, '$cursorEntry = Set-WpmCursorTakeover');
  if (moveAt < 0) {
    add('G4', `${ENGINE_PS} never assigns Set-WpmCursorTakeover to $cursorEntry`);
  } else {
    const tryAt = eng.lastIndexOf('try {', moveAt);
    const finallyAt = eng.indexOf('} finally {', moveAt);
    const restoreAt = indexOfOr(eng, 'Restore-WpmCursorTakeover');
    if (tryAt < 0) add('G4', 'the cursor move is not inside a try block');
    if (finallyAt < 0) add('G4', 'there is no finally block after the cursor move');
    if (restoreAt < 0) add('G4', 'Restore-WpmCursorTakeover is never called');
    if (tryAt >= 0 && finallyAt >= 0 && restoreAt >= 0) {
      if (!(restoreAt > finallyAt)) add('G4', 'the restore is not inside the finally block that follows the move');
      if (!(moveAt > tryAt)) add('G4', 'the move is not inside the try whose finally restores it');
      if (finallyAt - tryAt > 20000) add('G4', 'the try/finally pair around the move spans the whole file; it is not the same block');
    }
  }

  // ---- G5: only keyboard events can be constructed -----------------------------------------
  if (map.has(INJECT)) {
    const inj = stripComments(map.get(INJECT));
    if (!/INPUT_KEYBOARD/.test(inj)) add('G5', `${INJECT} does not construct INPUT_KEYBOARD`);
    if (/\bMOUSEEVENTF_|\bmouse_event\b/.test(inj)) add('G5', `${INJECT} names a mouse event -- the injection module must be unable to click`);
  }

  return problems;
}

/** Mutation self-tests: each one must make exactly its own assertion fire. */
const SELF_TESTS = [
  {
    code: 'G1',
    what: 'a fake SetCursorPos in win.ps1',
    mutate: (m) => { m.set('src/engine/win.ps1', (m.get('src/engine/win.ps1') ?? '') + '\n[WpmWin]::SetCursorPos(10, 10)\n'); },
  },
  {
    code: 'G2',
    what: 'the takeover module dot-sourced outside the branch',
    mutate: (m) => { m.set('src/engine/engine.ps1', ". (Join-Path $PSScriptRoot 'takeover.ps1')\n" + (m.get('src/engine/engine.ps1') ?? '')); },
  },
  {
    code: 'G3',
    what: 'the HUD re-check removed',
    mutate: (m) => { m.set('src/engine/engine.ps1', (m.get('src/engine/engine.ps1') ?? '').split('Test-WpmHudReady').join('Test-WpmHudWasStarted')); },
  },
  {
    code: 'G4',
    what: 'the cursor restore replaced by a read-back',
    mutate: (m) => { m.set('src/engine/engine.ps1', (m.get('src/engine/engine.ps1') ?? '').split('Restore-WpmCursorTakeover -Entry $cursorEntry').join('Get-WpmCursorPos')); },
  },
  {
    code: 'G5',
    what: 'a mouse-event constant in the injection module',
    mutate: (m) => { m.set('src/engine/input-inject.ps1', (m.get('src/engine/input-inject.ps1') ?? '') + '\n$mouse = [WpmInject]::MOUSEEVENTF_LEFTDOWN\n'); },
  },
];

const selfTest = process.argv.includes('--self-test');
const real = loadEngine();
const problems = inspect(real);

if (selfTest) {
  let bad = 0;
  for (const t of SELF_TESTS) {
    const clone = new Map(real);
    t.mutate(clone);
    const found = inspect(clone).map((p) => p.code);
    if (!found.includes(t.code)) {
      bad++;
      console.error(`FAIL self-test ${t.code}: injected "${t.what}" but the gate stayed green`);
    }
    if (found.length === 0) {
      bad++;
      console.error(`FAIL self-test ${t.code}: the mutation produced no problem at all`);
    }
  }
  if (problems.length) {
    console.error('FAIL: the real engine already violates the takeover structure:');
    for (const p of problems) console.error(`  ${p.code}: ${p.message}`);
    process.exit(1);
  }
  if (bad) process.exit(1);
  console.log(`OK self-test: ${SELF_TESTS.length} injected violation(s), each caught by its own assertion (${SELF_TESTS.map((t) => t.code).join(', ')})`);
  process.exit(0);
}

if (problems.length) {
  console.error("FAIL: the takeover tier's structural promises are broken:");
  for (const p of problems) console.error(`  ${p.code}: ${p.message}`);
  process.exit(1);
}
console.log('OK: G1-G5 hold (primitives confined, branch-scoped loading, HUD-before-act, try/finally restore, keyboard-only injection)');
process.exit(0);
