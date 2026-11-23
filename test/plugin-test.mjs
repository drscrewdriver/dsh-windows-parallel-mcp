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
// WHAT MUST BE EXCLUDED IS AN ASYNC FACTORY, not a callable schema: a Schemastery schema IS a function
// (callable instance) that also carries '~standard', and the host renders the settings form from it. The
// original `typeof === 'object'` was written when only the shim path was reachable, so it asserted the
// shim's shape rather than the contract Cordis actually needs. The contract is the next assertion.
ok('Config is a schema VALUE, not a factory',
  (typeof mod.Config === 'object' || typeof mod.Config === 'function') && mod.Config !== null,
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
ok('the discriminator enum equals the eight actions', JSON.stringify([...schema.properties.action.enum].sort()) === JSON.stringify(projectedActions),
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

// The control surface must be visible in the result the model and the user both read. On this
// machine Ctrl+Alt+Q is owned by another app, so the honest answer is "unavailable or a different
// chord" -- never a silent assertion that the documented key works.
ok('status reports the overlay state', /\boverlay=(on|off)\b/.test(status.text), status.text?.slice(0, 240));
ok('status reports which pause hotkey actually registered',
  /\bpauseHotkey=(unavailable|[A-Za-z+]+)/.test(status.text), status.text?.slice(0, 240));
// The read paths' coordinates are physical only while the process is DPI aware; the honest way to keep
// that from becoming a silent half-scale system is to make the stance a readable fact, not a promise.
ok('status reports dpiAware, the fact every snapshot rect and screenshot pixel depends on',
  /\bdpiAware=(true|false)\b/.test(status.text), status.text?.slice(0, 300));

const wins = await tool.execute({ action: 'windows' });
ok('windows reaches the engine', wins.ok === true && wins.text.length > 0, wins.text?.slice(0, 160));

// ---- refusals stay refusals -----------------------------------------------------------------
// A REFUSED CLICK MUST NOT PLACE A MARKER, and must not start the overlay either: the marker
// promise is "this is the point that was acted on", and there was no such point here. The overlay
// may already be on from an earlier run, so the invariant asserted is "this call did not CHANGE
// it" -- read before, read after, compare. (An `off || on` assertion would have been unfalsifiable;
// the first version of this block was exactly that and is why it is written as a comparison.)
const beforeDead = await tool.execute({ action: 'status' });
const wasOn = /\boverlay=on\b/.test(beforeDead.text);
const deadClick = await tool.execute({ action: 'click', hwnd: '1', x: 10, y: 10 });
const afterDeadClick = await tool.execute({ action: 'status' });
const nowOn = /\boverlay=on\b/.test(afterDeadClick.text);
ok('a refused click does not change the marker overlay state', wasOn === nowOn,
  `before=${wasOn} after=${nowOn} :: ${afterDeadClick.text?.slice(0, 200)}`);
ok('a dead hwnd is returned as a refusal, not an exception', deadClick.ok === false);
ok('the dead-hwnd refusal carries the engine code', deadClick.refusal === 'no_hwnd', String(deadClick.refusal));
ok('the refusal text leads with the code, so a caller can branch on it', deadClick.text.startsWith('no_hwnd'), deadClick.text);

// A REFUSAL HAS NO EFFECT TO REPORT: no action ran, so nobody can have reported success. Both
// halves are asserted -- the text a model reads and the field a program reads -- because "no
// effect= in the text" alone would still let a structural field leak out.
ok("a refused click reports no effect in its text", !/effect=/.test(deadClick.text), deadClick.text);
ok('a refused click carries no effect field at all', !('effect' in deadClick), JSON.stringify(Object.keys(deadClick)));

const emptyType = await tool.execute({ action: 'type', hwnd: '1', text: '' });
ok('an empty write is refused', emptyType.ok === false);
ok('the empty-write refusal uses a real code', ['unreachable', 'no_hwnd'].includes(emptyType.refusal), String(emptyType.refusal));

const missingArg = await tool.execute({ action: 'focus', hwnd: '1' });
ok('a missing required argument is refused with a code', missingArg.ok === false, JSON.stringify(missingArg).slice(0, 160));

// ---- 0.5.0: image coordinates without a shotId cost ZERO worker requests ---------------------
// "space:'image' with no shotId" is not a coordinate the engine can interpret, and reinterpreting the
// raw numbers as screen pixels would click somewhere plausibly wrong. The refusal has to happen before
// the expensive part, or "the check exists" and "the check is checked first" are indistinguishable.
{
  const { WorkerClient } = await import('../lib/engine.js');
  const original = WorkerClient.prototype.request;
  const seen = [];
  WorkerClient.prototype.request = function patched(payload) {
    seen.push(payload);
    return original.call(this, payload);
  };
  try {
    const imgCtx = makeCtx();
    mod.apply(imgCtx, {});
    const imgTool = imgCtx.registered[0];
    const noShot = await imgTool.execute({ action: 'click', hwnd: '1', x: 10, y: 20, space: 'image' });
    ok('space:"image" without a shotId is refused with stale_ref, not reinterpreted',
      noShot.ok === false && noShot.refusal === 'stale_ref', JSON.stringify(noShot).slice(0, 200));
    ok('  ... and it costs no worker request at all', seen.length === 0, JSON.stringify(seen));

    // A label with no snapshot behind it can only be judged by the engine, so THAT one does travel.
    // It needs a LIVE hwnd though: liveness is checked before the label is resolved, and a dead handle
    // must stay no_hwnd rather than being reported as a stale reference (the two have different next
    // steps). Asserting both keeps the ordering from drifting.
    const liveHwnd = (wins.text || '').split('\n').slice(1).map((l) => l.trim().split(/\s+/)[0]).find(Boolean) || '';
    const beforeDead = seen.length;
    const deadLabel = await imgTool.execute({ action: 'click', hwnd: '1', x: 10, y: 20, label: 3, snapId: 'snap-nope' });
    ok('a label on a dead hwnd is still no_hwnd (liveness outranks the reference check)',
      deadLabel.refusal === 'no_hwnd', JSON.stringify(deadLabel).slice(0, 180));
    ok('  ... and liveness is decided by the ENGINE, so that call did travel (unlike the shotId gate)',
      seen.length === beforeDead + 1, `requests ${beforeDead}->${seen.length}`);
    if (liveHwnd) {
      const beforeLive = seen.length;
      const labelOnly = await imgTool.execute({ action: 'click', hwnd: liveHwnd, x: 10, y: 20, label: 3, snapId: 'snap-nope' });
      ok('a label with no live frame behind it is refused with stale_ref',
        labelOnly.refusal === 'stale_ref', JSON.stringify(labelOnly).slice(0, 220));
      ok('  ... and it too reached the engine exactly once',
        seen.length === beforeLive + 1, `requests ${beforeLive}->${seen.length}`);
    }

    // The read paths themselves must be reachable through the projection (a registered action the
    // engine cannot serve would look installed and fail).
    const shotFull = await imgTool.execute({ action: 'screenshot', fullScreen: true });
    ok('a full-screen screenshot is served without an hwnd', shotFull.ok === true, `${shotFull.refusal} ${String(shotFull.text).slice(0, 160)}`);
    await imgCtx.dispose();
  } finally {
    WorkerClient.prototype.request = original;
  }
}

// ---- the effect dimension reaches the caller (R1) -------------------------------------------
// The engine has always computed `effect` (src/engine/engine.ps1); 0.1.2 dropped it on the floor, so
// `proof=pass` could not be told apart from "the message was delivered and the app ignored it".
// Asserted on the shipped projection with hand-authored engine results: no desktop involved, so this
// arm cannot pass by luck.
const EFFECTS = ['unverified', 'reported-by-send', 'reported-by-pattern'];
{
  const quietSamples = Array.from({ length: 12 }, (_, i) => ({
    ts: 1000 + i * 20, cx: 40, cy: 60, fg: '1', focus: '2', inputAgeMs: 5000 + i * 20,
  }));
  for (const effect of EFFECTS) {
    const projected = mod._internals.formatResult('click', {
      channel: 'msg', tier: 'quiet', focusTaken: 'false', effect,
      proofSamples: quietSamples, proofControl: quietSamples,
    });
    ok(`click result carries effect=${effect} in the text`, projected.text.includes(`effect=${effect}`),
      projected.text);
    ok(`  ... and structurally, with a legal value`, EFFECTS.includes(projected.effect), String(projected.effect));
  }
  // An engine result that never set effect must not invent a nicer word for itself.
  const silent = mod._internals.formatResult('click', { channel: 'msg', tier: 'quiet' });
  ok('a result with no effect defaults to unverified', silent.effect === 'unverified', String(silent.effect));
  ok('  ... and a channel that reported nothing cannot read as proof=pass',
    silent.proof !== 'pass', String(silent.proof));
}

// ---- the settings gate is server-side ------------------------------------------------------
const offCtx = makeCtx();
mod.apply(offCtx, { enabled: false });
const offTool = offCtx.registered[0];
const offResult = await offTool.execute({ action: 'status' });
ok('disabled plugin refuses before reaching the engine', offResult.ok === false && offResult.refusal === 'paused', JSON.stringify(offResult).slice(0, 160));

// ---- R3 GATES: refused BEFORE the worker, and stripped rather than forwarded -----------------
// "The gate is checked" is indistinguishable from "the gate is checked after the expensive part" unless
// the worker traffic is counted, so the client's request method is wrapped for these arms only.
{
  const { WorkerClient } = await import('../lib/engine.js');
  const original = WorkerClient.prototype.request;
  const seen = [];
  WorkerClient.prototype.request = function patched(payload) {
    seen.push(payload);
    return original.call(this, payload);
  };
  try {
    const gated = makeCtx();
    mod.apply(gated, {});
    const gatedTool = gated.registered[0];

    const noTakeover = await gatedTool.execute({ action: 'click', hwnd: '1', x: 10, y: 10, takeover: true });
    ok('takeover with takeoverAllowed off is refused', noTakeover.ok === false && noTakeover.refusal === 'takeover_unavailable',
      JSON.stringify(noTakeover).slice(0, 200));
    ok('  ... and the refusal never reached the worker', seen.length === 0, JSON.stringify(seen));

    // With BOTH gates off the takeover gate is the one that speaks first: the caller asked for a tier that
    // is switched off, and naming that is more useful than describing a keyboard it never reached.
    const noInject = await gatedTool.execute({ action: 'type', hwnd: '1', text: 'x', takeover: true, keyInput: 'inject' });
    ok('injection inside a switched-off takeover tier is refused at the takeover gate',
      noInject.ok === false && noInject.refusal === 'takeover_unavailable',
      JSON.stringify(noInject).slice(0, 200));
    ok('  ... and that refusal never reached the worker either', seen.length === 0, JSON.stringify(seen));

    // The K5 independence arm: injection open, takeover closed. Injection must stay impossible, because
    // SendInput writes to the foreground and the takeover tier is what makes that a declared action.
    const openInject = makeCtx();
    mod.apply(openInject, { keyInjectAllowed: true });
    const openTool = openInject.registered[0];
    const injectNoTakeover = await openTool.execute({ action: 'type', hwnd: '1', text: 'x', keyInput: 'inject' });
    ok('keyInjectAllowed alone does not enable injection (it needs the takeover tier)',
      injectNoTakeover.ok === false && injectNoTakeover.refusal === 'keyinject_unavailable',
      JSON.stringify(injectNoTakeover).slice(0, 200));
    ok('  ... with zero worker traffic', seen.length === 0, JSON.stringify(seen));

    // The other direction: takeover open, injection closed. Same code, and still no request.
    const noKeyGate = makeCtx();
    mod.apply(noKeyGate, { takeoverAllowed: true, keyInjectAllowed: false });
    const noKeyTool = noKeyGate.registered[0];
    const injectDenied = await noKeyTool.execute({ action: 'click', hwnd: '1', x: 10, y: 10, takeover: true, keyInput: 'inject' });
    ok('an unauthorised keyInput is refused even when takeover is allowed',
      injectDenied.ok === false && injectDenied.refusal === 'keyinject_unavailable',
      JSON.stringify(injectDenied).slice(0, 200));
    ok('  ... and it costs no worker request', seen.length === 0, JSON.stringify(seen));

    // An AUTHORISED request is forwarded, with the per-call ceiling, and carries no keyInput at all when
    // the caller did not ask for injection.
    const allowed = makeCtx();
    mod.apply(allowed, { takeoverAllowed: true });
    const allowedTool = allowed.registered[0];
    await allowedTool.execute({ action: 'click', hwnd: '1', x: 10, y: 10, takeover: true });
    const forwarded = seen.find((p) => p.action === 'click');
    ok('an authorised takeover reaches the worker with takeover:true', !!forwarded && forwarded.takeover === true,
      JSON.stringify(forwarded));
    ok('  ... with a numeric per-call ceiling', !!forwarded && typeof forwarded.takeoverMaxMs === 'number',
      JSON.stringify(forwarded));
    ok('  ... and no keyInput field when none was asked for', !!forwarded && !('keyInput' in forwarded),
      JSON.stringify(forwarded));

    await gated.dispose();
    await openInject.dispose();
    await noKeyGate.dispose();
    await allowed.dispose();
  } finally {
    WorkerClient.prototype.request = original;
  }
}

// ---- the worker lifetime is owned -----------------------------------------------------------
await ctx.dispose();
await offCtx.dispose();
ok('dispose does not throw', true);

console.log(`\nplugin-test: ${pass} passed, ${failures.length} failed`);
if (failures.length) {
  console.log(`failed: ${failures.join(', ')}`);
  process.exit(1);
}
