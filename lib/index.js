// index.js — the host half: one tool, one worker, and the refusal vocabulary kept intact.
//
// THE SHAPE OF THIS FILE IS THE FORM DECISION. R3.1' in spec.md recorded the fork as
//   A. DSH native plugin: the host registers the tool directly; PowerShell is a sidecar.
//   B. MCP server: the host talks to a separate MCP process over stdio.
// The owner chose A on 2026-11-19. Concretely that means: no `@modelcontextprotocol/sdk`, no bridge
// row, no second Node process — the tool is registered here and the only child process is the
// PowerShell worker, which the engine already needed in either form.
//
// WHY ONE TOOL AND NOT FIVE. src/schema/tools.json names five actions as the contract surface. The
// host convention (shell / terminal / read / write in this same build) is one tool with an action
// discriminator, because every registered tool is resident schema on every turn — five entries
// describing one engine is a standing token cost for no gain in capability. The contract is
// preserved exactly: same five actions, same eight refusal codes, same required arguments. The
// mapping is asserted in test/plugin-test.mjs against the contract file, so "we project to one tool"
// cannot quietly become "we support four actions".
//
// THE THREE THINGS THIS FILE MUST GET RIGHT, each of which would look like a working plugin while
// being wrong:
//   1. A disappeared worker must not become a dead tool. The client restarts once and reports.
//   2. A refusal must survive as a refusal. It is returned in the result text with its code, never
//      swallowed and never turned into a generic failure — R3.2 forbids canned messages.
//   3. `paused` and `enabled` are server-side gates. They are checked here, before any worker call,
//      because a prompt-level hint is not a switch (R2.5).
import { createConfigSchema, CONFIG_DEFAULTS } from './config.js';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { WorkerClient, workerScript } from './engine.js';
import { ACTIONS, PARAMETERS, TOOL_NAME, resolveDefineTool } from './host-tools.js';
import { evaluateProof } from './proof-window.mjs';

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
    switch (args.action) {
      case 'windows':
        return { action: 'windows' };
      case 'status':
        return { action: 'status' };
      case 'click':
        requireArg(args, 'hwnd', 'click');
        requireArg(args, 'x', 'click');
        requireArg(args, 'y', 'click');
        // The two casts state what `requireArg` just enforced: `WpmArgs.x/y` are optional in the
        // public contract (click requires them, windows does not), and the guard above is the only
        // thing that narrows them. A checker cannot see through a separate function's throw, so this
        // is where the guarantee is recorded -- not a suppression, since requireArg throws for both
        // undefined and null before this line is reached.
        return { action: 'click', hwnd: args.hwnd, x: Math.round(/** @type {number} */ (args.x)), y: Math.round(/** @type {number} */ (args.y)), settleMs, ...takeoverFields };
      case 'type':
        requireArg(args, 'hwnd', 'type');
        if (typeof args.text !== 'string' || args.text.length === 0) {
          // Refused here rather than sent: a write of nothing succeeds silently on every channel,
          // so an empty string is indistinguishable from a dead door.
          throw refusal('unreachable', 'type needs a non-empty text; an empty write cannot be verified');
        }
        return {
          action: 'type', hwnd: args.hwnd, text: args.text,
          elementName: args.elementName ?? '', replace: args.replace === true, settleMs, ...takeoverFields,
        };
      case 'focus':
        requireArg(args, 'hwnd', 'focus');
        requireArg(args, 'elementName', 'focus');
        return { action: 'focus', hwnd: args.hwnd, elementName: args.elementName, settleMs, ...takeoverFields };
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
      + 'key, is interruptible three ways, and never injects mouse events. Refusals carry a code (no_hwnd, '
      + 'paused, elevated_target, unreachable, terminal_no_door, needs_facts, action_failed, '
      + 'restore_failed, takeover_unavailable, keyinject_unavailable, takeover_aborted) and a reason. '
      + 'Start with action=windows to get an hwnd, or action=status to see what currently holds the '
      + 'foreground.',
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
      // Server-side gates first: a paused or disabled engine must refuse before it spends a worker
      // call, and the refusal must name the gate rather than describe a symptom.
      if (!settings.enabled) {
        return result(args.action, false, 'paused', 'windows-parallel is switched off in settings; no action was attempted');
      }
      // ---- R3 gates, BEFORE the worker. A refused takeover costs zero worker requests, which is
      // asserted with a request counter in test/plugin-test.mjs: "the gate is checked" is otherwise
      // indistinguishable from "the gate is checked after the expensive part".
      if (args.takeover === true && !settings.takeoverAllowed) {
        return result(args.action, false, 'takeover_unavailable',
          'takeoverAllowed is off in settings; the action was refused rather than silently downgraded to the quiet tier. '
          + 'The quiet tier still works without takeover:true' + hwndHint(args));
      }
      if (args.keyInput === 'inject' && (!settings.keyInjectAllowed || args.takeover !== true)) {
        return result(args.action, false, 'keyinject_unavailable',
          args.takeover !== true
            ? 'keyInput:"inject" is only available inside the takeover tier (takeover:true): synthetic keys go to the FOREGROUND window, so without the HUD and the cursor contract it would be typing into whatever is in front'
            : 'keyInjectAllowed is off in settings; no keystroke was sent');
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
        return result(args.action, false, code, /** @type {WpmError} */ (err)?.reason ?? String(/** @type {WpmError} */ (err)?.message ?? err));
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
        return result(args.action, false, 'action_failed', `engine worker unavailable: ${/** @type {Error} */ (err).message}`);
      } finally {
        disarm();
      }
      if (!envelope.ok) {
        return result(args.action, false, 'action_failed', `worker error: ${envelope.error ?? 'unknown'}`);
      }
      // click coordinates are SCREEN pixels (the engine converts to client space itself), so the
      // marker can be placed straight from the request -- no second coordinate system to get wrong.
      // Only a click that actually ran places a marker: a refused click has no impact point, and
      // letting a refusal start the overlay would mean a dead hwnd silently spawns a WPF window.
      const r = envelope.result;
      if (request.action === 'click' && r && r.ok !== false && !r.refusal) {
        markPoint(request.x, request.y);
      }
      return format(args.action, envelope.result);
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

/** @param {any} value @returns {number} */
function clampSettle(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 350;
  return Math.max(0, Math.min(2000, Math.round(n)));
}

/**
 * @param {Record<string, any>} args
 * @param {'hwnd'|'x'|'y'|'text'|'elementName'} key
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

  // WHO REPORTED THE SUCCESS. The engine sets `effect` when a channel call RETURNS without throwing;
  // this file never upgrades it, and the three values are not degrees of confidence in the app -- they
  // name who is speaking (README's table states the same three lines, keep them in step):
  //   unverified           no channel reported success at all;
  //   reported-by-send     the window message was DELIVERED -- nothing here proves the target app
  //                        processed it;
  //   reported-by-pattern  the UIA pattern call RETURNED -- nothing here proves the interface changed.
  // Read as "who says it worked", never as "the application's state is confirmed".
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
    ...(r.takeover === 'true'
      ? { takeover: 'on', cursorRestored: r.cursorRestored === 'true', injectedChars: r.injectedChars ?? 0 }
      : {}),
  });
}

/** @param {string} s @param {number} n @returns {string} */
function truncate(s, n) {
  return s.length <= n ? s : `${s.slice(0, n - 1)}…`;
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
