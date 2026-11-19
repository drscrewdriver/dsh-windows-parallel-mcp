// check-refusals.mjs — gate: the refusal vocabulary exists in exactly one shape, in three places.
//
// WHY THIS IS A GATE. A refusal code is the whole diagnostic value of the product: the model
// branches on it, the owner reads it. Three copies of that vocabulary live in this repo —
// decide.ps1/engine.ps1 (what can fire), src/schema/tools.json (what the tool contract promises),
// docs/refusals.md (what the reader is told). The moment one copy drifts, a code fires in
// production that the documentation does not explain, or a code is documented that nothing can
// emit — and both of those are indistinguishable from a working product until someone is already
// stuck. Earlier in this repo the same drift class (a stale verdict string, a documented gate that
// no branch produced) was found only by re-reading; this check costs milliseconds.
//
// WHAT IT DOES NOT DO. It cannot prove a documented code is reachable — `elevated_target` is
// documented and, today, fires only in the decision table because the detection is deliberately
// unwired. That is stated in docs/refusals.md and labelled SIMULATED in the cases; the gate checks
// structure, the run checks behaviour.
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const read = (p) => readFileSync(p, 'utf8');
const problems = [];

// --- 1. codes the code can emit -------------------------------------------------------------
const codeFiles = ['src/engine/decide.ps1', 'src/engine/engine.ps1'];
const emitted = new Map(); // code -> ['file:line', ...]
for (const f of codeFiles) {
  const lines = read(f).split('\n');
  lines.forEach((ln, i) => {
    // Both `refusal = 'x'` (decide's return tables) and `$result.refusal = 'x'` (the executor).
    const m = ln.match(/refusal\s*=\s*'([a-z_]+)'/);
    if (m) {
      const at = `${f}:${i + 1}`;
      if (!emitted.has(m[1])) emitted.set(m[1], []);
      emitted.get(m[1]).push(at);
    }
  });
}

// The decision-layer closed set is declared as a hashtable; reading its keys as well means a code
// that is declared but never returned (or returned but never documented in the table) shows up.
const decideSrc = read('src/engine/decide.ps1');
const block = decideSrc.match(/\$script:WpmRefusals\s*=\s*@\{([\s\S]*?)\n\}/);
if (!block) problems.push('src/engine/decide.ps1: could not find the $WpmRefusals hashtable');
else {
  for (const ln of block[1].split('\n')) {
    const m = ln.match(/^\s*([a-z_]+)\s*=\s*'/);
    if (m && !emitted.has(m[1])) {
      problems.push(`src/engine/decide.ps1: '${m[1]}' is declared in $WpmRefusals but never returned by any branch`);
    }
  }
}

// --- 2. codes the tool contract promises ----------------------------------------------------
const schema = JSON.parse(read('src/schema/tools.json'));
const contract = new Map(schema.refusals.map((r) => [r.code, r]));
const toolsByName = new Map(schema.tools.map((t) => [t.name, t]));

for (const code of emitted.keys()) {
  if (!contract.has(code)) problems.push(`code '${code}' is emitted (${emitted.get(code).join(', ')}) but absent from src/schema/tools.json refusals`);
}
for (const code of contract.keys()) {
  if (!emitted.has(code)) problems.push(`code '${code}' is declared in tools.json but no branch in src/engine can emit it`);
}
for (const [code, at] of emitted) {
  const declaredLayer = contract.get(code)?.layer;
  const isRuntime = at.every((p) => p.startsWith('src/engine/engine.ps1'));
  if (declaredLayer && isRuntime && declaredLayer !== 'runtime') {
    problems.push(`code '${code}' is documented as layer '${declaredLayer}' but fires only from engine.ps1 (${at.join(', ')})`);
  }
  if (declaredLayer && !isRuntime && declaredLayer !== 'decision') {
    problems.push(`code '${code}' is documented as layer '${declaredLayer}' but fires from a decision branch (${at.join(', ')})`);
  }
}

// --- 3. codes the documentation shows -------------------------------------------------------
// The human table's first column is the documentation form of the same set. Parsed rather than
// duplicated in a list here: a third hand-kept copy would be the next thing to drift.
const doc = read('docs/refusals.md');
const documented = new Set();
for (const ln of doc.split('\n')) {
  const m = ln.match(/^\|\s*`([a-z_]+)`\s*\|/);
  if (m) documented.add(m[1]);
}
if (!documented.size) problems.push('docs/refusals.md: no code table rows found (expected lines starting with "| `code` |")');
for (const code of documented) if (!contract.has(code)) problems.push(`docs/refusals.md documents '${code}' which tools.json does not declare`);
for (const code of contract.keys()) if (!documented.has(code)) problems.push(`tools.json declares '${code}' which docs/refusals.md does not document`);

// --- 4. the executable refusal cases --------------------------------------------------------
const ALLOWED_PLACEHOLDERS = new Set(['$deadHwnd', '$liveHwnd', '$winformsHwnd', '$missingName']);
const MODES = new Set(['engine', 'decision', 'none']);
const seenIds = new Set();
const covered = new Set();

for (const c of schema.refusalCases) {
  if (!c.id) problems.push('refusalCase without an id');
  if (seenIds.has(c.id)) problems.push(`duplicate refusalCase id '${c.id}'`);
  seenIds.add(c.id);
  if (!MODES.has(c.mode)) problems.push(`case '${c.id}': mode '${c.mode}' is not one of ${[...MODES].join('|')}`);
  // `tool: null` is the table-level guard: needs_facts protects the decision table when it is used
  // on its own and can never surface through a tool, so pretending it belongs to one would be the
  // fiction this gate exists to prevent.
  const tableLevel = c.tool === null;
  if (tableLevel) {
    if (c.mode !== 'decision') problems.push(`case '${c.id}': a table-level case must use decision mode`);
  } else {
    const tool = toolsByName.get(c.tool);
    if (!tool) problems.push(`case '${c.id}': unknown tool '${c.tool}'`);
    else if (!tool.refusals.includes(c.expect)) problems.push(`case '${c.id}': expect '${c.expect}' is not in ${c.tool}.refusals`);
  }
  if (!contract.has(c.expect)) problems.push(`case '${c.id}': expect '${c.expect}' is not a declared code`);
  if (!c.note) problems.push(`case '${c.id}': no note -- an unexplained case cannot be re-read later`);
  if (c.mode === 'decision' && !('facts' in c)) problems.push(`case '${c.id}': decision mode needs a facts object`);
  if (c.mode === 'engine' && !c.args) problems.push(`case '${c.id}': engine mode needs args`);
  if (c.mode === 'none') continue;
  covered.add(c.expect);
  const placeholders = JSON.stringify(c.args ?? c.facts ?? '').match(/\$[A-Za-z]+/g) ?? [];
  for (const p of placeholders) if (!ALLOWED_PLACEHOLDERS.has(p)) problems.push(`case '${c.id}': placeholder '${p}' has no binding in test/refusals-test.ps1`);
}

// Coverage is a claim, so it is checked in two parts: every code must have a case, and a code with
// no EXECUTABLE case must carry an uncoveredReason in the contract. Marking a code 'not covered'
// is acceptable; marking it so silently is not -- that is how an empty arm starts speaking.
for (const code of contract.keys()) {
  const cases = schema.refusalCases.filter((c) => c.expect === code);
  if (!cases.length) problems.push(`code '${code}' has no case at all`);
  if (!covered.has(code)) {
    const reason = contract.get(code)?.uncoveredReason;
    if (!reason) problems.push(`code '${code}' has no executable case and no uncoveredReason in tools.json refusals`);
  }
}

// --- 5. read-only tools must say why they cannot refuse -------------------------------------
for (const t of schema.tools) {
  if (t.refusals.length === 0 && !t.noRefusalReason) {
    problems.push(`tool '${t.name}' declares no refusals and no reason -- either add refusals or state why the tool cannot refuse`);
  }
  const cases = schema.refusalCases.filter((c) => c.tool === t.name && c.mode !== 'none');
  if (t.refusals.length > 0 && cases.length === 0) problems.push(`tool '${t.name}' can refuse but has no case`);
}

// The word below must never appear as a field in the action contract: the product does not inject
// synthetic input, and a schema field would advertise the opposite.
if (/"physical"\s*:/i.test(read('src/schema/tools.json'))) problems.push('src/schema/tools.json declares a "physical" field -- this product does not inject synthetic input');

if (problems.length) {
  console.error(`FAIL: ${problems.length} refusal-vocabulary problem(s).\n`);
  for (const p of problems) console.error('  ' + p);
  console.error('\nKeep three copies in step: decide.ps1/engine.ps1 (what fires), src/schema/tools.json');
  console.error('(what is promised), docs/refusals.md (what is explained).');
  process.exit(1);
}
const uncovered = [...contract.keys()].filter((c) => !covered.has(c));
console.log(`OK: ${contract.size} refusal code(s) emitted = promised = documented; ${schema.refusalCases.length} case(s) declared, ${covered.size} executable, ${uncovered.length} declared uncovered with a reason${uncovered.length ? ' (' + uncovered.join(', ') + ')' : ''}.`);
