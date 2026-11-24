// check-mcp-schema.mjs -- gate 22: the MCP `tools/list` answer must BE src/schema/tools.json.
//
// WHY THIS GATE EXISTS AT ALL. 0.8.0 delivers one engine through two channels, and the failure mode of
// that arrangement has a name in this repo's history: three copies of a contract drifting apart while
// all three look enforced (the refusal codes, the effect values, the version string, the geometry
// oracle, the policy ladder). R6 said the answer up front -- `tools/list` is GENERATED from the schema
// file -- and a claim about how code is written is worth exactly nothing as a comment. So this gate
// does the only thing that can be done from outside: it starts the real server over stdio, reads the
// answer a client would get, and compares it field by field with the file.
//
// NON-VACUITY, and the second half is the one that matters. --self-test runs six mutations:
//   four server-side ones that must turn the gate RED (drop the property spread, stop listing refusal
//   codes, hard-write the action enum, freeze every rung to one value);
//   two CONTRACT-side ones that must stay GREEN *and move*: rename a parameter in tools.json, or flip
//   an additionalProperties there. A mutation test that only ever checks "break the generator, see red"
//   cannot tell a generated schema from a transcribed one that happens to be in step today. The
//   contract-side arms are what prove the wire follows the file.
//
// Usage: node scripts/check-mcp-schema.mjs [--self-test]
import { spawn } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const SERVER = 'lib/mcp-server.mjs';
const SCHEMA = 'src/schema/tools.json';
/** What a copy needs to answer tools/list: the whole host half, the contract file, and the manifest the
 * server reads its own version from. No engine file, because this gate never performs an action. */
const SHIP_DIRS = ['lib', 'src/schema'];
const SHIP_FILES = [SERVER, SCHEMA, 'package.json'];

const schema = JSON.parse(readFileSync(SCHEMA, 'utf8'));

/** Ask a running server what it exposes. Returns the single tool entry. */
function askToolsList(entry, cwd) {
  const child = spawn(process.execPath, [entry], { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
  let buf = '';
  const lines = [];
  child.stdout.on('data', (d) => {
    buf += d.toString();
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const s = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (s) lines.push(s);
    }
  });
  const send = (o) => child.stdin.write(JSON.stringify(o) + '\n');
  const wait = (id, ms = 20000) => new Promise((resolve, reject) => {
    const at = setInterval(() => {
      const hit = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } })
        .find((m) => m && m.id === id);
      if (hit) { clearInterval(at); clearTimeout(timer); resolve(hit); }
    }, 20);
    const timer = setTimeout(() => { clearInterval(at); reject(new Error(`no reply to ${id} in ${ms}ms; lines=${lines.length}`)); }, ms);
  });
  return (async () => {
    try {
      send({ jsonrpc: '2.0', id: 'i', method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'gate', version: '0' } } });
      await wait('i');
      send({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} });
      send({ jsonrpc: '2.0', id: 'l', method: 'tools/list', params: {} });
      const list = await wait('l');
      const tools = list?.result?.tools;
      if (!Array.isArray(tools)) throw new Error(`tools/list returned no tools array: ${JSON.stringify(list).slice(0, 160)}`);
      if (tools.length !== 1) throw new Error(`expected exactly 1 tool, got ${tools.length} (${tools.map((t) => t.name).join(',')})`);
      return tools[0];
    } finally {
      child.stdin.end();
      child.kill();
    }
  })();
}

/** The comparison. Everything expected is READ from the contract file passed in, so this gate is not a
 * third copy -- and for a contract-side mutation the expectation comes from the MUTATED file, which is
 * the whole point: "did the wire follow the file" is answered against that file, not against the repo's. */
function compare(tool, contract = schema) {
  const problems = [];
  const push = (m) => problems.push(m);
  const actions = contract.tools.map((t) => t.action).sort();
  if (tool.name !== contract.mcpProjection?.tool) push(`tool name '${tool.name}' != mcpProjection.tool '${contract.mcpProjection?.tool}'`);
  const is = tool.inputSchema ?? {};
  const enum_ = [...(is.properties?.action?.enum ?? [])].sort();
  if (JSON.stringify(enum_) !== JSON.stringify(actions)) push(`action enum ${JSON.stringify(enum_)} != contract actions ${JSON.stringify(actions)}`);
  if (!(is.required ?? []).includes('action')) push('inputSchema does not require `action`');
  const branches = is.oneOf ?? [];
  if (branches.length !== contract.tools.length) push(`oneOf has ${branches.length} branches, the contract has ${contract.tools.length} actions`);
  for (const t of contract.tools) {
    const br = branches.find((b) => b?.properties?.action?.const === t.action);
    if (!br) { push(`contract action '${t.action}' has no oneOf branch`); continue; }
    const want = Object.keys(t.inputSchema.properties ?? {}).sort();
    const got = Object.keys(br.properties ?? {}).filter((k) => k !== 'action').sort();
    if (JSON.stringify(want) !== JSON.stringify(got)) push(`${t.action}: wire properties ${JSON.stringify(got)} != contract ${JSON.stringify(want)}`);
    const wantReq = [...(t.inputSchema.required ?? [])].sort();
    const gotReq = (br.required ?? []).filter((k) => k !== 'action').sort();
    if (JSON.stringify(wantReq) !== JSON.stringify(gotReq)) push(`${t.action}: wire required ${JSON.stringify(gotReq)} != contract ${JSON.stringify(wantReq)}`);
    const wantAP = t.inputSchema.additionalProperties === true;
    if (br.additionalProperties !== wantAP) push(`${t.action}: wire additionalProperties=${br.additionalProperties} != contract ${wantAP}`);
    // A parameter's own description is part of the contract; a branch that renames or re-summarises it
    // is a second document about the same argument, which is the thing this gate is for.
    for (const [k, v] of Object.entries(t.inputSchema.properties ?? {})) {
      if (typeof v?.description === 'string' && v.description && br.properties?.[k]?.description !== v.description)
        push(`${t.action}.${k}: the wire description differs from the contract's`);
    }
  }
  const desc = String(tool.description ?? '');
  const missingCodes = contract.refusals.map((r) => r.code).filter((c) => !desc.includes(c));
  if (missingCodes.length) push(`the description omits refusal code(s): ${missingCodes.join(', ')}`);
  const missingTiers = contract.tools.filter((t) => !desc.includes(`action=${t.action} | ${t.requiresTier}`));
  if (missingTiers.length) push(`the description does not pair action with its declared rung for: ${missingTiers.map((t) => t.action).join(', ')}`);
  const missingLeads = contract.tools.filter((t) => !desc.includes(String(t.description).split(/(?<=\.)\s/)[0]));
  if (missingLeads.length) push(`the description stops quoting the contract's own wording for: ${missingLeads.map((t) => t.action).join(', ')}`);
  return problems;
}

// ---- self-test: mutate a COPY, never the repo ------------------------------------------
const MUT_ROOT = '.tmp/mcp-gate';
function buildCopy(name, mutate) {
  const root = join(MUT_ROOT, name);
  rmSync(root, { recursive: true, force: true });
  for (const d of SHIP_DIRS) cpSync(d, join(root, d), { recursive: true });
  for (const f of SHIP_FILES) if (!existsSync(join(root, f))) { mkdirSync(dirname(join(root, f)), { recursive: true }); cpSync(f, join(root, f)); }
  mutate(root);
  return root;
}
const read = (root, f) => readFileSync(join(root, f), 'utf8');
const write = (root, f, s) => writeFileSync(join(root, f), s, 'utf8');

const MUTATIONS = [
  {
    name: 'server: the branch stops spreading the contract properties',
    expect: 'red',
    apply: (root) => write(root, SERVER, read(root, SERVER).replace('...t.inputSchema.properties,', '/* dropped */')),
  },
  {
    name: 'server: the refusal vocabulary is left out of the description',
    expect: 'red',
    apply: (root) => write(root, SERVER, read(root, SERVER).replace(/^\s*\.\.\.schema\.refusals\.map\(.*$/m, '    /* dropped */')),
  },
  {
    name: 'server: the action enum is hard-written instead of mapped',
    expect: 'red',
    apply: (root) => write(root, SERVER, read(root, SERVER).replace(
      'enum: schema.tools.map((t) => t.action)', "enum: ['windows', 'status', 'click']")),
  },
  {
    name: 'server: every rung is reported as the same quiet value',
    expect: 'red',
    // Targets the ACTION LINE specifically (the same expression also appears in each branch's own
    // description, and mutating that one would not be caught by a description assertion -- a mutation
    // that picks the wrong site is as useless as a gate that never fires).
    apply: (root) => write(root, SERVER, read(root, SERVER).replace(
      /\| \$\{t\.requiresTier\}\$\{t\.requiresTierFor/, '| quiet${t.requiresTierFor')),
  },
  {
    name: 'contract: a parameter is renamed in tools.json',
    expect: 'follows',
    apply: (root) => {
      const s = JSON.parse(read(root, SCHEMA));
      const t = s.tools.find((x) => x.action === 'type');
      if (!t.inputSchema.properties.caretPosition) throw new Error('the mutation assumed `type` declares caretPosition');
      t.inputSchema.properties.caretMoved = t.inputSchema.properties.caretPosition;
      delete t.inputSchema.properties.caretPosition;
      if ((t.inputSchema.required ?? []).includes('caretPosition')) t.inputSchema.required = t.inputSchema.required.map((r) => (r === 'caretPosition' ? 'caretMoved' : r));
      write(root, SCHEMA, JSON.stringify(s, null, 2) + '\n');
    },
    verify: (tool, problems) => {
      if (problems.length) return `the gate went red on a contract-side rename, which means the wire did NOT follow the file: ${problems[0]}`;
      const br = (tool.inputSchema?.oneOf ?? []).find((b) => b?.properties?.action?.const === 'type');
      if (!br || !('caretMoved' in br.properties) || 'caretPosition' in br.properties)
        return 'the renamed parameter did not reach tools/list -- the schema is being transcribed, not generated';
      return null;
    },
  },
  {
    name: 'contract: additionalProperties is flipped on one action',
    expect: 'follows',
    apply: (root) => {
      const s = JSON.parse(read(root, SCHEMA));
      const t = s.tools.find((x) => x.action === 'status');
      if (t.inputSchema.additionalProperties !== false) throw new Error('the mutation assumed status closes its schema');
      t.inputSchema.additionalProperties = true;
      write(root, SCHEMA, JSON.stringify(s, null, 2) + '\n');
    },
    verify: (tool, problems) => {
      if (problems.length) return `the gate went red on a contract-side flip instead of following it: ${problems[0]}`;
      const br = (tool.inputSchema?.oneOf ?? []).find((b) => b?.properties?.action?.const === 'status');
      if (br?.additionalProperties !== true) return 'the flipped additionalProperties did not reach tools/list';
      return null;
    },
  },
];

async function main() {
  const selfTest = process.argv.includes('--self-test');
  if (!selfTest) {
    const tool = await askToolsList(SERVER, '.');
    const problems = compare(tool);
    if (problems.length) {
      console.log(`FAIL mcp-schema: tools/list is not the contract file (${problems.length} problem(s))`);
      for (const p of problems) console.log(`  - ${p}`);
      process.exit(1);
    }
    console.log(`PASS mcp-schema: tools/list is generated from ${SCHEMA} -- ${schema.tools.length} action branch(es), ${schema.refusals.length} refusal code(s), one tool named ${schema.mcpProjection.tool}`);
    return;
  }
  let bad = 0;
  const tool = await askToolsList(SERVER, '.');
  const base = compare(tool);
  if (base.length) { console.log('FAIL mcp-schema --self-test: the unmutated build is already red'); base.forEach((p) => console.log(`  - ${p}`)); process.exit(1); }
  for (const m of MUTATIONS) {
    const slug = m.name.replace(/[^a-z]+/gi, '-').slice(0, 28).replace(/-$/, '');
    let outcome;
    try {
      const root = buildCopy(slug, m.apply);
      const mutated = await askToolsList(join('lib', 'mcp-server.mjs'), root);
      const problems = compare(mutated, JSON.parse(read(root, SCHEMA)));
      outcome = m.expect === 'red'
        ? (problems.length ? null : 'stayed green: the mutation is invisible to the gate')
        : m.verify(mutated, problems);
    } catch (e) {
      // A mutation that stops the server from answering is also a catch: a transport that dies under a
      // one-line edit is not the honest generated shape either.
      outcome = m.expect === 'red' ? `crashed instead of being reported: ${e.message}` : `crashed instead of following the contract: ${e.message}`;
    }
    if (outcome) { bad++; console.log(`  MISS  ${m.name}\n        ${outcome}`); }
    else console.log(`  seen  ${m.name} (${m.expect === 'red' ? 'red as expected' : 'followed the contract as expected'})`);
  }
  rmSync(MUT_ROOT, { recursive: true, force: true });
  if (bad) { console.log(`FAIL mcp-schema --self-test: ${bad} of ${MUTATIONS.length} mutations escaped`); process.exit(1); }
  console.log(`PASS mcp-schema --self-test: ${MUTATIONS.length} mutation(s) all seen (${MUTATIONS.filter((m) => m.expect === 'red').length} red, ${MUTATIONS.filter((m) => m.expect === 'follows').length} followed)`);
}

await main();
