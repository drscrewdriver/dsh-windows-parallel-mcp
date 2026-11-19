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

/** The five actions, in the order the contract lists them. */
export const ACTIONS = ['windows', 'click', 'type', 'focus', 'status'];

/** Simplified parameter spec — the same shape the host's `defineTool` consumes. */
export const PARAMETERS = {
  action: {
    type: 'string',
    enum: ACTIONS,
    required: true,
    description:
      'windows: list live windows that can be driven (hwnd, title, class, pid, rect). '
      + 'status: read the focus table (foreground window, focused control, last human input age, paused flag). '
      + 'click: click at a screen coordinate inside the target. type: write text into the target. '
      + 'focus: move keyboard focus to a named control inside the target.',
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
};

/**
 * Build a JSON Schema from the simplified spec.
 *
 * Kept separate and exported so test/schema-test.mjs can compare the shape this plugin registers
 * against src/schema/tools.json: the contract file is the source of truth, and a divergence between
 * "what the model is told" and "what the registry accepts" is invisible until a call is rejected.
 */
export function parametersToJsonSchema(spec = PARAMETERS) {
  const properties = {};
  const required = [];
  for (const [name, field] of Object.entries(spec)) {
    const { required: isRequired, ...rest } = field;
    properties[name] = rest;
    if (isRequired) required.push(name);
  }
  return { type: 'object', properties, required, additionalProperties: false };
}

/** Minimal argument validation. Returns a list of human-readable violations, empty when valid. */
export function validateArguments(schema, args) {
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

/** The local shim: same input, same registry-ready output shape. */
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
    async execute(args) {
      const problems = validateArguments(parameters, args);
      if (problems.length) {
        const err = new Error(`${options.name}: ${problems.join('; ')}`);
        err.name = 'ToolArgsError';
        throw err;
      }
      return userExecute(args);
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
