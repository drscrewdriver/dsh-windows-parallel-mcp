// host-tools.js — the one host-provided helper this plugin needs, with a fallback that is not a lie.
//
// WHY A FALLBACK AT ALL. `defineTool` lives in `@deepseek-ai/dsh-tools`, a peer the host provides.
// Peer resolution for a plugin loaded out of the profile's node_modules is the host's business, not
// the plugin's, and it is not something this package can verify from inside itself: a static import
// turns "the host resolves peers differently than I assumed" into "the plugin fails to load, with no
// tool and no message". So the import is dynamic, and when it fails the local shim takes over.
//
// WHAT THE SHIM IS AND IS NOT. It is NOT a reimplementation of the host's tool runtime: it builds the
// same registry-ready shape from the same simplified parameter spec (per-field `type` / `description`
// / `enum` / `required: true`, exactly the shape dsh-bash-terminal-ts passes) and validates arguments
// against it, because a schema that nothing validates is a description, not a contract. What it does
// not do is the host's own error branding and presentation hooks; those are additive.
//
// REFUSALS ARE NOT ERRORS HERE. The engine answers refusals as normal results carrying a code
// (decide.ps1's closed set). This layer must not convert them into thrown exceptions -- a thrown
// error would reach the model as a tool failure, and the whole point of the refusal vocabulary is
// that the caller can branch on the code and read the next step.
export const TOOL_NAME = 'wpm';

/** The eight actions, in the order the contract lists them. */
export const ACTIONS = ['windows', 'click', 'type', 'focus', 'status', 'snapshot', 'screenshot', 'preview'];

/**
 * One field of the simplified parameter spec -- the shape the host's `defineTool` consumes and the
 * shape `parametersToJsonSchema` translates. `required` is optional HERE and mandatory in the
 * registered JSON Schema, which is the whole reason `parametersToJsonSchema` destructures it out:
 * spelling that with a per-field object literal instead would make `field.required` a property that
 * does not exist on most members (TS2339), i.e. the checker saying what the data already says.
 * @typedef {object} ParamSpec
 * @property {'string'|'number'|'boolean'} type
 * @property {string} [description]
 * @property {string[]} [enum]
 * @property {boolean} [required]
 */

/**
 * The JSON Schema this plugin registers, as `parametersToJsonSchema` builds it.
 * @typedef {object} SimplifiedSchema
 * @property {string} [type]
 * @property {Record<string, ParamSpec>} [properties]
 * @property {string[]} [required]
 * @property {boolean} [additionalProperties]
 */

/** Simplified parameter spec — the same shape the host's `defineTool` consumes. */
/** @type {Record<string, ParamSpec>} */
export const PARAMETERS = {
  action: {
    type: 'string',
    enum: ACTIONS,
    required: true,
    description:
      'windows: list live windows that can be driven (hwnd, title, class, pid, rect). '
      + 'status: read the focus table (foreground window, focused control, last human input age, paused flag). '
      + 'click: click at a screen coordinate inside the target. type: write text into the target. '
      + 'focus: move keyboard focus to a named control inside the target. '
      + 'snapshot: read the accessibility tree as a numbered element table (labels you can act on). '
      + 'screenshot: capture the target rect to a PNG and return its coordinate mapping as data. '
      + 'preview: draw the marker at a point and report the element under it, without clicking.',
  },
  hwnd: {
    type: 'string',
    description: 'Target top-level window handle from action=windows. Required by click, type and focus.',
  },
  x: { type: 'number', description: 'Screen X coordinate (click only). Must resolve to a child of the target, or the action is refused.' },
  y: { type: 'number', description: 'Screen Y coordinate (click only).' },
  text: { type: 'string', description: 'Text to write (type only). The message tier inserts at the control\'s caret (position 0 when it was never focused); replace:true rewrites the whole value instead. An empty string is refused: it cannot be distinguished from a channel that silently did nothing.' },
  elementName: {
    type: 'string',
    description:
      'UIA Name or AutomationId of the control to address (type/focus). Naming an element forces the UIA tier, '
      + 'because a window message cannot address "the control called X".',
  },
  replace: { type: 'boolean', description: 'Replace the existing value instead of appending (type only).' },
  settleMs: { type: 'number', description: 'How long to let the app commit its state before the effect is judged (0-2000, default 350).' },
  // ---- R3. Every one of these costs the owner something real, so each description says so: a caller
  // that asks for takeover has to know it moves the pointer and needs the HUD up.
  takeover: {
    type: 'boolean',
    description:
      'Take the takeover tier: the REAL cursor moves to the action point (so the owner can see where the '
      + 'agent is pointing) and is always restored afterwards, the focus is held until the action ends, '
      + 'and a three-phase HUD is shown with a stop button and a global abort key. Requires the '
      + 'takeoverAllowed setting, otherwise it is refused with takeover_unavailable (it never degrades '
      + 'silently into the quiet tier). Interruptible three ways: HUD button, abort key, host cancellation.',
  },
  takeoverMaxMs: {
    type: 'number',
    description: 'Takeover only: how long the action may hold the cursor/focus (500-60000, default 10000). The HUD counts up to it.',
  },
  keyInput: {
    type: 'string',
    enum: ['none', 'inject'],
    description:
      'Takeover only: "inject" types the text with synthetic KEYBOARD input (SendInput, Unicode) into the '
      + 'foreground window, for targets with no message door and no UIA pattern (terminals). Requires '
      + 'takeover:true and the keyInjectAllowed setting; the target must be the foreground window or the '
      + 'call is refused with keyinject_unavailable. Never moves the mouse, never clicks. The result '
      + 'reports effect=reported-by-send, not "verified".',
  },
  // ---- 0.5.0: the frame / label / image-coordinate surface -----------------------------------
  // Every description below says what the field costs or what it refuses, because each one exists to
  // remove a way for the caller to silently act on the wrong thing.
  label: {
    type: 'number',
    description:
      'Element number from action=snapshot (click/type/focus). The label is resolved back to the UIA '
      + 'ELEMENT by RuntimeId, so the action still takes the silent pattern path instead of degrading to '
      + 'a coordinate click. For click, x/y stay required and must fall inside the labelled element, so '
      + '"the point is the contract" remains true.',
  },
  snapId: {
    type: 'string',
    description:
      'The snapId the label came from. A label whose snapId has been superseded is refused with '
      + 'stale_ref: element numbers only mean something in the frame that printed them.',
  },
  space: {
    type: 'string',
    enum: ['screen', 'image'],
    description:
      'Coordinate space of click x/y. "screen" (default) is physical screen pixels. "image" means image '
      + 'pixels from the screenshot named by shotId -- the ENGINE converts them, so the caller never '
      + 'multiplies a scale factor; the point-ownership assertion still runs after conversion.',
  },
  shotId: {
    type: 'string',
    description:
      'The shotId from action=screenshot. Required when space="image" (refused before any worker call); '
      + 'an id that was already cleaned up by the retention policy is refused with stale_ref.',
  },
  maxElements: {
    type: 'number',
    description: 'snapshot only: hard cap on returned elements (1-5000, default 300). The text then says "truncated at N of M" and truncated is true.',
  },
  interactableOnly: {
    type: 'boolean',
    description: 'snapshot only (default true): return only elements exposing a usable UIA pattern. false returns the whole visible tree.',
  },
  sinceSnapId: {
    type: 'string',
    description: 'snapshot only: return an added/removed/changed diff against this earlier snapId instead of the whole table. An unchanged tree yields an empty delta.',
  },
  intent: {
    type: 'string',
    description: 'snapshot only: what this frame is FOR. It travels with the frame so a deciding subagent can answer with a single label.',
  },
  fullScreen: {
    type: 'boolean',
    description: 'screenshot only (default false): capture the whole virtual screen instead of one window. Off by default so the owner\'s desktop is never captured silently.',
  },
  maxWidth: {
    type: 'number',
    description: 'screenshot only: downscale the saved image to at most this width (0 = no scaling, default). Scaling changes the coordinate system, so it must be asked for explicitly and is reported as scale.',
  },
};

/**
 * Build a JSON Schema from the simplified spec.
 *
 * Kept separate and exported so test/schema-test.mjs can compare the shape this plugin registers
 * against src/schema/tools.json: the contract file is the source of truth, and a divergence between
 * "what the model is told" and "what the registry accepts" is invisible until a call is rejected.
 * @param {Record<string, ParamSpec>} [spec]
 * @returns {SimplifiedSchema}
 */
export function parametersToJsonSchema(spec = PARAMETERS) {
  /** @type {Record<string, any>} */
  const properties = {};
  /** @type {string[]} */
  const required = [];
  for (const [name, field] of Object.entries(spec)) {
    const { required: isRequired, ...rest } = field;
    properties[name] = rest;
    if (isRequired) required.push(name);
  }
  return { type: 'object', properties, required, additionalProperties: false };
}

/**
 * Minimal argument validation. Returns a list of human-readable violations, empty when valid.
 * @param {SimplifiedSchema} schema
 * @param {any} args
 * @returns {string[]}
 */
export function validateArguments(schema, args) {
  /** @type {string[]} */
  const problems = [];
  if (args === null || typeof args !== 'object' || Array.isArray(args)) return ['arguments must be an object'];
  for (const name of schema.required ?? []) {
    if (args[name] === undefined || args[name] === null) problems.push(`missing required argument '${name}'`);
  }
  for (const [name, value] of Object.entries(args)) {
    const field = schema.properties?.[name];
    if (!field) {
      problems.push(`unknown argument '${name}'`);
      continue;
    }
    if (value === undefined || value === null) continue;
    if (field.type === 'string' && typeof value !== 'string') problems.push(`'${name}' must be a string`);
    if (field.type === 'number' && typeof value !== 'number') problems.push(`'${name}' must be a number`);
    if (field.type === 'boolean' && typeof value !== 'boolean') problems.push(`'${name}' must be a boolean`);
    if (Array.isArray(field.enum) && !field.enum.includes(value)) {
      problems.push(`'${name}' must be one of ${field.enum.join(', ')}`);
    }
  }
  return problems;
}

/**
 * The local shim: same input, same registry-ready output shape.
 * @param {{name: string, description: string, parameters: Record<string, ParamSpec>,
 *   output: {schema: any, render: any}, execute: (args: any, exec: any) => any}} options
 * @returns {any}
 */
export function localDefineTool(options) {
  const parameters = parametersToJsonSchema(options.parameters);
  const userExecute = options.execute;
  return {
    name: options.name,
    description: options.description,
    parameters,
    output: {
      schema: options.output.schema,
      render: options.output.render,
    },
    // THE SECOND ARGUMENT IS THE CALL CONTEXT, and dropping it silently disables cancellation: the plugin
    // asks the host for `exec.signal` to abort a takeover in flight, and a wrapper that forwards only
    // `args` makes that code path unreachable -- the abort arrives, nothing is listening, and the call
    // runs to completion. Measured: the first version of this shim did exactly that, and test/signal-test.mjs
    // caught it as "the cancellation was not reported" while everything else looked green.
    /** @param {any} args @param {any} exec @returns {Promise<any>} */
    async execute(args, exec) {
      const problems = validateArguments(parameters, args);
      if (problems.length) {
        const err = new Error(`${options.name}: ${problems.join('; ')}`);
        err.name = 'ToolArgsError';
        throw err;
      }
      return userExecute(args, exec);
    },
  };
}

/**
 * Resolve the host's `defineTool`, falling back to the local shim.
 * Returns `{ defineTool, source }` so the plugin can log which one it got -- a silent fallback is how
 * "runs on my machine" diverges from "runs on the host".
 */
export async function resolveDefineTool() {
  // The peer is reached through ./peers-tools.js with a STATIC import -- the host's loader resolves
  // the bare specifier there, while a dynamic `import('@deepseek-ai/dsh-tools')` from a
  // `link:`-installed package resolves upward from the link target and never reaches the profile's
  // node_modules. peers-tools.js throwing means dsh-tools genuinely is not installed (this desktop
  // profile: it is not): the shim takes over and `source` says so. See peers-schemastery.js for why
  // the two peers have separate bridges.
  try {
    const mod = await import('./peers-tools.js');
    if (mod && typeof mod.defineTool === 'function') return { defineTool: mod.defineTool, source: '@deepseek-ai/dsh-tools' };
  } catch {
    // Documented fallback, reported via `source`.
  }
  return { defineTool: localDefineTool, source: 'local-shim' };
}
