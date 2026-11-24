// schema-test.mjs — the action contract, checked as a contract rather than as a file that exists.
//
// WHY THIS IS A TEST AND NOT REVIEW. src/schema/tools.json is the surface a model branches on:
// eleven actions, their arguments, and the refusal codes each can return. Four classes of mistake in
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
// The form is decided (A: DSH native plugin, spec.md R3.1', plus the 0.8.0 stdio form below). That makes
// the projection part of the contract rather than a private detail: the eleven named actions are what the
// docs promise, the one registered tool is what the model actually gets, and the two must describe the
// same capability.
{
  const proj = schema.hostProjection;
  if (!proj) fail('no hostProjection -- the delivery form is decided, so the projection belongs in the contract');
  else {
    if (proj.form !== 'A') fail(`hostProjection.form is '${proj.form}'; the owner chose A on 2026-11-19 and 0.8.0 did not replace it -- the MCP form is listed beside it as mcpProjection`);
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

// --- the 0.8.0 second form must be declared, and must be the SAME surface ----------------------
// Two delivery channels over one engine is the arrangement most likely to drift (risk R6), so the
// contract states both and this test states what they owe each other: same tool name, same
// discriminator, same action set, and every source it claims to read actually present on disk.
{
  const mcp = schema.mcpProjection;
  if (!mcp) fail('no mcpProjection -- 0.8.0 ships a second delivery form, and an undeclared form is how two copies start disagreeing');
  else {
    const host = schema.hostProjection ?? {};
    if (mcp.tool !== host.tool) fail(`mcpProjection.tool '${mcp.tool}' != hostProjection.tool '${host.tool}' -- one tool name across both forms is the whole point`);
    if (mcp.discriminator !== host.discriminator) fail(`mcpProjection.discriminator '${mcp.discriminator}' != hostProjection.discriminator '${host.discriminator}'`);
    if (mcp.package !== host.package) fail(`mcpProjection.package '${mcp.package}' != hostProjection.package '${host.package}'`);
    if (!mcp.why || !mcp.reversal) fail('mcpProjection must carry both its reason and the reversal of the 2026-11-19 decision -- a reversed decision that is not named reads as an accident');
    if (!/tools\/list is GENERATED/.test(String(mcp.schemaSource ?? ''))) fail('mcpProjection must say the schema is generated from this file, not copied');
    for (const f of [mcp.entry, String(mcp.schemaSource ?? '').split(' --')[0], String(mcp.implementationSource ?? '').split('#')[0]]) {
      if (f && !existsSync(f)) fail(`mcpProjection points at a missing file: ${f}`);
    }
    // The bin entry the Registry and the DSH bridge both use must exist in package.json.
    const pkgJson = JSON.parse(readFileSync('package.json', 'utf8'));
    const norm = (p) => String(p ?? '').replace(/^\.\//, '');
    if (norm(pkgJson.bin?.[mcp.bin]) !== norm(mcp.entry)) fail(`package.json bin['${mcp.bin}'] is ${JSON.stringify(pkgJson.bin?.[mcp.bin])}, expected ${mcp.entry}`);
    if (!pkgJson.files?.includes('server.json')) fail('package.json files does not ship server.json -- the Registry cannot install what the tarball dropped');
    // server.json must be about THIS package, at THIS version, over stdio from THAT bin.
    const sj = JSON.parse(readFileSync('server.json', 'utf8'));
    if (sj.name !== `io.github.${(pkgJson.repository?.url ?? '').split('github.com/')[1]?.split('/')[0] ?? '?'}/${(pkgJson.name ?? '').split('/').pop()}`)
      fail(`server.json name '${sj.name}' does not match the GitHub namespace derived from package.json`);
    if (sj.version !== pkgJson.version) fail(`server.json version '${sj.version}' != package.json version '${pkgJson.version}' -- a Registry entry pinned to a version that is not the one shipping installs the wrong engine`);
    const p0 = sj.packages?.[0] ?? {};
    if (p0.version !== pkgJson.version) fail(`server.json packages[0].version '${p0.version}' != package.json version '${pkgJson.version}'`);
    if (p0.identifier !== pkgJson.name) fail(`server.json packages[0].identifier '${p0.identifier}' != package name '${pkgJson.name}'`);
    if (p0.transport?.type !== 'stdio') fail(`server.json transport is ${JSON.stringify(p0.transport)}; this form is stdio, and no HTTP/SSE surface exists or is planned`);
    if (!Array.isArray(sj.packages) || sj.packages.length !== 1) fail(`server.json must describe exactly the one npm package this repo is, got ${sj.packages?.length}`);
    // The Registry's own limits, transcribed from the schema this file's $schema points at
    // (2025-12-11: description<=100, title<=100, name pattern, no version ranges, _meta<=4KB).
    // 0.8.0 shipped an 800-character description and the validator said NO -- which is the whole reason
    // these lines exist: a manifest that a registry refuses is a form nobody can install from a listing.
    if (String(sj.description ?? '').length === 0 || sj.description.length > 100)
      fail(`server.json description must be 1..100 characters (the Registry schema caps it); got ${sj.description?.length}`);
    if (sj.title !== undefined && (sj.title.length === 0 || sj.title.length > 100))
      fail(`server.json title must be 1..100 characters; got ${sj.title?.length}`);
    if (!/^[a-zA-Z0-9.-]+\/[a-zA-Z0-9._-]+$/.test(String(sj.name ?? '')) || sj.name.length > 200)
      fail(`server.json name '${sj.name}' is not a reverse-DNS namespace/name of <=200 characters`);
    if (/[*\^~]|[><=]/.test(String(sj.version ?? '')))
      fail(`server.json version '${sj.version}' looks like a range; the Registry wants one concrete version`);
    const metaBytes = Buffer.byteLength(JSON.stringify(sj._meta?.['io.modelcontextprotocol.registry/publisher-provided'] ?? {}), 'utf8');
    if (metaBytes > 4096) fail(`_meta publisher-provided is ${metaBytes} bytes; the official registry preserves at most 4096`);
    const noName = (p0.environmentVariables ?? []).filter((e) => !e.name);
    if (noName.length) fail(`${noName.length} environment variable(s) in server.json have no name`);
    // Every environment variable server.json advertises has to be one the server actually reads, and
    // every one the server reads has to be advertised: a hidden switch is an unenforceable one.
    const serverSrc = readFileSync('lib/mcp-server.mjs', 'utf8');
    const declared = new Set((p0.environmentVariables ?? []).map((e) => e.name));
    const read = new Set([...serverSrc.matchAll(/WPM_[A-Z_0-9]+/g)].map((m) => m[0]));
    const undocumented = [...read].filter((n) => !declared.has(n));
    const nonExistent = [...declared].filter((n) => !read.has(n));
    if (undocumented.length) fail(`server.json does not document env vars the server reads: ${undocumented.join(', ')}`);
    if (nonExistent.length) fail(`server.json advertises env vars the server never reads: ${nonExistent.join(', ')}`);
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
