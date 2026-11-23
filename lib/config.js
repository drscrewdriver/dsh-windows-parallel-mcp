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

/**
 * One declarable setting. `type` is a closed string union rather than a string so the four-way
 * branch in both validators is checked as exhaustive by the reader, not just by the shim at runtime.
 * `string[]` exists for one reason: `appLaunchAllow` is a whitelist, and a whitelist that has to be
 * spelled inside a string is a whitelist that will be parsed differently by two readers.
 * @typedef {object} ConfigField
 * @property {string} key
 * @property {'boolean'|'number'|'string'|'string[]'} type
 * @property {any} default
 * @property {number} [min]
 * @property {number} [max]
 * @property {boolean} [volatile]
 * @property {string} [description]
 */

/** @type {ConfigField[]} */
const FIELDS = [
  { key: 'enabled', type: 'boolean', default: true, volatile: true,
    description: 'Master switch. When off, every action refuses with `paused` before the engine is reached.' },
  { key: 'settleMs', type: 'number', default: 350, min: 0, max: 2000, volatile: true,
    description: 'How long the target app gets to commit its state before the effect is judged.' },
  { key: 'requestTimeoutMs', type: 'number', default: 20000, min: 1000, max: 600000,
    description: 'A worker that stops answering is killed and restarted on the next call.' },
  { key: 'powershellPath', type: 'string', default: '',
    description: 'Override the PowerShell executable. Windows PowerShell 5.1 is the floor; pwsh is accepted.' },
  { key: 'overlay', type: 'boolean', default: true, volatile: true,
    description: 'Show the click-through AI marker at the point each action touched. It never takes '
      + 'the foreground and never intercepts a click (measured). The first action pays a one-time '
      + 'worker round-trip while the overlay starts; after that a placement costs ~19ms and does not '
      + 'gate the action result.' },
  { key: 'logWorkerStderr', type: 'boolean', default: false, volatile: true,
    description: 'Forward the sidecar’s stderr diagnostics to the host log.' },
  // ---- R3 gates. BOTH DEFAULT OFF, and that is a product decision, not timidity: with them off the
  // tool behaves exactly like 0.1.6 (zero physical input), so an upgrade cannot silently start moving
  // the owner's cursor. Turning takeover on is the owner's explicit act.
  { key: 'takeoverAllowed', type: 'boolean', default: false, volatile: true,
    description: 'Allow actions to request the takeover tier (takeover:true): the real cursor is moved '
      + 'to the action point and always restored, the focus is held for the duration, and a three-phase '
      + 'HUD is mandatory. Off by default; when off, a takeover request is refused with '
      + 'takeover_unavailable and the action is NOT silently downgraded.' },
  { key: 'keyInjectAllowed', type: 'boolean', default: false, volatile: true,
    description: 'Allow keyboard injection (keyInput:"inject") inside the takeover tier, for targets '
      + 'with no message door and no UIA pattern (terminals). Text is typed into the FOREGROUND window '
      + 'after asserting it is the target; never mouse injection. Off by default.' },
  { key: 'takeoverMaxMs', type: 'number', default: 10000, min: 500, max: 60000, volatile: true,
    description: 'How long a takeover action may hold the owner’s cursor/focus before it must end. '
      + 'Hard ceiling 60s; the HUD shows the elapsed/limit clock so a long action is visible.' },
  { key: 'takeoverArmMs', type: 'number', default: 800, min: 0, max: 5000, volatile: true,
    description: 'Length of the HUD’s arming phase: the window in which the owner can cancel before '
      + 'the cursor moves or a key is typed. 0 disables the wait (the HUD still shows).' },
  // ---- 0.5.0 read-path settings. Each one is a COST the owner can see, not a hidden default:
  // a snapshot cap, an explicit downscale, and a retention count. Nothing here changes the input
  // stance -- snapshot/screenshot/preview write no input and take no focus.
  { key: 'snapshotMaxElements', type: 'number', default: 300, min: 1, max: 5000, volatile: true,
    description: 'Cap on the number of elements one snapshot returns. Measured trees: 71 visible '
      + 'elements for an 816-node Electron window, so 300 is deliberately loose; a lower value trades '
      + 'completeness for a smaller frame when the deciding side is a clean subagent.' },
  { key: 'screenshotMaxWidth', type: 'number', default: 0, min: 0, max: 7680, volatile: true,
    description: 'Downscale screenshots to at most this width. 0 (default) means no scaling and '
      + 'scale=1: a resized image is a different coordinate system, so it is never chosen silently.' },
  { key: 'shotsKeep', type: 'number', default: 10, min: 1, max: 200, volatile: true,
    description: 'How many screenshot PNGs stay in %LOCALAPPDATA%\\wpm\\shots. Older files are deleted '
      + 'after each capture, so the directory cannot grow without bound; a shotId that was cleaned up '
      + 'is refused with stale_ref rather than reinterpreted.' },
  // ---- 0.7.0 desktop actions. `launch` is the one action in this product that can run arbitrary code,
  // so it gets its OWN gate rather than riding on takeoverAllowed, and it gets a whitelist rather than a
  // denylist: a denylist is wrong the first time someone adds a program (spec 0.7.0-A). Both default to
  // "nothing may launch", which means an upgrade cannot start spawning processes on its own, and the
  // whitelist is matched EXACTLY (case-insensitive, no wildcards, no prefixes) because `notepad` matching
  // `notepad-helper.exe` by prefix is the shape of a whitelist that authorises more than it says.
  { key: 'appLaunchAllowed', type: 'boolean', default: false, volatile: true,
    description: 'Allow action=launch at all. Off by default; when off, a launch is refused with '
      + 'app_launch_denied before any worker request is made. This gate is independent of '
      + 'takeoverAllowed: being allowed to move a cursor is not being allowed to start a program.' },
  { key: 'appLaunchAllow', type: 'string[]', default: [], volatile: true,
    description: 'The launch whitelist: exact program names or absolute exe paths, matched '
      + 'case-insensitively and in full. An EMPTY list means nothing may launch even when '
      + 'appLaunchAllowed is on -- the two switches are deliberately not one.' },
  // ---- 0.7.0 authorization model. TWO AXES, deliberately not one enum per action: the action declares
  // the minimum tier it can need (src/schema/tools.json#requiresTier), and this setting says how far the
  // plugin may go. Eleven actions times one knob stays readable; eleven knobs would not.
  { key: 'policy', type: 'string', default: 'balanced', volatile: true,
    description: 'How far an action may go without asking again: readonly (reads only -- snapshot, '
      + 'screenshot, preview, status, windows, clipboard read), quiet (adds click/type/focus through the '
      + 'message door), balanced (default: adds the bounded-flash tier, clipboard writes and window ops), '
      + 'full (adds takeover and launch). Anything above the level is refused with policy_denied, whose '
      + 'next step is to raise this setting -- not to retry. An unrecognizable value falls back to '
      + 'balanced, never to full.' },
  { key: 'policyIdleMs', type: 'number', default: 3000, min: 0, max: 60000, volatile: true,
    description: 'Idle sensing: how recently a PHYSICAL input must have happened for the owner to count '
      + 'as "present". An action that needs the takeover tier while the owner is present is refused with '
      + 'user_active and NO dialog -- a popup that interrupts someone who is typing is not consent, it is '
      + 'a second disturbance. 0 disables the check. Measured input age already travels with status.' },
];

/** Defaults, for documentation and for tests that must not depend on a resolver. */
export const CONFIG_DEFAULTS = Object.fromEntries(FIELDS.map((f) => [f.key, f.default]));

/**
 * Validate one raw config object against FIELDS. Returns `{ value, issues }` standard-schema style.
 *
 * `@returns {any}` on purpose: the two returns below have different shapes (`{issues}` alone vs
 * `{value}` alone), which is exactly what the standard-schema contract allows and what Cordis
 * branches on. A precise union here is a lie about the runtime and was measured to turn two errors
 * into three (findings §7.5).
 * @param {any} raw
 * @returns {any}
 */
function validateWithShim(raw) {
  const input = raw && typeof raw === 'object' ? raw : {};
  /** @type {Record<string, any>} */
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
    } else if (field.type === 'string[]') {
      // An array is validated element-wise, and a non-array is an ISSUE rather than a coercion: the
      // bundle patch is YAML, and `appLaunchAllow: notepad` (a bare string) is the single most likely
      // way someone will write a one-entry whitelist. Accepting it silently would make the setting work
      // today and break the moment a second entry is added as a list.
      if (!Array.isArray(given)) {
        issues.push({ message: 'expected an array of strings', path: [field.key] });
      } else if (given.some((x) => typeof x !== 'string')) {
        issues.push({ message: 'expected every entry to be a string', path: [field.key] });
      } else {
        value[field.key] = given.map((x) => x.trim()).filter((x) => x !== '');
      }
    } else if (field.key === 'policy') {
      // A closed set, checked where the settings are parsed rather than at the decision site: a policy
      // that silently reads as an unknown level is the same class of bug as a level the table does not
      // know how to compare.
      if (!['readonly', 'quiet', 'balanced', 'full'].includes(given)) {
        issues.push({ message: 'expected readonly|quiet|balanced|full', path: [field.key] });
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
    // Static-import bridge (see lib/peers-schemastery.js): a dynamic bare specifier does not
    // resolve for a `link:`-installed package under the host, which is exactly why the desktop
    // profile fell to the shim and rendered no settings form.
    const mod = await import('./peers-schemastery.js');
    const z = mod?.z;
    if (z && typeof z.object === 'function') {
      /** @type {Record<string, any>} */
      const shape = {};
      for (const field of FIELDS) {
        let s;
        if (field.type === 'boolean') s = z.boolean();
        else if (field.type === 'number') s = z.number();
        else if (field.type === 'string[]') s = z.array(z.string());
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
      const schema = typeof z.object(shape).prefault === 'function' ? z.object(shape).prefault({}) : z.object(shape);
      // TWO PROPERTIES THE SHIM ALREADY HAD, restored on the Schemastery path so both paths behave the
      // same way for the caller:
      //   * UNKNOWN KEYS ARE REJECTED, not silently carried through. Schemastery keeps them in the
      //     validated value, which means a typo'd setting reads as accepted while doing nothing -- the
      //     exact failure test/plugin-test.mjs pins, and the reason the shim has this rule;
      //   * '~standard' stays the single validation entry point Cordis calls.
      // The Schemastery INSTANCE itself is kept: it is a callable object and it is what the host uses to
      // render the settings form. Wrapping it in a plain object would trade the form for the check.
      // Schemastery owns '~standard' as a non-writable accessor, so it cannot be replaced in place. The
      // wrapper below is a PROXY over the instance: still callable, still carrying the instance's own
      // fields and methods (which is what the settings form reads), but with one property -- the
      // validation entry point Cordis calls -- replaced by the strict one.
      const std = schema['~standard'];
      let configValue = schema;
      if (std && typeof std.validate === 'function') {
        /** @type {Set<string>} */
        const known = new Set(FIELDS.map((f) => f.key));
        const wrapped = Object.assign(Object.create(null), std, {
          /** @param {any} raw @returns {any} */
          validate(raw) {
            const input = raw && typeof raw === 'object' ? raw : {};
            const unknown = Object.keys(input).filter((k) => !known.has(k));
            if (unknown.length) {
              return { issues: unknown.map((k) => ({ message: 'unknown setting', path: [k] })) };
            }
            return std.validate(raw);
          },
        });
        try {
          configValue = new Proxy(schema, {
            get(target, prop, receiver) {
              if (prop === '~standard') return wrapped;
              const v = Reflect.get(target, prop, receiver);
              return typeof v === 'function' ? v.bind(target) : v;
            },
            apply(target, thisArg, args) { return Reflect.apply(target, thisArg, args); },
          });
        } catch { configValue = schema; }
      }
      return { schema: configValue, source: '@deepseek-ai/schemastery' };
    }
  } catch {
    // Documented fallback, reported through `source`.
  }
  return { schema: shimSchema, source: 'local-standard-schema-shim' };
}
