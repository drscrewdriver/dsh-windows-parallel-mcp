// check-no-cursor-control.mjs -- the build-time gate that makes the runtime cursor claim structural.
//
// WHY THIS GATE EXISTS AND WHY IT IS BETTER THAN THE SENSOR. The runtime proof measures cursor motion
// and can only say how much of it was NOT the human (GetLastInputInfo excludes the human; nothing in
// a coordinate stream excludes another process). Measured on this desktop with NOTHING of ours running,
// the cursor already showed unexplained motion across 3 separate gaps at 11px in 1 of 4 idle windows.
// So the sensor cannot reliably blame cursor motion on us -- and it must not pretend to; failing a
// clean action because the desktop moved is the wolf-cry trap. The claim "the real cursor never moves
// because of us" is therefore enforced WHERE IT CAN BE ENFORCED: the shipped engine must contain no
// primitive capable of moving the cursor or injecting input. That is decidable by reading the bytes,
// has zero false positives, and a regression that ADDS cursor control is caught at build time -- a
// 100x stronger guarantee than sampling for it at runtime.
//
// This mirrors the repo's own principle: enforce safety by architecture (the schema has no `physical`
// field at all, per the README), not by detecting violations of a promise the code could keep breaking.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

// Anything here can move the real cursor or synthesize input. Their absence is the whole claim.
const FORBIDDEN = [
  { re: /\bSetCursorPos\b/, name: 'SetCursorPos (moves the real cursor)' },
  { re: /\bSendInput\b/, name: 'SendInput (synthesizes input)' },
  { re: /\bmouse_event\b/, name: 'mouse_event (synthesizes a click)' },
  { re: /\bkeybd_event\b/, name: 'keybd_event (synthesizes a key)' },
  { re: /\bEVENT_(MOUSE|KEYBOARD)/, name: 'WinEventHook injection constants' },
];

// Read-only cursor queries: allowed, and REQUIRED for the proof sampler. Named explicitly so a future
// reader does not confuse "no cursor control" with "no cursor knowledge".
const roots = ['src/engine'];
const files = [];
for (const rt of roots) {
  try {
    for (const e of readdirSync(rt)) {
      const p = join(rt, e);
      if (statSync(p).isFile() && /\.(ps1|mjs|js)$/.test(e)) files.push(p);
    }
  } catch { /* missing root is itself a failure below */ }
}
if (files.length === 0) {
  console.error('FAIL: no engine files found under ' + roots.join(', ') + ' -- the gate would pass vacuously');
  process.exit(1);
}

const hits = [];
for (const f of files) {
  const text = readFileSync(f, 'utf8');
  // Strip line comments before matching: win.ps1's header DOCUMENTS that these calls are absent.
  // Matching the documentation of the ban would be the gate crying wolf at its own explanation.
  const code = text
    .split('\n')
    .filter((l) => !/^\s*#/.test(l) && !/^\s*\/\//.test(l) && !/^\s*\/\*|^\s*\*/.test(l))
    .join('\n');
  for (const { re, name } of FORBIDDEN) {
    const m = re.exec(code);
    if (m) hits.push(`${f}: ${name} -> "${m[0]}"`);
  }
}

if (hits.length) {
  console.error('FAIL: the shipped engine contains cursor/input control, breaking the product claim:');
  for (const h of hits) console.error('  ' + h);
  console.error('fix: the README promises "the real cursor never moves". If a physical tier is ever added');
  console.error('     deliberately, it is a product decision (the `physical` field must STAY absent from');
  console.error('     the schema), and the runtime cursor proof must be re-litigated, not quietly bypassed.');
  process.exit(1);
}
console.log(`OK: ${files.length} engine file(s) scanned, no cursor-moving or input-injecting primitive present`);
console.log('    (GetCursorPos/WindowFromPoint are read-only queries and are allowed -- the sampler needs them.)');
process.exit(0);
