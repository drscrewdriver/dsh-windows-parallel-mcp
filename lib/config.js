// config.js — the settings surface, built on the host's schema library when it is reachable and on a
// standard-schema shim when it is not.
//
// WHY THIS FILE EXISTS AT ALL. The first version exported `Config` as a factory function. Cordis
// requires a *standard-schema value* — it calls `Config['~standard'].validate(config)` — so the
// plugin failed to activate with `Cannot read properties of undefined (reading 'validate')`, and the
// only reason it was found is that the profile was actually booted (`dsh --profile wpm-dev headless`)
// instead of being assumed good from a passing unit test. A plugin that never activates is the worst
// failure mode available: it registers no tool, prints one warning into a busy log, and looks
// installed.
//
// WHY NOT A HARD DEPENDENCY. `@deepseek-ai/schemastery` is a host-provided peer. Declaring it as a
// dependency would drag a second copy of the schema library into the profile, and declaring it as a
// peer would make install fail wherever the host resolves peers differently than it does here. So the
// import is attempted, and the shim is the documented fallback.
//
// WHAT THE SHIM IS. A standard-schema implementation over a flat, explicitly typed field list. It
// applies defaults, rejects wrong types and out-of-range values, and reports issues in the shape
// Cordis renders. It is NOT schemastery: the settings FORM is rendered from schemastery's field
// metadata, so a host that cannot resolve schemastery gives the user no form — the values still work
// from the bundle patch. That limitation is stated in the README rather than papered over.
const FIELDS = [
  { key: 'enabled', type: 'boolean', default: true, volatile: true,
    description: 'Master switch. When off, every action refuses with `paused` before the engine is reached.' },
  { key: 'settleMs', type: 'number', default: 350, min: 0, max: 2000, volatile: true,
    description: 'How long the target app gets to commit its state before the effect is judged.' },
  { key: 'requestTimeoutMs', type: 'number', default: 20000, min: 1000, max: 600000,
    description: 'A worker that stops answering is killed and restarted on the next call.' },
  { key: 'powershellPath', type: 'string', default: '',
    description: 'Override the PowerShell executable. Windows PowerShell 5.1 is the floor; pwsh is accepted.' },
  { key: 'logWorkerStderr', type: 'boolean', default: false, volatile: true,
    description: 'Forward the sidecar’s stderr diagnostics to the host log.' },
];

/** Defaults, for documentation and for tests that must not depend on a resolver. */
export const CONFIG_DEFAULTS = Object.fromEntries(FIELDS.map((f) => [f.key, f.default]));

/** Validate one raw config object against FIELDS. Returns `{ value, issues }` standard-schema style. */
function validateWithShim(raw) {
  const input = raw && typeof raw === 'object' ? raw : {};
  const value = {};
  const issues = [];
  for (const field of FIELDS) {
    const given = input[field.key];
    if (given === undefined || given === null) { value[field.key] = field.default; continue; }
    if (field.type === 'boolean') {
      if (typeof given !== 'boolean') issues.push({ message: `expected a boolean`, path: [field.key] });
      else value[field.key] = given;
    } else if (field.type === 'number') {
      if (typeof given !== 'number' || !Number.isFinite(given)) {
        issues.push({ message: `expected a finite number`, path: [field.key] });
      } else if ((field.min !== undefined && given < field.min) || (field.max !== undefined && given > field.max)) {
        issues.push({ message: `expected ${field.min}..${field.max}`, path: [field.key] });
      } else {
        value[field.key] = given;
      }
    } else if (typeof given !== 'string') {
      issues.push({ message: `expected a string`, path: [field.key] });
    } else {
      value[field.key] = given;
    }
  }
  for (const key of Object.keys(input)) {
    if (!FIELDS.some((f) => f.key === key)) {
      // Unknown keys are an issue, not silence: a typo in the bundle patch would otherwise take the
      // default and leave the user wondering why their setting did nothing.
      issues.push({ message: `unknown setting`, path: [key] });
    }
  }
  return issues.length ? { issues } : { value };
}

const shimSchema = {
  '~standard': {
    version: 1,
    vendor: 'dsh-windows-parallel-mcp',
    validate: validateWithShim,
  },
  /** Marker parity with schemastery so `typeof field.volatile === 'function'` probes behave. */
  fields: FIELDS,
};

/**
 * Build the Config value. Tries the host's schema library first; falls back to the shim.
 * Returns `{ schema, source }` so the caller can log which one is active -- a silent fallback is how
 * "works on my machine" diverges from "works on the host".
 */
export async function createConfigSchema() {
  try {
    const mod = await import('@deepseek-ai/schemastery');
    const z = mod?.default ?? mod;
    if (z && typeof z.object === 'function') {
      const shape = {};
      for (const field of FIELDS) {
        let s;
        if (field.type === 'boolean') s = z.boolean();
        else if (field.type === 'number') s = z.number();
        else s = z.string();
        if (field.min !== undefined || field.max !== undefined) {
          if (typeof s.min === 'function' && field.min !== undefined) s = s.min(field.min);
          if (typeof s.max === 'function' && field.max !== undefined) s = s.max(field.max);
        }
        if (field.description) s = s.description(field.description);
        s = s.default(field.default);
        // `.volatile()` marks a field as hot-reloadable on 0.1.7+. Guarded because older schema
        // lines in the same major do not have it.
        if (field.volatile && typeof s.volatile === 'function') s = s.volatile();
        shape[field.key] = s;
      }
      const schema = z.object(shape);
      return { schema: typeof schema.prefault === 'function' ? schema.prefault({}) : schema, source: '@deepseek-ai/schemastery' };
    }
  } catch {
    // Documented fallback, reported through `source`.
  }
  return { schema: shimSchema, source: 'local-standard-schema-shim' };
}
