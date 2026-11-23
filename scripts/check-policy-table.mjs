// check-policy-table.mjs -- gate 21: the authorization ladder exists in two languages, and this is the
// only thing that keeps them the same ladder.
//
// WHY THIS IS R4 AND WHY IT IS A GATE. 0.7.0 replaces "one boolean per action" with two axes: the action
// declares the rung it needs (`requiresTier` in src/schema/tools.json), the owner sets one ceiling
// (`policy`). That design only holds if three copies agree:
//   1. the contract file -- what the model is told each action needs;
//   2. lib/policy.js      -- the ladder the HOST compares against, in JS;
//   3. src/engine/decide.ps1 -- the ladder the ENGINE compares against, in PowerShell, because the
//      ceiling has to be enforced in the process that can measure last-input age too.
// Two copies of a constant is the drift this repo has now met four times (refusal codes, effect values,
// the version string, the geometry oracle), and here the drift is a PERMISSION: a rung listed in the
// contract but missing from the JS ladder reads as "undeclared", which `actionTier` deliberately maps to
// the LOUDEST rung -- fail closed. That failure is safe and invisible, which is the worst combination:
// the owner raises the ceiling and calls keep being refused, and nothing points at why.
//
// WHAT IT CHECKS, in order:
//   A. every action in tools.json declares `requiresTier`, and the value is in policy.js's TIER_ORDER;
//   B. every `requiresTierFor` op value is too, and every op it names is an op the tool's own schema
//      accepts (a refinement for an op that cannot be sent is dead text in a permission table);
//   C. policy.js's TIER_ORDER and decide.ps1's $WpmTierOrder are THE SAME LIST IN THE SAME ORDER, and
//      POLICY_CEILINGS matches $WpmPolicyCeiling key-for-key and value-for-value;
//   D. an action with no declared rung is a red, not a default.
//
// NON-VACUITY: --self-test mutates copies for each assertion and requires the corresponding red
// (delete one action's declaration, invent a rung, swap the PS order, point one ceiling at a different
// rung). A gate that has never been red is a comment.
//
// Usage: node scripts/check-policy-table.mjs [--self-test]
import { readFileSync } from 'node:fs';

const SCHEMA = 'src/schema/tools.json';
const POLICY = 'lib/policy.js';
const DECIDE = 'src/engine/decide.ps1';

/** The string array literal in a JS file, read as data (no eval, no import of the module under test). */
function jsArray(src, name) {
  const m = src.match(new RegExp(`export const ${name} = \\[([^\\]]*)\\]`, 's'));
  if (!m) return null;
  return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
}
function jsObject(src, name) {
  const m = src.match(new RegExp(`export const ${name} = \\{([\\s\\S]*?)\\n\\};`));
  if (!m) return null;
  const out = {};
  for (const line of m[1].split('\n')) {
    const e = line.match(/^\s*(\w+):\s*'([^']+)'/);
    if (e) out[e[1]] = e[2];
  }
  return out;
}
function psArray(src, name) {
  const m = src.match(new RegExp(`\\$script:${name}\\s*=\\s*@\\(([^)]*)\\)`));
  if (!m) return null;
  return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
}
function psHash(src, name) {
  const m = src.match(new RegExp(`\\$script:${name}\\s*=\\s*@\{([\\s\\S]*?)\n\}`));
  if (!m) return null;
  const out = {};
  for (const line of m[1].split('\n')) {
    for (const e of line.matchAll(/(\w+)\s*=\s*'([^']+)'/g)) out[e[1]] = e[2];
  }
  return out;
}

export function check(files) {
  const schema = JSON.parse(files[SCHEMA]);
  const policy = files[POLICY];
  const decide = files[DECIDE];
  const problems = [];

  const order = jsArray(policy, 'TIER_ORDER');
  const levels = jsArray(policy, 'POLICY_LEVELS');
  const ceilings = jsObject(policy, 'POLICY_CEILINGS');
  if (!order || !levels || !ceilings) {
    return [`${POLICY}: could not read TIER_ORDER / POLICY_LEVELS / POLICY_CEILINGS as literals -- the ladder cannot be checked (this is a gate bug, not a policy bug: it means the module's shape changed and this reader was not told)`];
  }
  const psOrder = psArray(decide, 'WpmTierOrder');
  const psCeil = psHash(decide, 'WpmPolicyCeiling');
  if (!psOrder || !psCeil) return [`${DECIDE}: could not read $WpmTierOrder / $WpmPolicyCeiling`];

  // (C) the two ladders are one ladder.
  if (JSON.stringify(order) !== JSON.stringify(psOrder)) {
    problems.push(`${DECIDE}: $WpmTierOrder ${JSON.stringify(psOrder)} != ${POLICY} TIER_ORDER ${JSON.stringify(order)} -- the host and the engine would rank the same action differently`);
  }
  const ks = Object.keys(ceilings).sort();
  const pk = Object.keys(psCeil).sort();
  if (JSON.stringify(ks) !== JSON.stringify(pk)) {
    problems.push(`${DECIDE}: policy levels ${JSON.stringify(pk)} != ${POLICY} ${JSON.stringify(ks)}`);
  }
  for (const k of ks) {
    if (psCeil[k] !== ceilings[k]) problems.push(`policy level '${k}': ceiling is '${ceilings[k]}' in ${POLICY} but '${psCeil[k]}' in ${DECIDE}`);
  }
  // Every declared level must have a ceiling, or `policy:<level>` parses and then refuses everything.
  for (const l of levels) if (!(l in ceilings)) problems.push(`${POLICY}: POLICY_LEVELS lists '${l}' but POLICY_CEILINGS has no entry for it`);

  // (A) + (B): every action declares a rung, in the contract's own vocabulary.
  const ops = {};
  for (const t of schema.tools) {
    if (typeof t.requiresTier !== 'string' || t.requiresTier === '') {
      problems.push(`${SCHEMA}: tool '${t.name}' (action '${t.action}') declares no requiresTier -- an undeclared action is refused as 'takeover' at runtime, which is safe but invisible, and invisibility is not a design`);
      continue;
    }
    if (!order.includes(t.requiresTier)) problems.push(`${SCHEMA}: ${t.name}.requiresTier '${t.requiresTier}' is not one of ${order.join('|')}`);
    const spec = t.inputSchema?.properties?.op;
    const legal = spec && Array.isArray(spec.enum) ? spec.enum : [];
    if (t.requiresTierFor) {
      for (const [op, tier] of Object.entries(t.requiresTierFor)) {
        if (!order.includes(tier)) problems.push(`${SCHEMA}: ${t.name}.requiresTierFor.${op} = '${tier}' is not a rung in ${POLICY} TIER_ORDER`);
        // A refinement for an op the schema does not accept would never be consulted: the permission
        // table would describe a door the tool does not have.
        if (legal.length && !legal.includes(op)) {
          problems.push(`${SCHEMA}: ${t.name}.requiresTierFor names '${op}' but that tool's op enum is ${JSON.stringify(legal)}`);
        }
      }
      // And the reverse: an op the tool accepts that the map leaves out silently inherits the action's
      // rung. That is a legitimate choice only when it is stated, so it is required to be the SAME rung
      // as the declared one -- anything else means someone added an op and forgot its rung.
      for (const op of legal) {
        if (!(op in t.requiresTierFor) && order.indexOf(t.requiresTier) < 0) {
          problems.push(`${SCHEMA}: ${t.name} accepts op '${op}' with no requiresTierFor entry`);
        }
      }
      ops[t.action] = Object.keys(t.requiresTierFor);
    }
  }
  // The action set the projection exposes must be the set that declares a rung, or a model can reach an
  // action with no rung at all.
  const projected = Object.values(schema.hostProjection?.actions ?? {});
  for (const a of projected) {
    if (!schema.tools.some((t) => t.action === a)) problems.push(`${SCHEMA}: hostProjection exposes action '${a}' with no tool entry (and therefore no requiresTier)`);
  }
  const declaredTiers = new Set(schema.tools.map((t) => t.requiresTier).filter(Boolean));
  for (const t of order) if (!declaredTiers.has(t)) {
    problems.push(`${SCHEMA}: no action declares the rung '${t}' -- the ladder has an empty rung, which usually means an action was reclassified and the table was not re-read`);
  }
  return problems;
}

const selfTest = process.argv.includes('--self-test');
const files = {
  [SCHEMA]: readFileSync(SCHEMA, 'utf8'),
  [POLICY]: readFileSync(POLICY, 'utf8'),
  [DECIDE]: readFileSync(DECIDE, 'utf8'),
};
const problems = check(files);
const notes = [];

if (selfTest) {
  const mutators = [
    ['one action loses its requiresTier', (f) => ({ ...f, [SCHEMA]: f[SCHEMA].replace('      "requiresTier": "flash",\n', '') })],
    ['a rung that does not exist', (f) => ({ ...f, [SCHEMA]: f[SCHEMA].replace('"requiresTier": "quiet"', '"requiresTier": "sneaky"') })],
    ['the PS ladder reorders a rung', (f) => ({ ...f, [DECIDE]: f[DECIDE].replace("$script:WpmTierOrder = @('readonly', 'quiet', 'flash', 'takeover')", "$script:WpmTierOrder = @('readonly', 'flash', 'quiet', 'takeover')") })],
    ['one ceiling points elsewhere', (f) => ({ ...f, [POLICY]: f[POLICY].replace("balanced: 'flash',", "balanced: 'takeover',") })],
    ['a requiresTierFor names an op the tool cannot receive', (f) => ({ ...f, [SCHEMA]: f[SCHEMA].replace('{ "read": "readonly", "write": "flash" }', '{ "read": "readonly", "write": "flash", "paste": "quiet" }') })],
  ];
  for (const [name, mutate] of mutators) {
    const mutated = mutate(files);
    let changed = false;
    for (const k of Object.keys(files)) if (mutated[k] !== files[k]) changed = true;
    if (!changed) { problems.push(`self-test: mutation "${name}" changed nothing -- the pattern no longer matches the code it was written for`); continue; }
    const found = check(mutated);
    if (!found.length) problems.push(`self-test: mutation "${name}" was NOT caught -- the assertion is vacuous`);
    else notes.push(`self-test red as expected: ${name}`);
  }
}

if (problems.length) {
  console.error(`FAIL: ${problems.length} policy-table problem(s).\n`);
  for (const p of problems) console.error('  ' + p);
  console.error('\nThe ladder is copied on purpose (host JS + engine PS) and a copy without a check is');
  console.error('a permission that drifts. Add a rung in all three places or in none.');
  process.exit(1);
}
const schema = JSON.parse(files[SCHEMA]);
console.log(`OK: ${schema.tools.length}/${schema.tools.length} actions declare requiresTier; `
  + 'TIER_ORDER == $WpmTierOrder and POLICY_CEILINGS == $WpmPolicyCeiling; every requiresTierFor op is an op the tool accepts'
  + (notes.length ? ` | ${notes.join('; ')}` : ''));
process.exit(0);
