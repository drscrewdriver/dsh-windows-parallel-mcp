// proof-window.mjs — the ONE implementation of "did the action disturb the owner".
//
// WHY THIS EXISTS AS A PURE MODULE. The product's central claim is that driving a window never
// moves the user's cursor and never keeps their foreground. That claim is only worth anything if it
// is MEASURED per call, not asserted in a README. The measurement is a window of samples
//   { ts, cx, cy, fg, focus, inputAgeMs }
// taken around the action, and the judgment is arithmetic on that window. All of it is pure: no
// file, no process, no syscall. So it can be unit-tested against SYNTHETIC samples where the right
// answer is known by construction -- which is exactly what a claim this load-bearing needs.
//
// THE ATTRIBUTION RULE (why the raw cursor delta cannot be the test). GetLastInputInfo returns "ms
// since the last PHYSICAL input". Between two samples, if that implied event timestamp MOVED, a
// human touched the mouse or keyboard inside the gap -- and any motion there belongs to the human.
// Motion in a gap with no physical event is UNEXPLAINED. So far, so standard.
//
// WHAT THE REAL DESKTOP RUNS AND AN IDLE BASELINE TAUGHT US. Unexplained does NOT mean "ours".
// Real clean clicks measured isolated 3.16px and 7.07px cursor jumps while nobody touched anything --
// another process nudging the cursor is routine. Against a hardcoded 1px that was a FALSE RED (the
// gate-cries-wolf failure this repo's doctrine names); against a "generous" threshold it is laundering.
// The decisive measurement was an IDLE BASELINE (scripts/idle-baseline.mjs (re-runnable)): with NOTHING of ours running,
// over windows the same length as an action, the cursor already showed unexplained motion across up to
// 3 separate gaps at ~11px (four idle windows: 0, 3, 0, 0 gaps). So even SUSTAINED multi-gap motion
// cannot be blamed on our action from a coordinate stream -- GetLastInputInfo excludes the HUMAN and
// nothing in a position delta excludes ANOTHER PROCESS. ">=2 gaps => fail" is therefore a wolf-cry the
// idle baseline disproves. The cursor dimension reports:
//   0 unexplained motion gaps => pass   (direct evidence: nothing moved while we acted)
//   >=1 unexplained gap       => inconclusive (something moved; the build-time gate says it was not
//                              our code, so we surface the number and resolve nothing by blame)
// THE CURSOR GUARANTEE LIVES WHERE IT IS DECIDABLE: scripts/check-no-cursor-control.mjs asserts the
// shipped engine contains no SetCursorPos / SendInput / mouse_event / keybd_event -- a byte-level,
// zero-false-positive build gate. A regression that ADDS cursor control is caught at build time with
// certainty, strictly stronger than sampling at runtime on a desktop that moves on its own. Same
// architecture as the schema DROPPING the `physical` field rather than detecting a disabled one:
// enforce by structure, measure only what structure cannot settle.
//
// FOREGROUND/FOCUS keep a fail verdict because they are different: the product CAN legitimately touch
// them (the UIA flash tier raises, then restores OUTSIDE the sample window; a regression could keep
// it), and an ambient focus steal is rarer than cursor jitter -- the control window characterises it.
// A switch is failed only when the control shows the desktop was NOT already switching seconds before;
// a desktop that steals during the control makes it inconclusive instead of a false red.
//
// Verdict ordering: fail > inconclusive > pass. A dimension that cannot be judged is reported, not
// assumed innocent: silence has never been evidence here.
//
// sampler.mjs and the engine both feed samples here. Two copies of this math would mean the
// reachability numbers and the per-action proof were measured by different instruments while
// carrying the same name -- the drift this repo already killed once (see sampler.mjs header).

const round = (v) => Math.round(v * 100) / 100;

/** Absolute timestamp of the last PHYSICAL input at sample x, or null if unreadable. */
export function physEventAt(x) {
  return typeof x.inputAgeMs === 'number' && x.inputAgeMs >= 0 ? x.ts - x.inputAgeMs : null;
}

/** Was there physical input inside the gap between b and a? Unreadable age => NOT human (fail closed). */
export function isHumanGap(b, a, humanGapFactor = 0.6) {
  const ea = physEventAt(b), eb = physEventAt(a);
  if (ea === null || eb === null) return false;
  return eb > ea + Math.max(2, (a.ts - b.ts) * humanGapFactor);
}

/**
 * Evaluate one proof window. Pure.
 * @param {Array} samples the ACTION window
 * @param {{minSamples?:number, humanGapFactor?:number, control?:Array, declaredFlash?:boolean,
 *          effect?:string, actions?:Array}} [opts]
 *   control = the pre-action window (sampled while nothing was done). It cannot excuse motion in the
 *   action window -- the structural rule already handles that -- but it decides whether the
 *   foreground/focus dimensions are evaluable at all.
 *   effect  = the engine's own word on who reported success ('unverified' | 'reported-by-send' |
 *   'reported-by-pattern'). Omitted => no effect dimension, so every pre-existing caller keeps its
 *   old behaviour byte for byte.
 *   actions = optional per-attempt results ({ ok, effect }); when EVERY attempt failed to take
 *   effect the verdict is fail regardless of how still the desktop stayed.
 */
export function evaluateProof(samples, opts = {}) {
  const minSamples = opts.minSamples ?? 3;
  const humanGap = opts.humanGapFactor ?? 0.6;

  const r = (Array.isArray(samples) ? samples : [])
    .map((x) => (x && typeof x.ts === 'number' ? x : null))
    .filter(Boolean);

  if (r.length < minSamples) {
    return {
      samples: r.length, windowMs: 0,
      cursorMaxDeltaPx: null, cursorMaxDeltaAt: null, cursorTotalPathPx: null,
      foregroundSwitches: null, focusChanges: null, attribution: null, control: null,
      verdict: 'insufficient', reason: `proof needs >=${minSamples} samples, got ${r.length}`,
    };
  }

  let maxD = 0, maxAt = r[0].ts, total = 0;
  let fg = 0, fc = 0, unexplained = 0, unexplainedMax = 0, unexplainedMaxAt = 0;
  let motionGaps = 0;
  let physEvents = 0, humanMs = 0, quietMs = 0, unexplainedFg = 0, unexplainedFc = 0;
  let physUnreadable = 0;

  for (let i = 1; i < r.length; i++) {
    const a = r[i], b = r[i - 1];
    const gap = a.ts - b.ts;
    const ea = physEventAt(b), eb = physEventAt(a);
    let human = false;
    if (ea === null || eb === null) physUnreadable++;
    else human = eb > ea + Math.max(2, gap * humanGap);

    if (human) { physEvents++; humanMs += gap; } else quietMs += gap;

    const d = Math.hypot(a.cx - b.cx, a.cy - b.cy);
    if (d > maxD) { maxD = d; maxAt = a.ts; }
    total += d;
    if (!human && d > 0.5) {
      motionGaps += 1;
      unexplained += d;
      if (d > unexplainedMax) { unexplainedMax = d; unexplainedMaxAt = a.ts; }
    }

    // A gap with NO physical input in it is the only one where a switch could be OURS: if a human
    // touched something in the gap, the desktop changed hands for reasons that have nothing to do
    // with the door call, and counting that against the action is a false red (a click cannot fail
    // because the user alt-tabbed during the settle sleep).
    if (a.fg !== b.fg) { fg++; if (!human) unexplainedFg++; }
    if (a.focus !== b.focus) { fc++; if (!human) unexplainedFc++; }
  }

  const attribution = {
    physicalInputEvents: physEvents,
    humanActiveMs: round(humanMs),
    quietMs: round(quietMs),
    unexplainedCursorMotionGaps: motionGaps,
    unexplainedCursorMaxDeltaPx: round(unexplainedMax),
    unexplainedCursorMaxDeltaAt: unexplainedMaxAt,
    unexplainedCursorPathPx: round(unexplained),
    unexplainedForegroundSwitches: unexplainedFg,
    unexplainedFocusChanges: unexplainedFc,
    unreadableInputAgeGaps: physUnreadable,
  };

  let control = null;
  if (Array.isArray(opts.control) && opts.control.length >= minSamples) {
    const c = evaluateProof(opts.control, { minSamples });
    if (c.attribution) control = c.attribution;
  }

  const v = verdictFor(attribution, control, r.length, {
    declaredFlash: opts.declaredFlash === true,
    effect: opts.effect,
    actions: opts.actions,
  });
  return {
    samples: r.length,
    windowMs: r[r.length - 1].ts - r[0].ts,
    cursorMaxDeltaPx: round(maxD),
    cursorMaxDeltaAt: maxAt,
    cursorTotalPathPx: round(total),
    foregroundSwitches: fg,
    focusChanges: fc,
    attribution,
    control,
    verdict: v.verdict,
    reason: v.reason,
    dimensions: v.dimensions,
  };
}

/**
 * The judgment, from the action window's attribution and (optionally) the control window's.
 *   cursor : 0 unexplained motion gaps => pass  (nothing moved during the action -- direct evidence)
 *            >=1                      => inconclusive (the IDLE BASELINE measured up to 3 gaps / 11px
 *                                          with nothing of ours running, so motion -- even multi-gap
 *                                          -- cannot be blamed on the action from position data. The
 *                                          number is surfaced. The real guarantee is the build-time
 *                                          check-no-cursor-control gate, not this sensor.)
 *   fg/focus: 0 unexplained switches  => pass
 *             action >0, control also  => inconclusive (the desktop was switching on its own seconds
 *                                          before; this switch cannot be pinned on us)
 *             action >0, control clean => fail  (the desktop was demonstrably not doing this; a
 *                                          FOREGROUND/FOCUS steal is not ambient the way a cursor
 *                                          nudge is -- and unlike the cursor, the product's touch on
 *                                          focus is DECLARED, see declaredFlash below)
 *            declaredFlash:true        => a foreground switch is EXPECTED for the bounded-flash tier
 *                                          (the engine raises, then restores after the sample window;
 *                                          "we never touch your foreground" was never the promise for
 *                                          that tier -- "we never KEEP it" is, and the restore table
 *                                          owns it, surfacing restore_failed separately). Reported,
 *                                          not failed.
 *   unreadable instrument on most gaps => inconclusive (silence is not innocence)
 *   effect   : absent                => the dimension does not exist (every pre-0.1.3 caller unchanged)
 *              reported-by-send        => pass, and the reason says 未独立验证: a channel reported that
 *              reported-by-pattern        the call RETURNED; nobody observed the application react
 *              unverified / unknown    => inconclusive (no channel reported anything, so a still
 *                                         cursor cannot be read as "the action landed")
 *   actions  : every attempt failed  => fail (动作未生效), however still the desktop stayed. This is
 *              the case the pre-0.1.3 gate could read as a green light: 50 failed calls, zero
 *              displacement. Displacement proves we did not disturb; it never proves we accomplished.
 * Overall = worst dimension: fail > inconclusive > pass.
 */
function judgeEffect(effect, actions) {
  const list = Array.isArray(actions) ? actions.filter(Boolean) : [];
  const reported = (a) => a.ok !== false
    && (a.effect === 'reported-by-send' || a.effect === 'reported-by-pattern');

  // Every attempt failed to take effect => fail, whatever the samples say. A displacement-free window
  // is the ABSENCE of disturbance, not the PRESENCE of accomplishment; letting it outvote a total
  // no-op is exactly the self-deception this dimension exists to stop.
  if (list.length > 0 && !list.some(reported)) {
    return {
      dim: 'fail',
      note: `动作未生效 (none of ${list.length} action attempt(s) took effect: no channel ever reported success, so the clean window below proves only that we did nothing loudly)`,
    };
  }
  // No effect supplied at all => no dimension. This keeps the module's old contract for every caller
  // that predates it (the 32 pre-existing arms must not move).
  if (effect === undefined || effect === null || effect === '') return null;
  if (effect === 'reported-by-send' || effect === 'reported-by-pattern') {
    return {
      dim: 'pass',
      note: `effect=${effect}: a channel reported the call returned -- 未独立验证 (not independently verified: the application's own handling was never observed)`,
    };
  }
  // 'unverified', and anything this module does not know, cannot be laundered into a pass.
  return {
    dim: 'inconclusive',
    note: `effect='${effect}': no channel reported success, so the clean window below cannot be read as the action having landed`,
  };
}

export function verdictFor(attribution, control, sampleCount, opts = {}) {
  const a = attribution || {};
  const unreadableCap = opts.unreadableCap ?? Math.max(1, Math.floor((sampleCount - 1) * 0.3));
  const dims = {};

  if ((a.unreadableInputAgeGaps ?? 0) > unreadableCap) {
    return {
      verdict: 'inconclusive',
      reason: `input-age unreadable for ${a.unreadableInputAgeGaps} gaps; cannot attribute anything`,
      dimensions: { cursor: 'unreadable', foreground: 'unreadable', focus: 'unreadable' },
    };
  }

  const gaps = a.unexplainedCursorMotionGaps ?? 0;
  const ux = a.unexplainedCursorMaxDeltaPx ?? 0;
  // No 'fail' on the cursor dimension: see the header. The idle baseline proved the desktop itself
  // produces multi-gap unexplained motion, so blaming it on the action is a false red by construction.
  dims.cursor = gaps === 0 ? 'pass' : 'inconclusive';

  const cFg = control ? (control.unexplainedForegroundSwitches ?? 0) : 0;
  const cFc = control ? (control.unexplainedFocusChanges ?? 0) : 0;
  const aFg = a.unexplainedForegroundSwitches ?? 0;
  const aFc = a.unexplainedFocusChanges ?? 0;
  if (aFg === 0) dims.foreground = 'pass';
  else if (opts.declaredFlash) dims.foreground = 'declared';
  else dims.foreground = control && cFg > 0 ? 'inconclusive' : 'fail';
  if (aFc === 0) dims.focus = 'pass';
  else dims.focus = control && cFc > 0 ? 'inconclusive' : 'fail';

  const parts = [];
  if (dims.cursor === 'inconclusive') parts.push(`cursor moved ${ux}px in ${gaps} gap(s) with no physical input -- not attributable to the action (the desktop itself does this: idle baseline measured up to 3 gaps/11px with nothing running); the cursor promise is enforced at build time by check-no-cursor-control`);
  if (dims.foreground === 'declared') parts.push(`foreground switched, but this tier DECLARED a bounded flash (raise then restore) -- the promise is never to KEEP the foreground, owned by the restore table`);
  if (dims.foreground === 'fail') parts.push(`${aFg} unexplained foreground switch(es) while the control showed the desktop was not switching and this tier did not declare a flash -- ours to explain`);
  if (dims.foreground === 'inconclusive') parts.push(`${aFg} foreground switch(es), but the desktop was switching on its own during the control too -- unattributable`);
  if (dims.focus === 'fail') parts.push(`${aFc} unexplained focus change(s) with a clean control`);
  if (dims.focus === 'inconclusive') parts.push(`${aFc} focus change(s) mirroring the desktop's own behaviour during the control`);

  const eff = judgeEffect(opts.effect, opts.actions);
  if (eff) { dims.effect = eff.dim; parts.push(eff.note); }

  const values = Object.values(dims);
  // 'declared' is informational, never the worst value: it cannot drag the verdict down on its own.
  const verdict = values.includes('fail') ? 'fail' : values.includes('inconclusive') ? 'inconclusive' : 'pass';
  // A 'pass' verdict must never print a reason that contradicts the dimensions. The bounded-flash
  // case passes WITH foreground switches (authorized by the tier's contract); claiming "no switches"
  // would be the README-in-a-tool-result failure mode this whole module exists to prevent.
  const reason = parts.length
    ? parts.join('; ')
    : `no unexplained cursor motion in ${sampleCount - 1} gaps, no unexplained foreground/focus switches`;
  return { verdict, reason, dimensions: dims };
}

/** The software-attributable quantities, flattened for callers that only want the numbers. */
export function softwareCursorEvidence(summary) {
  const a = (summary && summary.attribution) || {};
  return {
    motionGaps: a.unexplainedCursorMotionGaps ?? null,
    maxPx: a.unexplainedCursorMaxDeltaPx ?? null,
    pathPx: a.unexplainedCursorPathPx ?? null,
    foregroundSwitches: a.unexplainedForegroundSwitches ?? null,
    focusChanges: a.unexplainedFocusChanges ?? null,
    quietMs: a.quietMs ?? null,
  };
}
