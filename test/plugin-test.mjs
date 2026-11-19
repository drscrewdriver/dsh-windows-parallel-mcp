// plugin-test.mjs — the host half, exercised through its own `apply`, against the real worker.
//
// WHY THIS EXISTS ON TOP OF worker-smoke. worker-smoke proves the sidecar speaks; it says nothing
// about whether the tool the host registers is the tool the contract promises. The gap between those
// two is where a plugin looks installed and does the wrong thing:
//   * an action present in src/schema/tools.json that the registered parameters omit (the model is
//     told it exists, the registry rejects it);
//   * a required argument the contract names and the registration does not (same failure, later);
//   * a refusal that comes back as a thrown error (the caller sees "tool failed", not a code);
//   * a settings gate that is not actually checked server-side.
// Every assertion below is one of those, and it is made by importing the shipped file, not a copy.
//
// The ctx is a stub: this test is about the plugin's own contract, not about Cordis. Exit code 1 on
// any failure.
import { readFileSync } from 'node:fs';
import { PARAMETERS, TOOL_NAME, parametersToJsonSchema } from '../lib/host-tools.js';

let pass = 0;
const failures = [];
function ok(name, condition, detail = '') {
  if (condition) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
}

const contract = JSON.parse(readFileSync(new URL('../src/schema/tools.json', import.meta.url), 'utf8'));
const projection = contract.hostProjection;

// ---- a stub ctx that records what the plugin does -------------------------------------------
function makeCtx() {
  const registered = [];
  const disposers = [];
  return {
    registered,
    tools: { register: (tool) => { registered.push(tool); } },
    logger: { info: () => {}, warn: () => {} },
    on: (event, fn) => { if (event === 'dispose') disposers.push(fn); },
    dispose: async () => { for (const fn of disposers) await fn(); },
  };
}

const mod = await import('../lib/index.js');
ok('plugin exports a cordis name', typeof mod.name === 'string' && mod.name.length > 0, String(mod.name));
ok('plugin declares inject for tools', Array.isArray(mod.inject) && mod.inject.includes('tools'), JSON.stringify(mod.inject));
// ---- the three activation contracts Cordis enforces --------------------------------------------
// Both of the failures below were found by booting a real profile after this file was already green,
// which is why they are now assertions here: a unit test cannot see the loader's requirements.
ok('Config is a schema VALUE, not a factory', typeof mod.Config === 'object' && mod.Config !== null,
  `typeof=${typeof mod.Config} -- Cordis calls Config['~standard'].validate`);
ok("Config implements standard-schema ('~standard'.validate)",
  typeof mod.Config?.['~standard']?.validate === 'function');
{
  const validated = mod.Config?.['~standard']?.validate({});
  ok('Config validation is synchronous', validated && typeof validated.then !== 'function');
  ok('Config validation supplies every default',
    mod._internals.CONFIG_DEFAULTS && Object.keys(mod._internals.CONFIG_DEFAULTS).every((k) => validated?.value?.[k] !== undefined),
    JSON.stringify(validated?.value ?? {}));
  const bad = mod.Config?.['~standard']?.validate({ enabled: 'yes please' });
  ok('Config validation rejects a wrong type', Array.isArray(bad?.issues) && bad.issues.length > 0, JSON.stringify(bad));
  const typo = mod.Config?.['~standard']?.validate({ setteMs: 100 });
  ok('Config validation rejects an unknown key (a typo must not silently take the default)',
    Array.isArray(typo?.issues) && typo.issues.length > 0, JSON.stringify(typo));
}
// Cordis treats apply()'s return value as a disposable effect. An async apply returns a Promise and
// the plugin dies with "Invalid effect"; a sync apply must return undefined or a disposable.
ok('apply is a sync function', mod.apply?.constructor?.name !== 'AsyncFunction', String(mod.apply?.constructor?.name));

// ---- the projection ---------------------------------------------------------------------------
ok('a projection is declared in the contract', projection && projection.form === 'A', JSON.stringify(projection?.form));
ok('the projection names this tool', projection?.tool === TOOL_NAME, `${projection?.tool} vs ${TOOL_NAME}`);

const contractActions = contract.tools.map((t) => t.action).sort();
const projectedActions = Object.values(projection?.actions ?? {}).sort();
ok('the projection covers exactly the contract actions', JSON.stringify(contractActions) === JSON.stringify(projectedActions),
  `contract=${contractActions.join(',')} projected=${projectedActions.join(',')}`);

const projectedNames = Object.keys(projection?.actions ?? {}).sort();
const contractNames = contract.tools.map((t) => t.name).sort();
ok('every contract tool name is mapped, and nothing extra', JSON.stringify(projectedNames) === JSON.stringify(contractNames),
  `contract=${contractNames.join(',')} mapped=${projectedNames.join(',')}`);

const schema = parametersToJsonSchema(PARAMETERS);
ok('the action discriminator is required', schema.required.includes('action'), JSON.stringify(schema.required));
ok('the discriminator enum equals the five actions', JSON.stringify([...schema.properties.action.enum].sort()) === JSON.stringify(projectedActions),
  JSON.stringify(schema.properties.action.enum));
ok('the registered schema forbids undeclared arguments', schema.additionalProperties === false);

// Every required argument each contract tool names must exist in the registered parameters, or the
// model is told to send something the registry rejects.
for (const tool of contract.tools) {
  for (const arg of tool.inputSchema.required ?? []) {
    if (arg === 'hwnd' || arg === 'x' || arg === 'y' || arg === 'text' || arg === 'elementName' || arg === 'replace' || arg === 'settleMs' || arg === 'action') {
      ok(`contract ${tool.name}: '${arg}' is a registered parameter`, arg in schema.properties);
    } else {
      ok(`contract ${tool.name}: '${arg}' maps to a registered parameter`, false, 'unmapped required argument');
    }
  }
}

// The one field that must never appear: an input-method switch would advertise a capability this
// product does not have.
ok('no physical field in the registered parameters', !('physical' in schema.properties));
ok('no physical field anywhere in the contract', !/"physical"\s*:/i.test(JSON.stringify(contract)));

// ---- apply(): registration + real calls ---------------------------------------------------
const ctx = makeCtx();
const applyReturn = mod.apply(ctx, {});
const tool = ctx.registered[0];
ok('apply registers exactly one tool', ctx.registered.length === 1, `registered=${ctx.registered.length}`);
ok('the registered tool is the projected one', ctx.registered[0]?.name === TOOL_NAME, String(ctx.registered[0]?.name));
ok('the registered tool has a non-trivial description', (ctx.registered[0]?.description ?? '').length > 200,
  `len=${(ctx.registered[0]?.description ?? '').length}`);
ok('the registered tool validates arguments', typeof ctx.registered[0]?.execute === 'function');
ok('apply returns no value (Cordis would treat a returned object as an effect)', applyReturn === undefined,
  `returned ${applyReturn === null ? 'null' : typeof applyReturn}`);

// A real query through the real worker. This is the only assertion in this file that proves the
// plugin can actually reach the engine.
const status = await tool.execute({ action: 'status' });
ok('status reaches the engine', status.ok === true && /foreground=/.test(status.text), status.text?.slice(0, 160));
ok('status reports a refusal-free result', status.refusal === undefined || status.refusal === '', String(status.refusal));

const wins = await tool.execute({ action: 'windows' });
ok('windows reaches the engine', wins.ok === true && wins.text.length > 0, wins.text?.slice(0, 160));

// ---- refusals stay refusals -----------------------------------------------------------------
const deadClick = await tool.execute({ action: 'click', hwnd: '1', x: 10, y: 10 });
ok('a dead hwnd is returned as a refusal, not an exception', deadClick.ok === false);
ok('the dead-hwnd refusal carries the engine code', deadClick.refusal === 'no_hwnd', String(deadClick.refusal));
ok('the refusal text leads with the code, so a caller can branch on it', deadClick.text.startsWith('no_hwnd'), deadClick.text);

const emptyType = await tool.execute({ action: 'type', hwnd: '1', text: '' });
ok('an empty write is refused', emptyType.ok === false);
ok('the empty-write refusal uses a real code', ['unreachable', 'no_hwnd'].includes(emptyType.refusal), String(emptyType.refusal));

const missingArg = await tool.execute({ action: 'focus', hwnd: '1' });
ok('a missing required argument is refused with a code', missingArg.ok === false, JSON.stringify(missingArg).slice(0, 160));

// ---- the settings gate is server-side ------------------------------------------------------
const offCtx = makeCtx();
mod.apply(offCtx, { enabled: false });
const offTool = offCtx.registered[0];
const offResult = await offTool.execute({ action: 'status' });
ok('disabled plugin refuses before reaching the engine', offResult.ok === false && offResult.refusal === 'paused', JSON.stringify(offResult).slice(0, 160));

// ---- the worker lifetime is owned -----------------------------------------------------------
await ctx.dispose();
await offCtx.dispose();
ok('dispose does not throw', true);

console.log(`\nplugin-test: ${pass} passed, ${failures.length} failed`);
if (failures.length) {
  console.log(`failed: ${failures.join(', ')}`);
  process.exit(1);
}
