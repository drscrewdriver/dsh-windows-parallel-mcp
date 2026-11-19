// schema-test.mjs — the action contract, checked as a contract rather than as a file that exists.
//
// WHY THIS IS A TEST AND NOT REVIEW. src/schema/tools.json is the surface a model branches on:
// five tools, their arguments, and the refusal codes each can return. Four classes of mistake in
// it are invisible until an agent is already confused at runtime:
//   * a required field that is not declared in properties (the model cannot know the type);
//   * an argument accepted by a case but rejected by the schema (the documented example is wrong);
//   * a tool whose declared refusals do not match what the engine can actually return;
//   * a field named for an input method this product explicitly does not use.
// None of them throw. All of them are one loop over the file.
//
// It validates the schema itself with a deliberately small JSON Schema subset (type / required /
// additionalProperties / minimum / maximum): the point is to catch a wrong contract, not to
// re-implement validator semantics. Exit code 1 on any problem.
import { readFileSync } from 'node:fs';

const schema = JSON.parse(readFileSync('src/schema/tools.json', 'utf8'));
const problems = [];
const fail = (m) => problems.push(m);

// --- the small validator --------------------------------------------------------------------
function validate(sch, value, path) {
  const t = sch.type;
  if (t === 'object') {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) { fail(`${path}: expected object`); return; }
    for (const r of sch.required ?? []) if (!(r in value)) fail(`${path}: missing required '${r}'`);
    const props = sch.properties ?? {};
    for (const k of Object.keys(value)) {
      if (!(k in props)) {
        if (sch.additionalProperties === false) fail(`${path}: undeclared property '${k}'`);
        continue;
      }
      validate(props[k], value[k], `${path}.${k}`);
    }
    return;
  }
  if (t === 'integer') {
    if (!Number.isInteger(value)) { fail(`${path}: expected integer, got ${JSON.stringify(value)}`); return; }
    if (sch.minimum !== undefined && value < sch.minimum) fail(`${path}: ${value} < minimum ${sch.minimum}`);
    if (sch.maximum !== undefined && value > sch.maximum) fail(`${path}: ${value} > maximum ${sch.maximum}`);
    return;
  }
  if (t === 'string') {
    // Placeholders ($liveHwnd, ...) are resolved by test/refusals-test.ps1 at run time; at contract
    // level they are strings, which is also the type they resolve to.
    if (typeof value !== 'string') fail(`${path}: expected string, got ${typeof value}`);
    return;
  }
  if (t === 'boolean') { if (typeof value !== 'boolean') fail(`${path}: expected boolean, got ${typeof value}`); return; }
  fail(`${path}: schema uses unsupported type '${t}'`);
}

// --- the contract's own shape ---------------------------------------------------------------
if (!schema.stance || !schema.stance.inputQueue || !schema.stance.cursor) fail('schema.stance must state what the engine does not do');

const EXPECTED = ['wpm_windows', 'wpm_click', 'wpm_type', 'wpm_focus', 'wpm_status'];
const names = schema.tools.map((t) => t.name);
for (const n of EXPECTED) if (!names.includes(n)) fail(`missing tool '${n}'`);
for (const n of names) if (!EXPECTED.includes(n)) fail(`unexpected tool '${n}' (the surface is fixed at five; adding one is a contract change)`);
if (new Set(names).size !== names.length) fail('duplicate tool name');

for (const tool of schema.tools) {
  if (!tool.action) fail(`${tool.name}: no action mapping`);
  if (!tool.engine) fail(`${tool.name}: no engine mapping -- a tool the engine cannot serve is a promise, not a contract`);
  if (!tool.description || tool.description.length < 60) fail(`${tool.name}: description too thin to select the tool by`);
  const is = tool.inputSchema;
  if (!is || is.type !== 'object') { fail(`${tool.name}: inputSchema must be an object schema`); continue; }
  if (is.additionalProperties !== false) fail(`${tool.name}: inputSchema must set additionalProperties:false, or a typo in an argument name is silently ignored`);
  for (const r of is.required ?? []) {
    if (!(r in (is.properties ?? {}))) fail(`${tool.name}: required '${r}' is not declared in properties`);
  }
  for (const [k, p] of Object.entries(is.properties ?? {})) {
    if (!p.description) fail(`${tool.name}.${k}: property has no description`);
    if (p.type === 'integer' && p.default !== undefined) {
      if (p.default < (p.minimum ?? -Infinity) || p.default > (p.maximum ?? Infinity)) fail(`${tool.name}.${k}: default outside its own bounds`);
    }
  }
  // The one field that must never appear: an input-method switch would advertise a capability the
    // product does not have and cannot test.
  if ('physical' in (is.properties ?? {})) fail(`${tool.name}: inputSchema must not expose a 'physical' field`);
}

// --- arguments in the documented cases must be arguments the schema accepts ------------------
for (const c of schema.refusalCases) {
  if (c.mode !== 'engine') continue;
  if (c.tool === null) { fail(`${c.id}: engine-mode case must name a tool`); continue; }
  const tool = schema.tools.find((t) => t.name === c.tool);
  if (!tool) continue; // check-refusals.mjs reports the unknown tool
  validate(tool.inputSchema, c.args, `${c.id}.args`);
}

// --- the delivery form must not have leaked into the contract -------------------------------
// The form (plugin vs MCP) is undecided; a contract written against one form cannot be served by
// the other. Checked as text so a stray 'mcp' path in a description is caught too.
for (const tool of schema.tools) {
  const s = JSON.stringify(tool);
  for (const forbidden of ['cordis', 'mcpServers', 'stdio', 'dsh.plugin.json']) {
    if (s.includes(forbidden)) fail(`${tool.name}: contract mentions '${forbidden}' -- the action surface must stay form-neutral until task_56 decides the form`);
  }
}

if (problems.length) {
  console.error(`FAIL: ${problems.length} contract problem(s).\n`);
  for (const p of problems) console.error('  ' + p);
  process.exit(1);
}
console.log(`OK: ${schema.tools.length} tools, ${schema.refusals.length} refusal codes, ${schema.refusalCases.length} case(s) validated against the contract.`);
