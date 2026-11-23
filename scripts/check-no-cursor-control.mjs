// check-no-cursor-control.mjs -- the build-time gate that makes the input stance STRUCTURAL.
//
// WHAT CHANGED IN R3 AND WHY THIS FILE WAS REWRITTEN RATHER THAN RELAXED. Through 0.1.x the claim was
// "the shipped engine contains no primitive that can move the cursor or synthesize input" -- decidable,
// zero false positives, and far stronger than sampling a live desktop (an idle baseline measured the
// desktop moving the cursor by itself, so a runtime sensor cannot blame motion on us at all). R3 keeps
// that strength instead of trading it away: SetCursorPos and SendInput stay BANNED everywhere except one
// named file each, and the ban on everything that could turn them into MOUSE input or a global hook stays
// repo-wide. So the claim is now:
//
//   * SetCursorPos  -- allowed ONLY in src/engine/takeover.ps1
//   * SendInput     -- allowed ONLY in src/engine/input-inject.ps1
//   * MOUSEEVENTF_*, mouse_event, keybd_event, EVENT_* -- BANNED in every engine file
//
// The mouse ban is not decoration: with only INPUT_KEYBOARD constructible, an injector cannot click,
// drag or warp anything even if a future edit tries. check-takeover-path.mjs adds the order/structure
// assertions (HUD first, try/finally around the move) on top of this file-permission table.
//
// NON-VACUOUS BY CONSTRUCTION: the whitelisted files must EXIST, and this gate prints both counts, so a
// rename that made the whitelist empty would show up as "0 allowed" rather than as a green run.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const ALLOWED = {
  SetCursorPos: 'src/engine/takeover.ps1',
  SendInput: 'src/engine/input-inject.ps1',
};

// Anything here can move the real cursor, synthesize input, or install a global hook. Banned everywhere.
const FORBIDDEN = [
  { re: /\bMOUSEEVENTF_[A-Z_]*/, name: 'MOUSEEVENTF_* (constructs a mouse event)' },
  { re: /\bmouse_event\b/, name: 'mouse_event (legacy synthetic click)' },
  { re: /\bkeybd_event\b/, name: 'keybd_event (legacy synthetic key)' },
  { re: /\bEVENT_(MOUSE|KEYBOARD)/, name: 'WinEventHook injection constants' },
];

const roots = ['src/engine'];
const files = [];
for (const rt of roots) {
  try {
    for (const e of readdirSync(rt)) {
      const p = join(rt, e);
      if (statSync(p).isFile() && /\.(ps1|mjs|js)$/.test(e)) files.push(p.split('\\').join('/'));
    }
  } catch { /* missing root is itself a failure below */ }
}
if (files.length === 0) {
  console.error('FAIL: no engine files found under ' + roots.join(', ') + ' -- the gate would pass vacuously');
  process.exit(1);
}

const hits = [];
const allowedHits = [];
for (const f of files) {
  const text = readFileSync(f, 'utf8');
  // Comments are documentation, not code: win.ps1's header explains the bans, and matching the
  // explanation would be the gate crying wolf at its own text.
  const code = text
    .split('\n')
    .filter((l) => !/^\s*#/.test(l) && !/^\s*\/\//.test(l) && !/^\s*\/\*|^\s*\*/.test(l))
    .join('\n');
  for (const { re, name } of FORBIDDEN) {
    const m = re.exec(code);
    if (m) hits.push(`${f}: ${name} -> "${m[0]}"`);
  }
  for (const [symbol, file] of Object.entries(ALLOWED)) {
    // CALL form only: engine files legitimately NAME these primitives when explaining what they refuse
    // to do (decide.ps1's terminal refusal cites the measurement). A symbol cannot be invoked without
    // parentheses, so the call is the thing to confine.
    const m = new RegExp('\\b' + symbol + '\\s*\\(').exec(code);
    if (!m) continue;
    if (f === file) allowedHits.push(`${f}: ${symbol} (whitelisted)`);
    else hits.push(`${f}: ${symbol} is only allowed in ${file}`);
  }
}

// A whitelisted primitive that no file uses means the whitelist is a fiction -- or the file was renamed.
for (const [symbol, file] of Object.entries(ALLOWED)) {
  if (!files.includes(file.split('\\').join('/'))) {
    hits.push(`${symbol} is whitelisted for ${file}, which does not exist`);
    continue;
  }
  if (!allowedHits.some((h) => h.startsWith(`${file.split('\\').join('/')}: ${symbol} `))) {
    hits.push(`${file} is whitelisted for ${symbol} but never uses it`);
  }
}

if (hits.length) {
  console.error('FAIL: the shipped engine violates the input stance:');
  for (const h of hits) console.error('  ' + h);
  console.error('fix: SetCursorPos belongs to takeover.ps1 and SendInput to input-inject.ps1, nowhere else.');
  console.error('     Mouse events stay forbidden in every file -- the takeover tier moves the cursor instead of');
  console.error('     clicking synthetically, which is why "the agent can drive a terminal" does not become');
  console.error('     "the agent can click anything".');
  process.exit(1);
}
console.log(`OK: ${files.length} engine file(s) scanned; ${allowedHits.length} whitelisted primitive use(s) (${allowedHits.join(', ')}); no mouse/hook injection anywhere`);
process.exit(0);
