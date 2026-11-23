// index.js — the host half: one tool, one worker, and the refusal vocabulary kept intact.
//
// THE SHAPE OF THIS FILE IS THE FORM DECISION. R3.1' in spec.md recorded the fork as
//   A. DSH native plugin: the host registers the tool directly; PowerShell is a sidecar.
//   B. MCP server: the host talks to a separate MCP process over stdio.
// The owner chose A on 2026-11-19. Concretely that means: no `@modelcontextprotocol/sdk`, no bridge
// row, no second Node process — the tool is registered here and the only child process is the
// PowerShell worker, which the engine already needed in either form.
//
// WHY ONE TOOL AND NOT FIVE. src/schema/tools.json names eight actions as the contract surface. The
// host convention (shell / terminal / read / write in this same build) is one tool with an action
// discriminator, because every registered tool is resident schema on every turn — eight entries
// describing one engine is a standing token cost for no gain in capability. The contract is
// preserved exactly: same eight actions, same fourteen refusal codes, same required arguments. The
// mapping is asserted in test/plugin-test.mjs against the contract file, so "we project to one tool"
// cannot quietly become "we support seven actions". 0.5.0's three new actions went into the SAME one
// tool for the same reason the earlier five did: the token argument does not weaken when the surface
// grows.
//
// THE THREE THINGS THIS FILE MUST GET RIGHT, each of which would look like a working plugin while
// being wrong:
//   1. A disappeared worker must not become a dead tool. The client restarts once and reports.
//   2. A refusal must survive as a refusal. It is returned in the result text with its code, never
//      swallowed and never turned into a generic failure — R3.2 forbids canned messages.
//   3. `paused` and `enabled` are server-side gates. They are checked here, before any worker call,
//      because a prompt-level hint is not a switch (R2.5).
import { createConfigSchema, CONFIG_DEFAULTS } from './config.js';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { WorkerClient, workerScript } from './engine.js';
import { ACTIONS, PARAMETERS, TOOL_NAME, resolveDefineTool } from './host-tools.js';
import { evaluateProof } from './proof-window.mjs';
import { actionTier, policyDecision, tierTable } from './policy.js';
import { auditLine, auditWrite } from './audit.js';

/**
 * The tier each action declares it needs, read ONCE from the contract file -- not copied into a table
 * here. The reason is this repo's most repeated lesson: three hand-kept copies of one vocabulary drift
 * (scripts/check-refusals.mjs exists because of it), and a policy table written in two places would be
 * the same bug with permission semantics attached. If the file cannot be read the table is EMPTY, and an
 * empty table makes `actionTier` answer `takeover` for everything -- fail closed, never fail open.
 * @type {Record<string, {requiresTier: string, requiresTierFor: Record<string,string>}>}
 */
const REQUIRES_TIER = (() => {
  try {
    const doc = JSON.parse(readFileSync(new URL('../src/schema/tools.json', import.meta.url), 'utf8'));
    return tierTable(doc.tools ?? []);
  } catch { return {}; }
})();

// ---- THE PUBLIC CONTRACT IS THE SOURCE OF TRUTH, AND THIS FILE IS CHECKED AGAINST IT ----------
//
// types/index.d.ts is what a consumer imports and what `scripts/check-types.mjs` proves a strict
// client accepts. The typedef block below IMPORTS that same file, so the annotations in this
// implementation are checked against the shipped promise rather than against a private copy of it:
// rename a field in types/index.d.ts and `scripts/check-jsdoc.mjs` turns this file red. That
// direction is the whole point -- a generated .d.ts (what a TypeScript rewrite would emit here) has
// no `WpmAction`/`RefusalCode`/`WpmArgs` at all, so it could not do this.
//
// (The first version of this block used `// @typedef` lines. Those are comments, not JSDoc: nothing
// was declared, and the checker answered "Cannot find name 'WpmArgs'". A JSDoc block is required.)
/**
 * @typedef {import('../types/index.d.ts').WpmAction} WpmAction
 * @typedef {import('../types/index.d.ts').WpmArgs} WpmArgs
 * @typedef {import('../types/index.d.ts').RefusalCode} RefusalCode
 * @typedef {import('../types/index.d.ts').WpmResult} WpmResult
 * @typedef {import('../types/index.d.ts').WpmExec} WpmExec
 */

/**
 * The settings object `apply` derives from the Cordis config. Spelled out because the config VALUE is
 * `{}` at the type level -- config.js validates it at runtime, and a validator's output is not a
 * static fact -- so without this every one of the ten reads under `apply` reports "does not exist on
 * type '{}'". The property list here must match `FIELDS` in config.js; both are checked by
 * test/plugin-test.mjs.
 * @typedef {object} WpmSettings
 * @property {boolean} enabled
 * @property {number} settleMs
 * @property {number} requestTimeoutMs
 * @property {string} powershellPath
 * @property {boolean} overlay
 * @property {boolean} logWorkerStderr
 * @property {boolean} takeoverAllowed
 * @property {boolean} keyInjectAllowed
 * @property {number} takeoverMaxMs
 * @property {number} takeoverArmMs
 * @property {number} snapshotMaxElements
 * @property {number} screenshotMaxWidth
 * @property {number} shotsKeep
 * @property {boolean} appLaunchAllowed
 * @property {string[]} appLaunchAllow
 * @property {'readonly'|'quiet'|'balanced'|'full'} policy
 * @property {number} policyIdleMs
 * @property {number} auditKeep
 */

/**
 * A refusal thrown before the worker is reached. The two extra fields are the whole point: the caller
 * path reads `err.refusal` for the code and `err.reason` for the sentence, so typing this as a plain
 * `Error` would lose the vocabulary that makes a refusal actionable.
 * @typedef {Error & {refusal?: RefusalCode, reason?: string}} WpmError
 */

/**
 * One worker envelope, as engine.js documents it. `result` is deliberately `any`: its shape is the
 * PowerShell engine's JSON-lines protocol, and pretending to type it from this side would be the
 * "type safety over half the system" mistake in miniature.
 * @typedef {object} Envelope
 * @property {boolean} [ok]
 * @property {string} [error]
 * @property {any} [result]
 */

/**
 * The Cordis context surface this plugin touches, and nothing more. `logger` is optional everywhere it
 * is used (`logger.warn?.(...)`) because a host that supplies no logger must still work.
 * @typedef {object} CordisContext
 * @property {{register: (tool: any) => void}} tools
 * @property {{info?: (m: string) => void, warn?: (m: string) => void}} [logger]
 * @property {(event: string, fn: () => void) => void} [on]
 */

/** Stable Cordis plugin name (this is what a profile entry points at). */
export const name = 'windows-parallel';

/** Services that must exist before the tool can register. */
export const inject = ['tools'];

/**
 * The settings schema is resolved once, at module load, because Cordis reads `Config` synchronously
 * as a standard-schema value (it calls `Config['~standard'].validate(config)`). A factory function
 * here -- the first version of this file -- fails activation with
 * `Cannot read properties of undefined (reading 'validate')`, which is only visible by booting a real
 * profile. See lib/config.js.
 */
const resolvedConfig = await createConfigSchema();
export const Config = resolvedConfig.schema;
export const configSource = resolvedConfig.source;

/**
 * Resolved at module load, not inside `apply`. Cordis treats whatever `apply` returns as a
 * disposable effect, so an `async apply` returns a Promise and the plugin dies with "Invalid effect"
 * -- the second activation failure found by booting a real profile. Anything asynchronous therefore
 * has to finish before `apply` runs, which top-level await makes possible and keeps `apply` sync.
 */
const resolvedTools = await resolveDefineTool();
export const toolHelperSource = resolvedTools.source;

/**
 * Register the tool. `apply` is the whole host half; there is no client half yet, which is
 * deliberate: the overlay / pill / hotkey layer is task_54 and gets its own commit. A plugin with a
 * working tool and no UI is usable; a plugin with UI and no working tool is a demo.
 * @param {CordisContext} ctx
 * @param {Record<string, any>} [config]
 * @returns {void}
 */
export function apply(ctx, config = {}) {
  /** @type {WpmSettings} */
  const settings = {
    enabled: resolveSetting(config.enabled, true),
    settleMs: resolveSetting(config.settleMs, 350),
    requestTimeoutMs: resolveSetting(config.requestTimeoutMs, 20000),
    powershellPath: resolveSetting(config.powershellPath, ''),
    overlay: resolveSetting(config.overlay, true),
    logWorkerStderr: resolveSetting(config.logWorkerStderr, false),
    // ---- R3 gates. Both default false: with them off this build behaves exactly like 0.1.6, so an
    // upgrade cannot silently start moving the owner's cursor. The gates live HERE, before the worker,
    // because a prompt-level hint is not a switch (same reasoning as `enabled`/`paused`).
    takeoverAllowed: resolveSetting(config.takeoverAllowed, false) === true,
    keyInjectAllowed: resolveSetting(config.keyInjectAllowed, false) === true,
    takeoverMaxMs: clampNumber(resolveSetting(config.takeoverMaxMs, 10000), 500, 60000, 10000),
    takeoverArmMs: clampNumber(resolveSetting(config.takeoverArmMs, 800), 0, 5000, 800),
    // ---- 0.5.0 read-path settings. Forwarded, never silently clamped on the caller's behalf: the
    // engine is the one that reports what it actually used (maxElements/shotsKeep ride back on the
    // result), so "the setting took" is observable rather than assumed.
    snapshotMaxElements: clampNumber(resolveSetting(config.snapshotMaxElements, 300), 1, 5000, 300),
    screenshotMaxWidth: clampNumber(resolveSetting(config.screenshotMaxWidth, 0), 0, 7680, 0),
    shotsKeep: clampNumber(resolveSetting(config.shotsKeep, 10), 1, 200, 10),
    // ---- 0.7.0 desktop gates. Read defensively because a whitelist is a list of AUTHORIZATIONS: a
    // non-array, an empty entry, or a stray space must never turn into "everything is allowed".
    appLaunchAllowed: resolveSetting(config.appLaunchAllowed, false) === true,
    appLaunchAllow: normalizeAllowList(resolveSetting(config.appLaunchAllow, [])),
    // ---- 0.7.0 authorization model. `policy` is the ONE knob that says how far this plugin may go
    // without asking again; the per-action `requiresTier` in src/schema/tools.json is the other axis, so
    // adding an action never means adding a setting.
    policy: normalizePolicy(resolveSetting(config.policy, 'balanced')),
    policyIdleMs: clampNumber(resolveSetting(config.policyIdleMs, 3000), 0, 60000, 3000),
    auditKeep: clampNumber(resolveSetting(config.auditKeep, 2000), 100, 200000, 2000),
  };

  const logger = ctx.logger ?? console;
  // ---- the marker -----------------------------------------------------------------------------
  // Deliberately fire-and-forget and deliberately AFTER the action has answered: this is a visual
  // aid, not part of the result, and making it synchronous would put 19ms (plus a one-time ~875ms
  // overlay start) on every click. Two rules keep it honest:
  //   * it is fired after the action request resolves, so a slow overlay start can never delay the
  //     action the user is waiting for;
  //   * the first failure is WARNED, not swallowed -- an overlay that never appears would otherwise
  //     make the README's "AI cursor is a click-through overlay" claim silently untrue.
  // Cost measured over the real worker protocol (.tmp/worker-overlay.mjs): start ~875ms once,
  // marker 19ms, status 15ms, stop ~660ms.
  /** @type {Promise<any>|null} */
  let overlayReady = null;
  let overlayWarned = false;
  const ensureOverlay = () => {
    if (overlayReady) return overlayReady;
    overlayReady = client.request({ action: 'overlay', on: true }).then((env) => {
      if (!env.ok) throw new Error(env.error || 'overlay start refused');
      const st = env.result?.state ?? {};
      if (!st.running) throw new Error(st.reason || 'overlay reported not running');
      if (st.hotkeyRegistered === false) {
        logger.warn?.(`[windows-parallel] pause hotkey unavailable: ${st.reason || 'RegisterHotKey failed'}`);
      } else if (st.hotkeyLabel && st.hotkeyLabel !== 'Ctrl+Alt+Q') {
        logger.warn?.(`[windows-parallel] Ctrl+Alt+Q is owned by another app; the pause key is ${st.hotkeyLabel}`);
      }
      return st;
    }).catch((err) => {
      overlayReady = null;                     // let the next action retry rather than latch off
      if (!overlayWarned) {
        overlayWarned = true;
        logger.warn?.(`[windows-parallel] marker overlay unavailable (${err.message}); actions still work`);
      }
      throw err;
    });
    return overlayReady;
  };
  /**
   * Place the marker at a PHYSICAL screen point. Never awaited by the caller path.
   * Placement RETRIES until the overlay reports running or a 6 s deadline passes -- not as a
   * bandage but because the old single-shot silently broke the shipped promise: a cold worker's
   * handshake can expire while the overlay is genuinely still starting (measured: WPF JIT past the
   * budget), the marker request was then skipped, and the click had already answered so nobody ever
   * retried. A promise with a race window is a promise that loses the race sometimes. The deadline
   * is BOUNDED and a confirmed-dead start (a reason with starting=false) stops the loop immediately
   * and warns -- endless patience would just hide a broken surface.
   * @param {number} x @param {number} y @returns {void}
   */
  const markPoint = (x, y) => {
    if (!settings.overlay || !Number.isFinite(x) || !Number.isFinite(y)) return;
    const mx = Math.round(x);
    const my = Math.round(y);
    void (async () => {
      await ensureOverlay().catch(() => {});     // kick the start; its own failures are warned there
      const deadline = Date.now() + 6000;
      for (;;) {
        const env = await client.request({ action: 'marker', x: mx, y: my }).catch(() => null);
        const res = env?.result;
        if (env?.ok && res?.ok !== false) return;               // placed
        if (res && res.reason === 'overlay not running') {
          const st = await client.request({ action: 'overlay', on: true }).catch(() => null);
          const state = st?.result?.state;
          if (state && state.running) continue;                  // up now; retry placement
          if (state && !state.starting && state.reason) {
            if (!overlayWarned) {
              overlayWarned = true;
              logger.warn?.(`[windows-parallel] marker overlay failed to start (${state.reason}); actions still work`);
            }
            return;                                              // dead for a named reason: stop
          }
        }
        if (Date.now() >= deadline) {
          if (!overlayWarned) {
            overlayWarned = true;
            logger.warn?.('[windows-parallel] marker was not placed within 6s of the click; actions still work');
          }
          return;
        }
        await new Promise((r) => setTimeout(r, 150));
      }
    })().catch(() => { /* warned inside; a marker must never become an unhandled rejection */ });
  };
  logger.info?.(`[windows-parallel] config schema: ${configSource}`);
  const client = new WorkerClient({
    powershellPath: settings.powershellPath,
    script: workerScript(),
    requestTimeoutMs: settings.requestTimeoutMs,
    onStderr: (line) => {
      if (settings.logWorkerStderr) logger.warn?.(`[wpm worker] ${line}`);
    },
    onExit: ({ code }) => {
      logger.warn?.(`[windows-parallel] engine worker exited (code=${code}); it will restart on the next call`);
    },
  });

  /**
   * Wire the host's cancellation into the worker. THE WORKER IS SINGLE-THREADED: while it is inside an
   * action it cannot read a new request, so an 'abort' request alone would be answered only after the
   * action it was meant to stop. The engine therefore polls a latch FILE at the path this writes, and
   * the worker request is sent as well (fire-and-forget) so an idle worker clears its flag too.
   * Two channels because one of them is a local file write that cannot be lost to a wedged loop.
   */
  const activeLatches = new Set();
  /** @param {WpmExec|undefined} exec @returns {() => void} */
  const armAbort = (exec) => {
    const signal = exec?.signal;
    if (!signal || typeof signal.addEventListener !== 'function') return () => {};
    const onAbort = () => {
      const pid = client.child?.pid;
      if (!pid) return;
      const latch = abortLatchPath(pid);
      try {
        mkdirSync(dirname(latch), { recursive: true });
        writeFileSync(latch, 'abort', 'utf8');
        activeLatches.add(latch);
      } catch { /* the HUD button and the abort chord remain available */ }
      void client.request({ action: 'abort' }).catch(() => {});
    };
    if (signal.aborted) { onAbort(); return () => {}; }
    signal.addEventListener('abort', onAbort, { once: true });
    return () => signal.removeEventListener('abort', onAbort);
  };

  const { defineTool } = resolvedTools;

  // Counted rather than logged-and-forgotten: an audit that silently fails to write would leave the
  // operator with a log that LOOKS complete. The count is reported in the result text when non-zero.
  let auditFailures = 0;

  /**
   * The audit line for one call, built once so every exit path writes the same SHAPE. A refusal path
   * that forgot to record would be the hole that makes an audit log useless, so this is called from a
   * single place in `execute` rather than from each return.
   * @param {WpmArgs} args @param {string} decision @param {string} code
   * @param {Record<string, any>} [extra]
   * @returns {{ok:boolean, wrote:boolean, error?:string}}
   */
  const writeAudit = (args, decision, code, extra) => {
    const r = auditLine({
      action: String(args.action ?? ''), hwnd: String(args.hwnd ?? ''),
      tier: String(extra?.tier ?? actionTier(REQUIRES_TIER, String(args.action ?? ''), args.op)),
      policy: settings.policy, decision, code,
      userActiveAgeMs: extra?.userActiveAgeMs, effect: String(extra?.effect ?? ''),
      latencyMs: extra?.latencyMs, detail: extra?.detail,
      forced: args.forceUserActive === true,
      // The two content-free facts about a launch (R1: the whitelist cannot make arguments safe, so the
      // record is what makes a bad one reviewable).
      ...(args.action === 'launch' ? { target: String(args.target ?? ''), args: String(args.args ?? '') } : {}),
      // Clipboard and type: lengths only. A log that copied the clipboard or the typed text would be a
      // second place a secret lives, and the second place is the one nobody protects.
      ...(args.action === 'clipboard' ? { op: String(args.op ?? ''), format: String(args.format ?? 'text') } : {}),
      ...(typeof args.text === 'string' ? { chars: args.text.length } : {}),
      ...(typeof extra?.chars === 'number' ? { resultChars: extra.chars } : {}),
    });
    const w = auditWrite(r, { keep: settings.auditKeep });
    if (!w.ok) auditFailures += 1;
    return w;
  };

  /** Build the worker request for one action. Throws for arguments the action cannot use. */
  /** @param {WpmArgs} args @returns {any} */
  function toRequest(args) {
    const settleMs = clampSettle(args.settleMs ?? settings.settleMs);
    // The takeover fields are attached ONLY when the caller asked for them AND the gate is open. When a
    // gate is closed the field is STRIPPED, not forwarded: a worker that received takeover:true would be
    // free to act on it, and the safe answer to "the gate is off" is the silent-tier request, which the
    // engine then refuses or serves by its own table (task_26).
    const takeover = args.takeover === true && settings.takeoverAllowed;
    const keyInput = takeover && args.keyInput === 'inject' && settings.keyInjectAllowed ? 'inject' : 'none';
    // takeoverArmMs is the OWNER's patience, not the caller's: it comes from settings and is forwarded so
    // the settings surface actually controls the pre-move cancellation window (a setting that never
    // reaches the engine is a form, not a switch).
    const takeoverFields = takeover
      ? {
        takeover: true,
        takeoverMaxMs: clampNumber(args.takeoverMaxMs, 500, 60000, settings.takeoverMaxMs),
        takeoverArmMs: settings.takeoverArmMs,
        ...(keyInput === 'inject' ? { keyInput } : {}),
      }
      : {};
    // ---- 0.7.0 authorization fields, forwarded to the engine for the door actions. The host has ALREADY
    // refused anything above the ceiling (so a refusal here costs zero worker requests); these travel so
    // the engine can apply the idle check, which needs a measurement only it can take.
    const authFields = {
      policy: settings.policy,
      requiredTier: actionTier(REQUIRES_TIER, args.action, args.op),
      policyIdleMs: settings.policyIdleMs,
      ...(args.forceUserActive === true ? { forceUserActive: true } : {}),
    };
    switch (args.action) {
      case 'windows':
        return { action: 'windows' };
      case 'status':
        return { action: 'status' };
      case 'snapshot':
        // A READ. maxElements is the SETTING unless the caller asked for a specific cap, and
        // interactableOnly defaults ON because the frame exists to be decided on, not to be dumped.
        requireArg(args, 'hwnd', 'snapshot');
        return {
          action: 'snapshot',
          hwnd: args.hwnd,
          maxElements: clampNumber(args.maxElements, 1, 5000, settings.snapshotMaxElements),
          interactableOnly: args.interactableOnly !== false,
          sinceSnapId: typeof args.sinceSnapId === 'string' ? args.sinceSnapId : '',
          intent: typeof args.intent === 'string' ? args.intent : '',
        };
      case 'screenshot':
        // fullScreen is the ONLY way to capture without naming a window, and it must be asked for:
        // silently capturing the owner's whole desktop would be exactly the overreach this product
        // refuses elsewhere. A non-fullscreen capture with no hwnd is refused here, before the worker.
        if (args.fullScreen !== true) requireArg(args, 'hwnd', 'screenshot');
        return {
          action: 'screenshot',
          hwnd: args.fullScreen === true ? (args.hwnd ?? '') : args.hwnd,
          fullScreen: args.fullScreen === true,
          maxWidth: clampNumber(args.maxWidth, 0, 7680, settings.screenshotMaxWidth),
          shotsKeep: settings.shotsKeep,
        };
      case 'preview':
        // Silent by construction: no click, no focus, no input queue entry. The engine draws the
        // marker and answers with the element UNDER the point as text.
        requireArg(args, 'hwnd', 'preview');
        requireArg(args, 'x', 'preview');
        requireArg(args, 'y', 'preview');
        return {
          action: 'preview', hwnd: args.hwnd,
          x: Math.round(/** @type {number} */ (args.x)),
          y: Math.round(/** @type {number} */ (args.y)),
        };
      case 'click':
        requireArg(args, 'hwnd', 'click');
        requireArg(args, 'x', 'click');
        requireArg(args, 'y', 'click');
        // The two casts state what `requireArg` just enforced: `WpmArgs.x/y` are optional in the
        // public contract (click requires them, windows does not), and the guard above is the only
        // thing that narrows them. A checker cannot see through a separate function's throw, so this
        // is where the guarantee is recorded -- not a suppression, since requireArg throws for both
        // undefined and null before this line is reached.
        //
        // THE COORDINATE SPACE IS EXPLICIT. 'image' without a shotId is refused HERE, before any worker
        // request: image pixels only mean something relative to a capture, and reinterpreting them as
        // screen pixels would click somewhere plausibly wrong -- the exact failure mode `stale_ref`
        // exists for. A label rides along with its snapId so the engine can resolve the ELEMENT.
        const space = args.space === 'image' ? 'image' : 'screen';
        if (space === 'image' && (typeof args.shotId !== 'string' || args.shotId === '')) {
          throw refusal('stale_ref', 'space:"image" needs the shotId of the screenshot whose pixels you are pointing at; no worker request was made and no coordinate was reinterpreted');
        }
        return {
          action: 'click', hwnd: args.hwnd, x: Math.round(/** @type {number} */ (args.x)), y: Math.round(/** @type {number} */ (args.y)), settleMs,
          ...authFields,
          ...(space === 'image' ? { space: 'image', shotId: args.shotId } : {}),
          ...(typeof args.label === 'number' && args.label > 0
            ? { label: Math.round(args.label), snapId: typeof args.snapId === 'string' ? args.snapId : '' }
            : {}),
          ...takeoverFields,
        };
      case 'type':
        requireArg(args, 'hwnd', 'type');
        if (typeof args.text !== 'string' || args.text.length === 0) {
          // Refused here rather than sent: a write of nothing succeeds silently on every channel,
          // so an empty string is indistinguishable from a dead door.
          throw refusal('unreachable', 'type needs a non-empty text; an empty write cannot be verified');
        }
        return {
          action: 'type', hwnd: args.hwnd, text: args.text,
          elementName: args.elementName ?? '', replace: args.replace === true, settleMs,
          ...authFields,
          // Forwarded only when it is one of the three values the engine declares; anything else is
          // dropped to the default HERE rather than passed on, because the engine's ValidateSet would
          // turn a model's typo into `action_failed` -- and a schema the host already validates against
          // (validateArguments, plus the registered enum) means a wrong value here did not come from a
          // validated call. The drop is logged into the result by the engine's own caret= field, which
          // always reports what was applied.
          caretPosition: args.caretPosition === 'start' || args.caretPosition === 'end' ? args.caretPosition : 'idle',
          ...(typeof args.label === 'number' && args.label > 0
            ? { label: Math.round(args.label), snapId: typeof args.snapId === 'string' ? args.snapId : '' }
            : {}),
          ...takeoverFields,
        };
      case 'focus':
        requireArg(args, 'hwnd', 'focus');
        if ((typeof args.label !== 'number' || args.label <= 0)) requireArg(args, 'elementName', 'focus');
        return {
          action: 'focus', hwnd: args.hwnd, elementName: args.elementName ?? '', settleMs,
          ...authFields,
          ...(typeof args.label === 'number' && args.label > 0
            ? { label: Math.round(args.label), snapId: typeof args.snapId === 'string' ? args.snapId : '' }
            : {}),
          ...takeoverFields,
        };
      case 'launch': {
        // The gates are applied in `execute` BEFORE this line is reached, so a refusal costs no worker
        // request at all; this function only shapes an authorised call. `args` is passed through as one
        // command line -- the whitelist vouches for the program, not for its arguments, which is exactly
        // why the audit records both.
        requireArg(args, 'target', 'launch');
        return {
          action: 'launch', target: args.target,
          ...(typeof args.args === 'string' && args.args ? { args: args.args } : {}),
          waitMs: clampNumber(args.waitMs, 0, 30000, 3000),
          policy: settings.policy, policyIdleMs: settings.policyIdleMs,
          launchAllowed: settings.appLaunchAllowed,
          allowList: settings.appLaunchAllow,
          ...(args.forceUserActive === true ? { forceUserActive: true } : {}),
        };
      }
      case 'clipboard': {
        if (args.op !== 'read' && args.op !== 'write') {
          throw refusal('action_failed', "clipboard needs op:'read' or op:'write'; no worker request was made");
        }
        const format = args.format === 'image' ? 'image' : 'text';
        if (args.op === 'write' && format === 'text' && (typeof args.text !== 'string' || args.text.length === 0)) {
          // Same rule as `type`: an empty write cannot be told apart from a clipboard the owner already
          // cleared, and "the write worked" would then be a claim about nothing.
          throw refusal('action_failed', 'clipboard write needs text; an empty write is indistinguishable from an already-empty clipboard');
        }
        return {
          action: 'clipboard', op: args.op, format,
          ...(format === 'text' && args.op === 'write' ? { text: args.text } : {}),
          ...(format === 'image' && typeof args.shotId === 'string' ? { shotId: args.shotId } : {}),
        };
      }
      case 'window': {
        // An action with no target window is not a convenience, it is the ability to move something
        // nobody named -- so `hwnd` stays mandatory and "the front window" is not a selector here.
        requireArg(args, 'hwnd', 'window');
        const op = String(args.op ?? '');
        if (!['minimize', 'restore', 'move', 'resize', 'topmost'].includes(op)) {
          throw refusal('action_failed', `window needs op=minimize|restore|move|resize|topmost, not '${args.op ?? ''}'; no worker request was made`);
        }
        if (op === 'move' && (typeof args.x !== 'number' || typeof args.y !== 'number')) {
          throw refusal('action_failed', 'window move needs x and y in physical screen pixels; guessing the current position would make the move unreviewable');
        }
        if (op === 'resize' && (typeof args.width !== 'number' || typeof args.height !== 'number')) {
          throw refusal('action_failed', 'window resize needs width and height');
        }
        return {
          action: 'window', hwnd: args.hwnd, op,
          ...(op === 'move' ? { x: Math.round(/** @type {number} */ (args.x)), y: Math.round(/** @type {number} */ (args.y)) } : {}),
          ...(op === 'resize' ? { width: Math.round(/** @type {number} */ (args.width)), height: Math.round(/** @type {number} */ (args.height)) } : {}),
        };
      }
      default:
        throw refusal('no_hwnd', `unknown action '${args.action}'`);
    }
  }

  const tool = defineTool({
    name: TOOL_NAME,
    description:
      'Drive a Windows window: click at a screen coordinate, write text, or move focus inside ONE named '
      + 'window, choosing the cheapest available door. Two tiers are silent: a classic child window is '
      + 'addressed with window messages (measured: zero foreground changes), and a window that only '
      + 'exposes a UI Automation pattern costs one bounded foreground flash that is reversed once '
      + 'afterwards (measured net return 15-95 ms). A THIRD tier exists and is opt-in: takeover:true may '
      + 'move the real cursor to the action point (always restored), hold the focus until the action ends, '
      + 'and -- with keyInput:"inject" -- type into the foreground target through synthetic keyboard input '
      + 'for windows that have no message door and no accessible pattern (terminals). Takeover is refused '
      + 'unless the owner enabled it, always shows a three-phase HUD with a stop button and a global abort '
      + 'key, is interruptible three ways, and never injects mouse events. '
      + 'THREE READ ACTIONS make the target legible without guessing: snapshot returns a NUMBERED element '
      + 'table (a continuous `label`, control type, name, automation id, rect, patterns) that click/type/'
      + 'focus accept as `label`+`snapId`; screenshot writes the window rect to a PNG and returns '
      + 'screenRect/imageSize/scale/identity/frame as data so image coordinates can be handed straight '
      + 'back to click with space:"image" (the engine converts, the caller never multiplies); preview '
      + 'draws the marker at a point and reports, as TEXT, the element under it -- a reviewable click that '
      + 'needs no picture. Refusals carry a code (no_hwnd, '
      + 'paused, elevated_target, unreachable, uia_tree_empty, uia_probe_failed, terminal_no_door, needs_facts, action_failed, '
      + 'restore_failed, takeover_unavailable, keyinject_unavailable, takeover_aborted, stale_ref, app_launch_denied, '
      + 'policy_denied, user_active) and a reason. '
      + 'THREE DESKTOP ACTIONS exist since 0.7.0 and are gated by settings rather than by the target: launch needs '
      + 'appLaunchAllowed AND an exact appLaunchAllow entry (an empty whitelist means nothing, and no wildcard exists); '
      + 'clipboard reads and writes the system clipboard, reporting lengths and never contents; window changes one '
      + 'named window (minimize/restore/move/resize/topmost) and verifies the change by reading the window state back. '
      + 'The single `policy` setting is the ceiling over all eleven actions: a call above it is refused with '
      + 'policy_denied, whose next step is to raise the setting and not to retry. '
      + 'Start with action=windows to get an hwnd, action=snapshot to read a frame, or action=status to see '
      + 'what currently holds the foreground.',
    parameters: PARAMETERS,
    output: {
      schema: {
        type: 'object',
        additionalProperties: true,
        properties: {
          action: { type: 'string', required: true },
          ok: { type: 'boolean', required: true },
          refusal: { type: 'string' },
          text: { type: 'string', required: true },
        },
      },
      // `WpmResult.text` is optional in the public contract (a consumer may hold a partial object),
      // but every value that reaches this render is built by `result()` below, which always sets it.
      // The cast records that invariant instead of substituting '' -- an empty string would be a
      // rendered blank, and the text IS the product here.
      /** @param {WpmArgs} _args @param {WpmResult} value @returns {Array<{type: string, text: string}>} */
      render: (_args, value) => [{ type: 'text', text: /** @type {string} */ (value.text) }],
    },
    /** @param {WpmArgs} args @param {WpmExec|undefined} exec @returns {Promise<Record<string, any>>} */
    async execute(args, exec) {
      // THE GATE ORDER IS THE SAFETY DESIGN, and each gate that can be answered from settings is answered
      // before the worker is touched -- asserted that way with a request counter in test/plugin-test.mjs.
      //   1 paused  2 policy  3 takeover / keyInject  4 launch gate + whitelist  5 (engine) idle  6 table
      // Every exit below goes through `finish`, because an audit written on one path and forgotten on the
      // next is an audit log that looks complete and is not.
      /** True once the audit line for this call has been written -- any second call is ignored. A
       * boolean, not an object: the field's whole job is "have we recorded this yet". */
      let audited = false;
      /** @param {Record<string, any>} res @returns {Record<string, any>} */
      const finish = (res) => {
        if (!audited) {
          audited = true;
          writeAudit(args, res.ok === true ? 'allow' : 'deny', String(res.refusal ?? ''), {
            effect: res.effect, latencyMs: res.latencyMs, chars: res.chars,
            tier: res.tier, detail: res.refusal ? String(res.text ?? '').slice(0, 200) : undefined,
          });
        }
        if (auditFailures) res.text = `${res.text} auditNote=${auditFailures} write(s) failed`;
        return res;
      };
      // Server-side gates first: a paused or disabled engine must refuse before it spends a worker
      // call, and the refusal must name the gate rather than describe a symptom.
      if (!settings.enabled) {
        return finish(result(args.action, false, 'paused', 'windows-parallel is switched off in settings; no action was attempted'));
      }
      // ---- 0.7.0 policy ceiling. ONE setting against the tier the action declares, so a new action
      // never needs a new switch -- and never can slip past one that was never added.
      const pd = policyDecision({
        policy: settings.policy, table: REQUIRES_TIER, action: String(args.action),
        takeoverRequested: args.takeover === true, keyInjectRequested: args.keyInput === 'inject',
        // clipboard is the one action whose two halves live on different rungs; the table refinement is
        // consulted here so `policy:'readonly'` still permits a read while a write is refused.
        op: args.action === 'clipboard' ? args.op : undefined,
      });
      if (pd.denied) {
        return finish(result(args.action, false, 'policy_denied',
          `policy='${settings.policy}' allows at most the '${pd.ceiling}' rung and this call needs '${pd.required}'. Nothing was sent to the worker and no window was touched. Next step is a settings change, not a retry: raise policy in the plugin settings${args.takeover === true ? ' or drop takeover:true' : ''}${args.action === 'clipboard' && args.op === 'write' ? ' (a clipboard READ is allowed at this level)' : ''}`));
      }
      // ---- R3 gates, BEFORE the worker. A refused takeover costs zero worker requests, which is
      // asserted with a request counter in test/plugin-test.mjs: "the gate is checked" is otherwise
      // indistinguishable from "the gate is checked after the expensive part".
      if (args.takeover === true && !settings.takeoverAllowed) {
        return finish(result(args.action, false, 'takeover_unavailable',
          'takeoverAllowed is off in settings; the action was refused rather than silently downgraded to the quiet tier. '
          + 'The quiet tier still works without takeover:true' + hwndHint(args)));
      }
      if (args.keyInput === 'inject' && (!settings.keyInjectAllowed || args.takeover !== true)) {
        return finish(result(args.action, false, 'keyinject_unavailable',
          args.takeover !== true
            ? 'keyInput:"inject" is only available inside the takeover tier (takeover:true): synthetic keys go to the FOREGROUND window, so without the HUD and the cursor contract it would be typing into whatever is in front'
            : 'keyInjectAllowed is off in settings; no keystroke was sent'));
      }
      // ---- 0.7.0 the launch gate, then its whitelist. TWO switches, and the reason they are two is that
      // "the owner enabled the capability" and "this program is on the approved list" are different
      // decisions made at different times; folding them into one would make enabling launch enable every
      // program at once. An empty whitelist refuses even when the gate is on -- that is the point.
      if (args.action === 'launch') {
        if (!settings.appLaunchAllowed) {
          return finish(result('launch', false, 'app_launch_denied',
            'appLaunchAllowed is off in settings, so no program may be started and no worker request was made. The next step is the owner\'s: turn the gate on AND list the exact program in appLaunchAllow'));
        }
        const name = String(args.target ?? '').trim().toLowerCase();
        if (!name) {
          return finish(result('launch', false, 'app_launch_denied', 'launch needs a target program name or path; nothing was started'));
        }
        // EXACT, case-folded membership. No wildcard, no prefix, no path normalisation: `notepad` must not
        // authorise `notepad-helper.exe`, and a rule that grows by prefix is a whitelist in name only.
        if (!settings.appLaunchAllow.includes(name)) {
          return finish(result('launch', false, 'app_launch_denied',
            `'${args.target}' is not on the appLaunchAllow whitelist (which holds ${settings.appLaunchAllow.length} exact name(s)); no process was started. Add the exact name or absolute path -- there is no wildcard and no prefix match${name.includes('\\') ? ' (a path must appear verbatim)' : ''}`));
        }
      }
      // A pre-worker refusal is still a refusal, not a thrown error. The first version of this file
      // let `toRequest` throw for an empty write, and the caller saw a crashed tool call instead of
      // `unreachable` -- the exact "refusal became an exception" defect this plugin's own comment
      // above warns about. Caught by test/plugin-test.mjs, which asserts the code is returned.
      let request;
      try {
        request = toRequest(args);
      } catch (err) {
        // `catch` binds `unknown` under strict, which is correct: anything can be thrown. The casts
        // are the narrowing step, kept INLINE so the statements and local names below are exactly what
        // they were -- `scripts`-level AST comparison against the previous revision is a gate here, and
        // a rename would make a comment-only change look like a behaviour change. Safe on this path
        // because the only thrower is `refusal()` above; the `??` fallbacks still keep the vocabulary
        // intact when it is not.
        const code = /** @type {WpmError} */ (err)?.refusal ?? 'action_failed';
        return finish(result(args.action, false, code, /** @type {WpmError} */ (err)?.reason ?? String(/** @type {WpmError} */ (err)?.message ?? err)));
      }
      let envelope;
      const disarm = request.takeover ? armAbort(exec) : () => {};
      try {
        envelope = await client.request(request);
      } catch (err) {
        // The worker layer failed (crash, timeout, missing engine). This is not a refusal code: the
        // engine never got to decide. Say exactly that instead of borrowing a code it does not own.
        // Cast inline for the same reason as above. No `String(...)` wrapper and no `?.` are added:
        // the original read `err.message` directly, and a non-Error thrown here still renders the
        // same way it always did -- widening the expression would be a behaviour change dressed as
        // type safety, which is exactly what this file refuses to do.
        return finish(result(args.action, false, 'action_failed', `engine worker unavailable: ${/** @type {Error} */ (err).message}`));
      } finally {
        disarm();
      }
      if (!envelope.ok) {
        return finish(result(args.action, false, 'action_failed', `worker error: ${envelope.error ?? 'unknown'}`));
      }
      // click coordinates are SCREEN pixels (the engine converts to client space itself), so the
      // marker can be placed straight from the request -- no second coordinate system to get wrong.
      // Only a click that actually ran places a marker: a refused click has no impact point, and
      // letting a refusal start the overlay would mean a dead hwnd silently spawns a WPF window.
      const r = envelope.result;
      if (request.action === 'click' && r && r.ok !== false && !r.refusal) {
        // With space:'image' the request coordinates are IMAGE pixels; the engine reports the screen
        // point it actually converted to, and the marker must be drawn THERE. Drawing it at the image
        // pixel would put the visible cursor somewhere other than where the click landed -- a marker
        // that lies is worse than no marker, because the README sells it as the point that was acted on.
        const screen = request.space === 'image' ? parsePoint(r.screenPoint) : null;
        markPoint(screen ? screen.x : request.x, screen ? screen.y : request.y);
      }
      return finish(format(args.action, envelope.result));
    },
  });

  ctx.tools.register(tool);
  ctx.on?.('dispose', () => {
    // A latch that outlives the worker would abort the NEXT worker's first takeover (the path is keyed
    // by pid, so a new process gets a new path -- this is belt and braces, and it keeps %LOCALAPPDATA%
    // tidy for an operator reading it).
    for (const latch of activeLatches) { try { rmSync(latch, { force: true }); } catch { } }
    activeLatches.clear();
    void client.dispose();
  });
  // No return value. Cordis treats whatever `apply` returns as a disposable effect, so returning the
  // registered tool is at best ignored and at worst an "Invalid effect" that disables the plugin --
  // the same class of failure as the async apply, one step further in.
}

// ---- small helpers ---------------------------------------------------------------------------

/** A Cordis settings value may be a live ref (0.1.7+) or a plain value (older lines). */
/** @param {any} value @param {any} fallback @returns {any} */
function resolveSetting(value, fallback) {
  if (value === undefined || value === null) return fallback;
  const v = typeof value.get === 'function' ? value.get() : value;
  if (v === undefined || v === null) return fallback;
  return v;
}

/**
 * The launch whitelist, as the gate sees it: trimmed, empties dropped, LOWER-CASED for comparison.
 * Case-folding is a deliberate decision and it is stated here rather than left to the reader: Windows
 * treats program names and paths case-insensitively, so a whitelist that was case-sensitive would
 * refuse `notepad.exe` when the owner wrote `NOTEPAD.EXE` -- and an operator who is refused for a
 * spelling difference starts adding wildcards, which is the failure this list exists to prevent.
 * @param {any} value @returns {string[]}
 */
function normalizeAllowList(value) {
  if (!Array.isArray(value)) return [];
  return value.filter((x) => typeof x === 'string' && x.trim() !== '').map((x) => x.trim().toLowerCase());
}

/**
 * The policy level, defaulted rather than trusted. A typo in a bundle patch (`banlanced`) must not
 * become "full" -- the safe direction for an unparseable authorization setting is the DOWNGRADE, and
 * `balanced` is the documented default that the README and the settings form both describe.
 * @param {any} value @returns {'readonly'|'quiet'|'balanced'|'full'}
 */
function normalizePolicy(value) {
  return value === 'readonly' || value === 'quiet' || value === 'full' ? value : 'balanced';
}

/** @param {any} value @returns {number} */
function clampSettle(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 350;
  return Math.max(0, Math.min(2000, Math.round(n)));
}

/**
 * @param {Record<string, any>} args
 * @param {'hwnd'|'x'|'y'|'text'|'elementName'|'target'} key
 * @param {string} action
 * @returns {void}
 */
function requireArg(args, key, action) {
  if (args[key] === undefined || args[key] === null || args[key] === '') {
    throw refusal('no_hwnd', `action=${action} requires '${key}'`);
  }
}

/**
 * A refusal thrown before the worker is reached; caught by the caller path that renders results.
 * @param {RefusalCode} code
 * @param {string} reason
 * @returns {WpmError}
 */
function refusal(code, reason) {
  // The cast is the definition of this function's payload: a plain Error plus the two fields the
  // caller path reads. Writing it after construction (rather than using a subclass) keeps `instanceof
  // Error` true for the host, which is what the catch sites rely on.
  const err = /** @type {WpmError} */ (new Error(`${code}: ${reason}`));
  err.refusal = code;
  err.reason = reason;
  return err;
}

/**
 * @param {string} action
 * @param {boolean} ok
 * @param {RefusalCode|''} refusalCode
 * @param {string} text
 * @param {Record<string, any>} [extra]
 * @returns {Record<string, any>}
 */
function result(action, ok, refusalCode, text, extra) {
  return { action, ok, refusal: refusalCode, text: refusalCode ? `${refusalCode}: ${text}` : text, ...(extra || {}) };
}

/**
 * Turn a worker result into the tool's output value.
 *
 * The text is the product. A caller that gets `ok:false` with a code and a reason can act; a caller
 * that gets "the action failed" cannot. Every number reported here is measured by the engine, not
 * inferred by this file.
 * @param {string} action
 * @param {any} r
 * @returns {Record<string, any>}
 */
function format(action, r) {
  if (!r) return result(action, false, 'action_failed', 'engine returned no result');

  if (action === 'windows') {
    const list = Array.isArray(r.windows) ? r.windows : [];
    if (list.length === 0) {
      return result(action, true, '', 'no drivable windows are visible right now (minimised and untitled windows are excluded by design)');
    }
    const lines = list.map(/** @param {any} w @returns {string} */ (w) => `${w.hwnd}  ${truncate(String(w.title), 60)}  [${w.cls}] pid=${w.pid} rect=${w.rect}`);
    return result(action, true, '', `${list.length} drivable window(s):\n${lines.join('\n')}`);
  }

  if (action === 'status') {
    const bits = [
      `paused=${r.paused === true}`,
      `foreground=${r.foreground || '(none)'}`,
      `foregroundPid=${r.foregroundPid || '(none)'}`,
      `focusedControl=${r.focusControl || '(none)'}`,
      `lastHumanInputAgeMs=${r.lastInputAgeMs ?? 'unknown'}`,
    ];
    // The control surface travels with status. Without it, "the overlay is on" and "the pause key
    // registered" are claims the user cannot check -- and this machine's desktop already owns
    // Ctrl+Alt+Q, so the real chord is not the documented one. Silence here would be a lie.
    bits.push(`overlay=${r.overlayRunning === true ? 'on' : 'off'}`);
    // The takeover surface, on the same principle: the owner must be able to check "is the HUD up and
    // which abort key is real" without inferring it from a successful call.
    bits.push(`hud=${r.hudOn === true ? 'on' : 'off'}`);
    if (r.abortChord) bits.push(`abortChord=${r.abortChord}`);
    // The overlay's hwnd, so an INDEPENDENT oracle can verify the exact window the product thinks
    // it is showing. Title-matching alone cannot do this: a leaked overlay from an earlier run is
    // also titled WpmOverlay, and grading that instead of ours would make the marker arms grade
    // homework that is not even in this class.
    if (r.overlayHwnd && r.overlayHwnd !== '0') bits.push(`overlayHwnd=${r.overlayHwnd}`);
    bits.push(`pauseHotkey=${r.hotkeyRegistered === true ? (r.hotkeyLabel || 'registered') : 'unavailable'}`);
    if (r.overlayReason) bits.push(`overlayNote=${r.overlayReason}`);
    if (r.pauseReason) bits.push(`pauseReason=${r.pauseReason}`);
    // The DPI stance is a FACT the read paths depend on: rects and captured pixels are physical only
    // while this process is per-monitor DPI aware. Reporting it here is what keeps a future deletion of
    // the setter from turning into a silent half-scale coordinate system (the marker already proved
    // that failure mode: 470,410 acted on at 303,263 on this 150% display).
    bits.push(`dpiAware=${r.dpiAware === true}`);
    if (r.stance) bits.push(`stance: ${r.stance}`);
    return result(action, true, '', bits.join('\n'));
  }

  // Action results. `refusal` is the engine's own code: an empty string means the action ran.
  // The cast leans on `scripts/check-refusals.mjs`, which pins the engine's emitted codes to the
  // closed set in src/schema/tools.json: the wire format is a string, but the vocabulary is a
  // contract that another gate already enforces. Typing this as plain `string` would push the check
  // to every call site; typing it as `RefusalCode` names where the guarantee actually comes from.
  const code = r.refusal ? /** @type {RefusalCode} */ (String(r.refusal)) : '';
  if (code) {
    const reason = r.reason ? ` (${r.reason})` : '';
    // A takeover refusal still carries the takeover accounting: "aborted after 12 characters, cursor
    // restored" is the information that makes an interruption harmless instead of alarming.
    if (r.takeover === 'true') {
      const extra = ` [takeover=on cursorRestored=${r.cursorRestored === 'true'} injectedChars=${r.injectedChars ?? 0}`
        + `${r.abortChord ? ` abortChord=${r.abortChord}` : ''}]`;
      return result(action, false, code, `${code}${reason}${extra}`, {
        takeover: 'on', cursorRestored: r.cursorRestored === 'true', injectedChars: r.injectedChars ?? 0,
      });
    }
    return result(action, false, code, `${code}${reason}`);
  }

  // ---- 0.5.0 READ RESULTS ---------------------------------------------------------------------
  // These three have no channel, no tier and no proof window: there is no action to prove. Rendering
  // happens HERE (not in the engine) for the same reason every other action's text does -- one place
  // owns "what the model reads", and the engine stays a JSON protocol.
  if (action === 'snapshot') return formatSnapshot(r);
  if (action === 'screenshot') return formatScreenshot(r);
  if (action === 'preview') return formatPreview(r);
  // ---- 0.7.0 DESKTOP RESULTS -----------------------------------------------------------------
  // No channel, no tier, no proof window: these actions do not choose a door and there is no
  // disturbance for a proof to attribute. What they DO carry is a read-back of the state they changed,
  // rendered explicitly so a caller can see the difference between "the syscall answered" and "the
  // window is like that now".
  if (action === 'launch') return formatLaunch(r);
  if (action === 'clipboard') return formatClipboard(r);
  if (action === 'window') return formatWindow(r);

  // WHO REPORTED THE SUCCESS. The engine sets `effect` when a channel call RETURNS without throwing;
  // this file never upgrades it, and the four values are not degrees of confidence in the app -- they
  // name who is speaking (README's table states the same four lines, keep them in step):
  //   unverified           no channel reported success at all;
  //   reported-by-send     the window message was DELIVERED -- nothing here proves the target app
  //                        processed it;
  //   reported-by-pattern  the UIA pattern call RETURNED -- nothing here proves the interface changed;
  //   readback-verified    0.6.0: the value was READ BACK after the settle window and equals the value
  //                        predicted from measurements the CONTROL reported. This is the only value that
  //                        is about the application rather than about the call, and the engine grants it
  //                        only on an exact match -- a masked field reports readback=unavailable and an
  //                        app that reformatted the input reports readbackMismatch=true, neither of which
  //                        is an upgrade (findings 8.1/8.2).
  // Read the first three as "who says it worked", never as "the application's state is confirmed".
  const bits = [
    `${action} ok`,
    `channel=${r.channel || '?'}`,
    `tier=${r.tier || '?'}`,
    `effect=${r.effect || 'unverified'}`,
    `focusTaken=${r.focusTaken === 'true' || r.focusTaken === true}`,
  ];
  // The takeover accounting. Every number here was measured by the engine (cursor read-backs, the
  // injected-character counter, the chord that actually registered) -- nothing in this file infers it.
  if (r.takeover === 'true') {
    bits.push('takeover=on');
    bits.push(`cursorMoved=${r.cursorMoved === 'true'}`);
    bits.push(`cursorRestored=${r.cursorRestored === 'true'}`);
    if (r.takeoverMs !== undefined) bits.push(`takeoverMs=${r.takeoverMs}`);
    if (r.abortChord) bits.push(`abortChord=${r.abortChord}`);
    if (r.keysInjected !== undefined) bits.push(`keysInjected=${r.keysInjected}`);
    bits.push(`injectedChars=${r.injectedChars ?? 0}`);
    if (r.cursorRestoreReason) bits.push(`cursorRestoreReason=${r.cursorRestoreReason}`);
    if (r.takeoverNote) bits.push(`takeoverNote=${r.takeoverNote}`);
  }
  // THE PROOF. The engine sampled cursor/foreground/focus/last-input-age in TWO windows: a short
  // pre-action CONTROL (captured while, by construction, nothing was done) and the settle window
  // AFTER the door call. The judgment is arithmetic and lives in one pure implementation
  // (proof-window.mjs), never here and never in the README. Three verdicts, and their asymmetry is
  // the whole point -- see proof-window.mjs's header for the idle-baseline measurement behind it:
  //   pass          no unexplained cursor gap, no unexplained foreground/focus switch;
  //   inconclusive  the desktop moved or switched in a way position data cannot attribute to the
  //                 action (the idle baseline proved our absence does not imply desktop stillness);
  //   fail          a foreground/focus switch the control shows the desktop was NOT doing, on a tier
  //                 that did not DECLARE a bounded flash.
  // `declaredFlash` is the decision table's own needsRestore: on the bounded-flash tier the engine
  // DELIBERATELY raises foreground inside the window and restores it after -- the promise of that
  // tier was never "don't touch", it is "don't keep", and the restore table owns that promise
  // (restore_failed surfaces separately). Sampling cannot be allowed to contradict the contract.
  // A missing/short window is 'insufficient': silence is not innocence.
  const proof = evaluateProof(r.proofSamples || [], {
    control: r.proofControl || [],
    declaredFlash: r.tier === 'bounded-flash',
    // The takeover tier DELIBERATELY moves the cursor and may hold the foreground; the promise it makes
    // is "nothing was kept", not "nothing was touched". A cursor that was not restored still fails, and
    // does so through the same evaluator instead of a special case here.
    declaredTakeover: r.tier === 'takeover',
    cursorRestored: r.cursorRestored === 'false' ? false : undefined,
    // The effect travels into the judgment, not just into the text. Without this, "nothing worked"
    // still reads as proof=pass whenever the desktop happened to stay still (R2 in the plan). One call
    // is one action, so `actions` is left to batch callers; a channel that reported NOTHING here caps
    // the verdict at inconclusive rather than inventing a red on a single quiet call.
    effect: r.effect || 'unverified',
  });
  bits.push(`proof=${proof.verdict}(${proof.reason})`);
  if (r.restoreOutcome) bits.push(`restore=${r.restoreOutcome}`);
  if (r.flashMs !== undefined) bits.push(`flashMs=${r.flashMs}`);
  if (r.latencyMs !== undefined) bits.push(`latencyMs=${r.latencyMs}`);
  if (r.detail) bits.push(`detail=${r.detail}`);
  return result(action, true, '', bits.join(' '), {
    proof: proof.verdict,
    proofDimensions: proof.dimensions,
    effect: r.effect || 'unverified',
    // A converted point travels back with the result so the caller can check the arithmetic it never
    // performed. `screenPoint` is the fact the marker is drawn from, too: with space:'image' the
    // request's own x/y are image pixels and would put the visible marker in the wrong place.
    ...(r.coordSpace === 'image'
      ? { coordSpace: 'image', shotId: r.shotId, imagePoint: r.imagePoint, screenPoint: r.screenPoint, scale: r.scale }
      : {}),
    ...(r.takeover === 'true'
      ? { takeover: 'on', cursorRestored: r.cursorRestored === 'true', injectedChars: r.injectedChars ?? 0 }
      : {}),
  });
}

/** @param {string} s @param {number} n @returns {string} */
function truncate(s, n) {
  return s.length <= n ? s : `${s.slice(0, n - 1)}…`;
}

/**
 * One element row of a snapshot frame. The format is the contract the caller reasons on, so it is
 * fixed here: `label  ControlType  "Name"  [AutomationId]  rect=l,t,r,b  patterns=...`. The label is
 * what a deciding side answers with; the rect is in PHYSICAL screen pixels, in the same space as
 * screenRect, which is what makes `space:"image"` conversion possible without a second coordinate table.
 * @param {any} e @returns {string}
 */
function elementLine(e) {
  const rc = e?.rect ?? {};
  const pats = Array.isArray(e?.patterns) ? e.patterns : [];
  return `${e?.label ?? '?'}  ${e?.controlType ?? '?'}  "${e?.name ?? ''}"  [${e?.automationId ?? ''}]  `
    + `rect=${rc.left ?? '?'},${rc.top ?? '?'},${rc.right ?? '?'},${rc.bottom ?? '?'}  `
    + `patterns=${pats.length ? pats.join('|') : 'none'}`;
}

/**
 * Render a snapshot frame.
 *
 * WHY THE DELTA IS A FIRST-CLASS FORM. Repeating an unchanged 70-row table between two steps is the
 * dominant token cost of a multi-step flow, and it is pure noise: nothing in it changed. With
 * `sinceSnapId` the answer is "no changes" plus the three lists that DID move. The full table stays
 * available -- this is an option, not a replacement.
 * @param {any} r @returns {Record<string, any>}
 */
function formatSnapshot(r) {
  const rows = Array.isArray(r.elements) ? r.elements : [];
  const count = Number.isFinite(r.count) ? Number(r.count) : rows.length;
  const total = Number.isFinite(r.total) ? Number(r.total) : count;
  const truncated = r.truncated === true || r.truncated === 'true';
  const delta = r.delta && typeof r.delta === 'object' ? r.delta : null;
  const added = Array.isArray(delta?.added) ? delta.added : [];
  const removed = Array.isArray(delta?.removed) ? delta.removed : [];
  const changed = Array.isArray(delta?.changed) ? delta.changed : [];

  const head = `snapshot ok: ${count} element(s)`
    + (truncated ? ` (truncated at ${count} of ${total})` : '')
    + (delta ? ` (delta vs ${delta.sinceSnapId}: +${added.length} -${removed.length} ~${changed.length})` : '');
  const meta = [`snapId=${r.snapId || '?'}`, `frame=${r.frame || '?'}`, `frameCheck=${r.frameCheck || '?'}`, `total=${total}`];
  if (r.frameInset && typeof r.frameInset === 'object') {
    meta.push(`frameInset=${r.frameInset.left ?? '?'},${r.frameInset.top ?? '?'},${r.frameInset.right ?? '?'},${r.frameInset.bottom ?? '?'}`);
  }
  if (Number.isFinite(r.outsideFrame) && Number(r.outsideFrame) > 0) {
    meta.push(`outsideFrame=${r.outsideFrame}`);
  }
  if (r.intent) meta.push(`intent=${r.intent}`);
  const lines = [head, meta.join(' ')];

  if (delta) {
    if (added.length === 0 && removed.length === 0 && changed.length === 0) {
      lines.push(`no changes since ${delta.sinceSnapId}`);
    } else {
      for (const a of added) lines.push(`  + ${elementLine(a)}`);
      for (const m of removed) lines.push(`  - ${elementLine(m)}`);
      for (const c of changed) lines.push(`  ~ ${elementLine(c)}  changed=${(Array.isArray(c.changed) ? c.changed : []).join(',')}`);
    }
  } else if (count === 0) {
    // A REAL ANSWER, said out loud. This deliberately does NOT reuse uia_tree_empty: that code means
    // "UI Automation is switched off in the application" and its next step is relaunching the app.
    // Zero visible elements on a window that answers fine (measured: Clash, Everything) has no such
    // next step, so inventing one would be the canned message this product refuses.
    lines.push('0 element(s) is a real state: this window exposes no visible element to UI Automation right now. '
      + 'It is not uia_tree_empty (that code is about the application disabling accessibility) and it is not a failure.');
  } else {
    for (const e of rows) lines.push(elementLine(e));
  }
  if (r.frame === 'win32') {
    lines.push('note: frame=win32 -- DWM EXTENDED_FRAME_BOUNDS was unavailable, so this frame came from GetWindowRect and includes the invisible resize shadow. '
      + 'The frame check above passed (it compares the frame against the window rect the tree reports), but the capture and the labels are both 8px larger than the visible window edge.');
  }
  if (r.frameCheck === 'unknown') {
    lines.push('note: frameCheck=unknown -- the accessibility tree would not report its root rect, so the frame could not be cross-checked. Labels are still in physical screen pixels; treat an edge-of-window label with suspicion.');
  }
  if (Number(r.outsideFrame) > 0) {
    lines.push(`note: ${r.outsideFrame} element(s) were excluded because their rect does not overlap the captured frame; a label you cannot point at inside the capture would be a trap, so they are counted here instead of numbered.`);
  }
  return result('snapshot', true, '', lines.join('\n'), {
    snapId: r.snapId, elements: rows, count, total, truncated, frameCheck: r.frameCheck, intent: r.intent ?? '',
    // The delta travels structurally too: a caller that branches on "did anything move" must not have
    // to parse the text, and the counts are the same numbers the head line prints.
    ...(delta ? { delta } : {}),
    ...(r.frameInset ? { frameInset: r.frameInset } : {}),
    ...(Number.isFinite(r.outsideFrame) ? { outsideFrame: Number(r.outsideFrame) } : {}),
  });
}

/**
 * Render a screenshot: the mapping is the product, the file is the delivery.
 * @param {any} r @returns {Record<string, any>}
 */
function formatScreenshot(r) {
  const rect = r.screenRect && typeof r.screenRect === 'object' ? r.screenRect : {};
  const size = r.imageSize && typeof r.imageSize === 'object' ? r.imageSize : {};
  const scale = typeof r.scale === 'number' ? r.scale : 1;
  const identity = r.identity === true || r.identity === 'true';
  const dpiAware = r.dpiAware === true || r.dpiAware === 'true';
  const lines = [
    `screenshot ok: ${size.width ?? '?'}x${size.height ?? '?'} px (scale=${scale} identity=${identity}) frame=${r.frame || '?'} captureBackend=${r.captureBackend || '?'} dpiAware=${dpiAware}`,
    `file=${r.file || '?'}`,
    `shotId=${r.shotId || '?'}`,
    `screenRect=${rect.left ?? '?'},${rect.top ?? '?'},${rect.right ?? '?'},${rect.bottom ?? '?'} `
      + `imageSize=${size.width ?? '?'}x${size.height ?? '?'} bytes=${r.bytes ?? '?'} shotsKeep=${r.shotsKeep ?? '?'} latencyMs=${r.latencyMs ?? '?'}`,
    'mapping: screenX = screenRect.left + round(imageX / scale); screenY = screenRect.top + round(imageY / scale). '
      + `The ENGINE applies this when a click passes space:"image" with shotId=${r.shotId || '?'}; do not multiply it yourself.`,
  ];
  // 0.6.0-B. The cheap path is BitBlt and the fallback is Graphics.CopyFromScreen; they are measured
  // equivalent on a still scene (identical size, identical PNG bytes, 0 per-channel difference over
  // 17388 sample points) and they are NOT the same call, so which one ran is part of the result rather
  // than an implementation detail. A note appears only when the fast path was refused.
  if (!r.captureBackend) lines.push('note: captureBackend was not reported by the engine -- this result predates 0.6.0 or the engine is out of step with this build.');
  if (r.captureNote) lines.push(`note: ${r.captureNote} -- the picture came from Graphics.CopyFromScreen this time.`);
  if (identity) {
    lines.push('identity=true means the image was NOT resampled: image pixels and screen pixels differ only by the rect origin.');
  }
  if (r.frame === 'win32') {
    lines.push('note: frame=win32 -- DWM EXTENDED_FRAME_BOUNDS was unavailable, so screenRect came from GetWindowRect and includes the invisible shadow. '
      + 'Coordinates stay consistent with THIS capture, but a click at the very edge can land on the shadow rather than the client area.');
  }
  return result('screenshot', true, '', lines.join('\n'), {
    shotId: r.shotId, file: r.file, screenRect: rect, imageSize: size,
    scale, identity, frame: r.frame, captureBackend: r.captureBackend, dpiAware,
  });
}

/**
 * Render a preview. The report is text on purpose: "what is under that point" is answered by the OS,
 * so confirming a point never depends on the model's reading of a picture.
 * @param {any} r @returns {Record<string, any>}
 */
function formatPreview(r) {
  const x = r.previewX ?? '?';
  const y = r.previewY ?? '?';
  const atPoint = r.previewAtPoint === true || r.previewAtPoint === 'true';
  const head = atPoint && r.previewControlType
    ? `preview: would click ${x},${y} -> ${r.previewControlType} "${r.previewName || ''}"`
      + (r.previewAutomationId ? ` [${r.previewAutomationId}]` : '')
    : `preview: would click ${x},${y} -> no element is exposed at that point`;
  const rect = r.previewRect && typeof r.previewRect === 'object' ? r.previewRect : {};
  const lines = [
    head,
    `rect=${rect.left ?? '?'},${rect.top ?? '?'},${rect.right ?? '?'},${rect.bottom ?? '?'}`,
    `marker=${r.markerPlaced === true || r.markerPlaced === 'true' ? 'placed' : 'unavailable'}${r.markerReason ? ` (${r.markerReason})` : ''}`,
  ];
  if (r.previewReason) lines.push(`reason: ${r.previewReason}`);
  lines.push('no click was sent: a preview writes no input-queue entry, takes no focus, and produces no proof window');
  return result('preview', true, '', lines.join('\n'), {
    preview: {
      x, y,
      name: r.previewName ?? '', controlType: r.previewControlType ?? '', automationId: r.previewAutomationId ?? '',
    },
  });
}

/**
 * Render a launch. The two facts that matter are the pid (the process exists) and whether it has
 * published a window yet -- and the second is reported as `window-not-yet` rather than as a failure,
 * because Process.Start returning while MainWindowHandle is 0 is normal (measured 1348 ms cold).
 * An agent that is told "started, no window yet" can poll or pick a different target; an agent that is
 * told "failed" when the program is running will start it again.
 * @param {any} r @returns {Record<string, any>}
 */
function formatLaunch(r) {
  const lines = [
    `launch ok: pid=${r.pid ?? '?'} name=${r.processName ?? '?'}`,
    `detail=${r.detail || '(none)'}`,
  ];
  if (r.hwnd) lines.push(`hwnd=${r.hwnd} -- the window is addressable now; use it with action=snapshot or click`);
  else lines.push('hwnd=(none yet) -- the process is running but has published no top-level window; this is NOT a failure, and retrying the launch would start a second copy');
  if (r.note) lines.push(`note: ${r.note}`);
  if (r.latencyMs !== undefined) lines.push(`latencyMs=${r.latencyMs} waitedMs=${r.waitedMs ?? 0}`);
  return result('launch', true, '', lines.join('\n'), {
    pid: r.pid, hwnd: r.hwnd || '', processName: r.processName, waitedMs: r.waitedMs,
    effect: r.effect || 'unverified',
  });
}

/**
 * Render a clipboard result. THE VALUE IS DELIBERATELY ABSENT from a text read's summary line: it is
 * present in the structured field the caller asked for, and the text says what it is rather than
 * being it -- a log line or a screenshot of this result should not become a second copy of whatever was
 * on the clipboard.
 * @param {any} r @returns {Record<string, any>}
 */
function formatClipboard(r) {
  const lines = [];
  if (r.clipFormat === 'image') {
    lines.push(`clipboard ${r.op ?? ''} ok: image size=${r.readbackSize || r.imageSize || '?'}`);
    if (r.file) lines.push(`file=${r.file}`);
    if (r.clipId) lines.push(`clipId=${r.clipId}`);
    if (r.shotId) lines.push(`shotId=${r.shotId}`);
  } else {
    lines.push(`clipboard ${r.op ?? ''} ok: text chars=${r.chars ?? r.readbackChars ?? '?'}`);
    if (r.truncated) lines.push(`truncated: the clipboard held ${r.chars} characters and the 64 KB cap applies -- the value was cut, not lost`);
  }
  lines.push(`effect=${r.effect || 'unverified'}`);
  if (r.latencyMs !== undefined) lines.push(`latencyMs=${r.latencyMs}`);
  if (r.detail) lines.push(`detail=${r.detail}`);
  lines.push('privacy: a clipboard READ reports its length, never its content; the audit log records op/format/length only, because the clipboard may hold a token the owner copied seconds ago');
  return result('clipboard', true, '', lines.join('\n'), {
    clipFormat: r.clipFormat, chars: r.chars, truncated: r.truncated === true,
    file: r.file, clipId: r.clipId, imageSize: r.imageSize, readbackSize: r.readbackSize,
    effect: r.effect || 'unverified',
  });
}

/**
 * Render a window op. `verified` is the word the whole action is built around: the op's own read-back
 * (IsIconic, the rect, the ex-style) said yes, not `ShowWindow` returning true.
 * @param {any} r @returns {Record<string, any>}
 */
function formatWindow(r) {
  const lines = [
    `window ok: ${r.detail || '(no detail)'}`,
    `effect=${r.effect || 'unverified'}`,
  ];
  if (r.latencyMs !== undefined) lines.push(`latencyMs=${r.latencyMs}`);
  if (r.reason) lines.push(`reason: ${r.reason}`);
  lines.push('verified means the WINDOW reports the state (IsIconic / the rect / WS_EX_TOPMOST), not that the syscall answered; move/resize/topmost never activate the window');
  return result('window', true, '', lines.join('\n'), {
    effect: r.effect || 'unverified', detail: r.detail,
    // Forwarded, not re-derived: `foregroundTaken` is the engine's measurement of GetForegroundWindow on
    // both sides of the call. Dropping it here would leave the claim in the prose and out of the object,
    // which is how a caller that reads structure ends up less informed than one that reads text.
    foregroundTaken: r.foregroundTaken === true,
    verified: /verified=true/.test(String(r.detail ?? '')),
  });
}

/** Parse an engine-emitted "x,y" point. Returns null for anything else rather than guessing 0,0. */
/** @param {any} s @returns {{x: number, y: number}|null} */
function parsePoint(s) {
  if (typeof s !== 'string') return null;
  const m = s.match(/^(-?\d+),(-?\d+)$/);
  if (!m) return null;
  return { x: Number(m[1]), y: Number(m[2]) };
}

/** Clamp a possibly-undefined number into [min,max], falling back to `fallback` for non-numbers. */
/** @param {any} value @param {number} min @param {number} max @param {number} fallback @returns {number} */
function clampNumber(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.round(n)));
}

/** The same latch path the engine computes: %LOCALAPPDATA%\wpm\takeover-abort.<worker pid>. */
/** @param {number|string} pid @returns {string} */
function abortLatchPath(pid) {
  const base = process.env.LOCALAPPDATA || tmpdir();
  return join(base, 'wpm', `takeover-abort.${pid}`);
}

/** A one-line target hint for a pre-worker refusal: the caller can retry without the field. */
/** @param {WpmArgs} args @returns {string} */
function hwndHint(args) {
  return args.hwnd ? ` (target hwnd=${args.hwnd})` : '';
}

// Exported for tests: the projection from the five contract actions to this one tool.
// `formatResult` is here so the effect dimension can be asserted on the SHIPPED projection, with
// hand-authored engine results, without a desktop that has to cooperate.
export const _internals = { PARAMETERS, ACTIONS, TOOL_NAME, clampSettle, CONFIG_DEFAULTS, formatResult: format };
