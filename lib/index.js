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
import { WorkerClient, workerScript } from './engine.js';
import { ACTIONS, PARAMETERS, TOOL_NAME, resolveDefineTool } from './host-tools.js';

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
 */
export function apply(ctx, config = {}) {
  const settings = {
    enabled: resolveSetting(config.enabled, true),
    settleMs: resolveSetting(config.settleMs, 350),
    requestTimeoutMs: resolveSetting(config.requestTimeoutMs, 20000),
    powershellPath: resolveSetting(config.powershellPath, ''),
    logWorkerStderr: resolveSetting(config.logWorkerStderr, false),
  };

  const logger = ctx.logger ?? console;
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

  const { defineTool } = resolvedTools;

  /** Build the worker request for one action. Throws for arguments the action cannot use. */
  function toRequest(args) {
    const settleMs = clampSettle(args.settleMs ?? settings.settleMs);
    switch (args.action) {
      case 'windows':
        return { action: 'windows' };
      case 'status':
        return { action: 'status' };
      case 'click':
        requireArg(args, 'hwnd', 'click');
        requireArg(args, 'x', 'click');
        requireArg(args, 'y', 'click');
        return { action: 'click', hwnd: args.hwnd, x: Math.round(args.x), y: Math.round(args.y), settleMs };
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
        };
      case 'focus':
        requireArg(args, 'hwnd', 'focus');
        requireArg(args, 'elementName', 'focus');
        return { action: 'focus', hwnd: args.hwnd, elementName: args.elementName, settleMs };
      default:
        throw refusal('no_hwnd', `unknown action '${args.action}'`);
    }
  }

  const tool = defineTool({
    name: TOOL_NAME,
    description:
      'Drive a Windows window without moving the cursor or stealing the keyboard: click at a screen '
      + 'coordinate, write text, or move focus inside ONE named window, choosing the cheapest available '
      + 'door. A classic child window is addressed with window messages (measured: zero foreground '
      + 'changes). A window that only exposes a UI Automation pattern costs one bounded foreground flash '
      + 'that is reversed once afterwards (measured net return 15-95 ms). The real cursor never moves in '
      + 'either tier, no keystrokes are synthesized, and the tool never pulls focus back from a window '
      + 'the user chose. Refusals carry a code (no_hwnd, paused, elevated_target, unreachable, '
      + 'terminal_no_door, needs_facts, action_failed, restore_failed) and a reason. Start with '
      + 'action=windows to get an hwnd, or action=status to see what currently holds the foreground.',
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
      render: (_args, value) => [{ type: 'text', text: value.text }],
    },
    async execute(args) {
      // Server-side gates first: a paused or disabled engine must refuse before it spends a worker
      // call, and the refusal must name the gate rather than describe a symptom.
      if (!settings.enabled) {
        return result(args.action, false, 'paused', 'windows-parallel is switched off in settings; no action was attempted');
      }
      // A pre-worker refusal is still a refusal, not a thrown error. The first version of this file
      // let `toRequest` throw for an empty write, and the caller saw a crashed tool call instead of
      // `unreachable` -- the exact "refusal became an exception" defect this plugin's own comment
      // above warns about. Caught by test/plugin-test.mjs, which asserts the code is returned.
      let request;
      try {
        request = toRequest(args);
      } catch (err) {
        const code = err?.refusal ?? 'action_failed';
        return result(args.action, false, code, err?.reason ?? String(err?.message ?? err));
      }
      let envelope;
      try {
        envelope = await client.request(request);
      } catch (err) {
        // The worker layer failed (crash, timeout, missing engine). This is not a refusal code: the
        // engine never got to decide. Say exactly that instead of borrowing a code it does not own.
        return result(args.action, false, 'action_failed', `engine worker unavailable: ${err.message}`);
      }
      if (!envelope.ok) {
        return result(args.action, false, 'action_failed', `worker error: ${envelope.error ?? 'unknown'}`);
      }
      return format(args.action, envelope.result);
    },
  });

  ctx.tools.register(tool);
  ctx.on?.('dispose', () => { void client.dispose(); });
  // No return value. Cordis treats whatever `apply` returns as a disposable effect, so returning the
  // registered tool is at best ignored and at worst an "Invalid effect" that disables the plugin --
  // the same class of failure as the async apply, one step further in.
}

// ---- small helpers ---------------------------------------------------------------------------

/** A Cordis settings value may be a live ref (0.1.7+) or a plain value (older lines). */
function resolveSetting(value, fallback) {
  if (value === undefined || value === null) return fallback;
  const v = typeof value.get === 'function' ? value.get() : value;
  if (v === undefined || v === null) return fallback;
  return v;
}

function clampSettle(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 350;
  return Math.max(0, Math.min(2000, Math.round(n)));
}

function requireArg(args, key, action) {
  if (args[key] === undefined || args[key] === null || args[key] === '') {
    throw refusal('no_hwnd', `action=${action} requires '${key}'`);
  }
}

/** A refusal thrown before the worker is reached; caught by the caller path that renders results. */
function refusal(code, reason) {
  const err = new Error(`${code}: ${reason}`);
  err.refusal = code;
  err.reason = reason;
  return err;
}

function result(action, ok, refusalCode, text) {
  return { action, ok, refusal: refusalCode, text: refusalCode ? `${refusalCode}: ${text}` : text };
}

/**
 * Turn a worker result into the tool's output value.
 *
 * The text is the product. A caller that gets `ok:false` with a code and a reason can act; a caller
 * that gets "the action failed" cannot. Every number reported here is measured by the engine, not
 * inferred by this file.
 */
function format(action, r) {
  if (!r) return result(action, false, 'action_failed', 'engine returned no result');

  if (action === 'windows') {
    const list = Array.isArray(r.windows) ? r.windows : [];
    if (list.length === 0) {
      return result(action, true, '', 'no drivable windows are visible right now (minimised and untitled windows are excluded by design)');
    }
    const lines = list.map((w) => `${w.hwnd}  ${truncate(String(w.title), 60)}  [${w.cls}] pid=${w.pid} rect=${w.rect}`);
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
    if (r.pauseReason) bits.push(`pauseReason=${r.pauseReason}`);
    if (r.stance) bits.push(`stance: ${r.stance}`);
    return result(action, true, '', bits.join('\n'));
  }

  // Action results. `refusal` is the engine's own code: an empty string means the action ran.
  const code = r.refusal ? String(r.refusal) : '';
  if (code) {
    const reason = r.reason ? ` (${r.reason})` : '';
    return result(action, false, code, `${code}${reason}`);
  }

  const bits = [
    `${action} ok`,
    `channel=${r.channel || '?'}`,
    `tier=${r.tier || '?'}`,
    `focusTaken=${r.focusTaken === 'true' || r.focusTaken === true}`,
  ];
  if (r.restoreOutcome) bits.push(`restore=${r.restoreOutcome}`);
  if (r.flashMs !== undefined) bits.push(`flashMs=${r.flashMs}`);
  if (r.latencyMs !== undefined) bits.push(`latencyMs=${r.latencyMs}`);
  if (r.detail) bits.push(`detail=${r.detail}`);
  return result(action, true, '', bits.join(' '));
}

function truncate(s, n) {
  return s.length <= n ? s : `${s.slice(0, n - 1)}…`;
}

// Exported for tests: the projection from the five contract actions to this one tool.
export const _internals = { PARAMETERS, ACTIONS, TOOL_NAME, clampSettle, CONFIG_DEFAULTS };
