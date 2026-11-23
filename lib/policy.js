// policy.js -- the authorization ladder, as one pure module.
//
// WHY TWO AXES AND NOT ELEVEN SWITCHES. Every action declares the LOWEST rung it can ever need
// (`requiresTier` in src/schema/tools.json); the owner sets ONE ceiling (`policy`). A caller asking for
// more than the ceiling is refused with `policy_denied` whose next step is named: raise the setting, do
// not retry. The alternative -- a boolean per action -- would need eleven settings for eleven actions and
// a twelfth the moment a capability is added, and the pair that actually drifts is the setting nobody
// reads and the action nobody thought about.
//
// THE RUNGS ARE ABOUT DISTURBANCE, NOT ABOUT RISK CATEGORY:
//   readonly   touches nothing: reads a window list, a tree, a screen, a clipboard VALUE;
//   quiet      writes into one named window through its message door -- zero foreground change, measured;
//   flash      the same write when only UI Automation can reach it: one bounded flash that reverses itself;
//   takeover   the real cursor moves and the focus is held until the action ends, HUD mandatory.
// `launch` sits at takeover because it is the one action whose consequences outlive the call; it ALSO
// needs its own gate (appLaunchAllowed) and its own whitelist, which no tier ordering can express.
//
// NO IO, NO STATE, NO CLOCK. Every function here is answerable from its arguments, which is what makes
// the table testable without a desktop and what keeps a policy decision from depending on when it was
// asked. Drift between this set and tools.json is a gate (scripts/check-policy-table.mjs), not a comment.

/** The four rungs, lowest first. Order is the semantics: `tierAtLeast` compares positions here. */
export const TIER_ORDER = ['readonly', 'quiet', 'flash', 'takeover'];

/** The four settings levels, lowest first, each naming the highest rung it permits. */
export const POLICY_LEVELS = ['readonly', 'quiet', 'balanced', 'full'];

/**
 * Which rung each `policy` level allows at most. `balanced` is the default and stops at `flash`: the
 * quiet door and the self-reversing UIA path are permitted, the takeover tier and `launch` are not.
 * @type {Record<string, string>}
 */
export const POLICY_CEILINGS = {
  readonly: 'readonly',
  quiet: 'quiet',
  balanced: 'flash',
  full: 'takeover',
};

/**
 * Is `required` at or below what `policy` permits?
 *
 * An unknown `policy` or unknown `required` answers FALSE. That is the whole safety argument of this
 * function: a typo in a bundle patch, a tier someone added to tools.json without adding it here, or a
 * caller that invents a level must all fall on the refusing side, because "unparseable setting" and
 * "everything allowed" reading the same way is how a permission system becomes decoration.
 * @param {string} policy @param {string} required @returns {boolean}
 */
export function tierAtLeast(policy, required) {
  const ceiling = POLICY_CEILINGS[policy];
  if (!ceiling) return false;
  const need = TIER_ORDER.indexOf(required);
  if (need < 0) return false;
  return need <= TIER_ORDER.indexOf(ceiling);
}

/**
 * The rung a (action, requestedTier) pair needs. When the caller explicitly asks for the takeover tier
 * that outranks the action's declared minimum, because asking for the cursor to move IS the higher
 * request; otherwise the declared rung decides.
 * @param {string} required the action's declared `requiresTier`
 * @param {boolean} takeoverRequested
 * @param {boolean} keyInjectRequested
 * @returns {string}
 */
export function effectiveTier(required, takeoverRequested = false, keyInjectRequested = false) {
  if (takeoverRequested || keyInjectRequested) return 'takeover';
  return TIER_ORDER.includes(required) ? required : 'takeover';
}

/**
 * The action's declared rung, or `takeover` for an action nobody declared -- an undeclared action is
 * treated as the loudest one until a human says otherwise. Silence about a capability must not read as
 * permission for it.
 *
 * `op` consults `requiresTierFor` for the one action whose halves live on different rungs: reading the
 * clipboard touches nothing, writing it replaces something the owner put there, and a single rung for
 * both would have to be either too loose or too tight. An op that the table does not refine falls back
 * to the action's rung -- it never falls back to "allowed".
 * @param {Record<string, any>} table action -> requiresTier (and optionally requiresTierFor)
 * @param {string} action @param {string} [op] @returns {string}
 */
export function actionTier(table, action, op) {
  const entry = table ? table[action] : undefined;
  if (entry && typeof entry === 'object') {
    const perOp = op && entry.requiresTierFor ? entry.requiresTierFor[op] : undefined;
    if (typeof perOp === 'string') return TIER_ORDER.includes(perOp) ? perOp : 'takeover';
    return TIER_ORDER.includes(entry.requiresTier) ? entry.requiresTier : 'takeover';
  }
  if (typeof entry === 'string') return TIER_ORDER.includes(entry) ? entry : 'takeover';
  return 'takeover';
}

/**
 * The tier table as `lib/index.js` and the gate both want it: one object per action, carrying the
 * declared rung and, where the action has halves, the per-op refinement. Reading it through THIS
 * function is the single place the shape is understood; the contract file stays the source of truth.
 * @param {Array<{action:string, requiresTier?:string, requiresTierFor?:Record<string,string>}>} tools
 * @returns {Record<string, {requiresTier: string, requiresTierFor: Record<string,string>}>}
 */
export function tierTable(tools) {
  /** @type {Record<string, {requiresTier: string, requiresTierFor: Record<string,string>}>} */
  const out = {};
  for (const t of tools ?? []) {
    if (!t || typeof t.action !== 'string') continue;
    out[t.action] = {
      requiresTier: typeof t.requiresTier === 'string' ? t.requiresTier : '',
      requiresTierFor: (t.requiresTierFor && typeof t.requiresTierFor === 'object') ? t.requiresTierFor : {},
    };
  }
  return out;
}
/**
 * Should this action be refused for being above the ceiling? Returns the decision so the caller
 * cannot accidentally invert the boolean: `denied` is the refusal, and the two facts a reader
 * needs (what the action needed, what the policy allows) come back already formatted.
 * @param {{policy: string, table: Record<string,any>, action: string, op?: string, takeoverRequested?: boolean, keyInjectRequested?: boolean}} q
 * @returns {{denied: boolean, required: string, ceiling: string}}
 */
export function policyDecision(q) {
  const required = effectiveTier(actionTier(q.table, q.action, q.op), q.takeoverRequested, q.keyInjectRequested);
  return {
    denied: !tierAtLeast(q.policy, required),
    required,
    ceiling: POLICY_CEILINGS[q.policy] ?? '(unknown policy)',
  };
}
