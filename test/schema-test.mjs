// schema-test.mjs — the action contract, checked as a contract rather than as a file that exists.
//
// WHY THIS IS A TEST AND NOT REVIEW. src/schema/tools.json is the surface a model branches on:
// eight tools, their arguments, and the refusal codes each can return. Four classes of mistake in
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
import { readFileSync, existsSync } from 'node:fs';
import { PARAMETERS } from '../lib/host-tools.js';

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

// Grown with the contract, and the growth is the point of listing it here at all: 0.5.0 added three read
// actions and 0.7.0 added three desktop actions, so the set a model can reach is eleven. An extra name
// here is a contract change; a missing one is a tool nothing can call.
const EXPECTED = ['wpm_windows', 'wpm_click', 'wpm_type', 'wpm_focus', 'wpm_status', 'wpm_snapshot',
  'wpm_screenshot', 'wpm_preview', 'wpm_launch', 'wpm_clipboard', 'wpm_window'];
const names = schema.tools.map((t) => t.name);
for (const n of EXPECTED) if (!names.includes(n)) fail(`missing tool '${n}'`);
for (const n of names) if (!EXPECTED.includes(n)) fail(`unexpected tool '${n}' (the surface is fixed at eleven; adding one is a contract change)`);
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

// --- 0.7.0: the rung every action must declare ------------------------------------------------
// Checked here as well as in scripts/check-policy-table.mjs because this file owns "the contract is
// internally sound" while that gate owns "the three copies agree". Both are cheap; neither subsumes the
// other, and the failure mode they share -- an action nobody classified -- is the one that turns a
// permission setting into decoration.
for (const tool of schema.tools) {
  if (typeof tool.requiresTier !== 'string' || !['readonly', 'quiet', 'flash', 'takeover'].includes(tool.requiresTier)) {
    fail(`${tool.name}: requiresTier must be declared and one of readonly|quiet|flash|takeover (got ${JSON.stringify(tool.requiresTier)})`);
  }
  if (tool.requiresTierFor) {
    for (const [op, tier] of Object.entries(tool.requiresTierFor)) {
      if (!['readonly', 'quiet', 'flash', 'takeover'].includes(tier)) fail(`${tool.name}.requiresTierFor.${op}: '${tier}' is not a rung`);
    }
  }
}

// --- the host projection agrees with the registered parameters ------------------------------
// The form is decided (A: DSH native plugin, spec.md R3.1'). That makes the projection part of the
// contract rather than a private detail: the eight named actions are what the docs promise, the one
// registered tool is what the model actually gets, and the two must describe the same capability.
{
  const proj = schema.hostProjection;
  if (!proj) fail('no hostProjection -- the delivery form is decided, so the projection belongs in the contract');
  else {
    if (proj.form !== 'A') fail(`hostProjection.form is '${proj.form}'; the owner chose A on 2026-11-19`);
    if (!proj.why) fail('hostProjection has no stated reason');
    const contractNames = schema.tools.map((t) => t.name).sort();
    const mappedNames = Object.keys(proj.actions ?? {}).sort();
    if (JSON.stringify(contractNames) !== JSON.stringify(mappedNames)) {
      fail(`hostProjection.actions keys ${JSON.stringify(mappedNames)} != contract tool names ${JSON.stringify(contractNames)}`);
    }
    const contractActions = schema.tools.map((t) => t.action).sort();
    const mappedActions = Object.values(proj.actions ?? {}).sort();
    if (JSON.stringify(contractActions) !== JSON.stringify(mappedActions)) {
      fail(`hostProjection action values ${JSON.stringify(mappedActions)} != contract actions ${JSON.stringify(contractActions)}`);
    }
    if (!existsSync(proj.source.split('#')[0])) fail(`hostProjection.source points at a missing file: ${proj.source}`);
    // Every required argument a contract tool names must be sendable through the one registered
    // tool, or the model is told to send something the registry rejects.
    for (const tool of schema.tools) {
      for (const arg of tool.inputSchema.required ?? []) {
        if (arg === 'action') continue;
        if (!(arg in PARAMETERS)) fail(`contract ${tool.name} requires '${arg}', which the registered tool does not accept`);
      }
    }
    for (const extra of proj.extraWorkerActions ?? []) {
      if (extra.exposed !== false) fail(`extraWorkerAction '${extra.action}' must be marked exposed:false (or it belongs in the contract)`);
      if (!extra.why) fail(`extraWorkerAction '${extra.action}' has no stated reason`);
      if ((proj.actions && Object.values(proj.actions).includes(extra.action))) {
        fail(`extraWorkerAction '${extra.action}' is also a projected action`);
      }
    }
    // And the model-facing parameter names must not include an input-method switch.
    if ('physical' in PARAMETERS) fail('registered parameters expose a physical field');
  }
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
