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
// WHAT THE THREE REAL DESKTOP RUNS TAUGHT US, AND WHAT CHANGED. Unexplained does NOT mean "ours".
// The product has no code path that can move the physical cursor at all -- by policy there is no
// SendInput / mouse_event / SetCursorPos anywhere (README "no synthetic input"; grep-verified at
// the time this comment was written). Yet real clean clicks measured isolated 3.16px and 7.07px
// cursor jumps in a single sample gap while nobody touched anything: another process nudging the
// cursor position is routine on a live desktop. Against a hardcoded 1px that was a FALSE RED -- the
// gate-cries-wolf failure this repo's doctrine explicitly names -- and against a "generous"
// threshold it would be laundering. Both are wrong; the verdict had to learn to tell the desktop's
// noise from a regression, and that is structural, not numerical:
//
//   * A REGRESSION that moves the cursor does so ACROSS GAPS -- a drag, a sweep, code driving the
//     cursor in a loop. Two or more separate motion gaps inside the action window is the structural
//     signature, and the gate fails on it whatever the control shows.
//   * AN AMBIENT NUDGE is a single isolated jump between two samples, then still. One motion gap.
//     Position data alone cannot attribute it -- not to the human (the input age says not them), and
//     not to us either: we cannot prove a UIA pattern did not make the TARGET app reposition a caret,
//     and we cannot prove some other process did not warp it, from a coordinate delta. So it is
//     INCONCLUSIVE with the number surfaced. This is a GATE-DESIGN choice (isolated jumps on a live
//     desktop are common enough that calling them fail is a wolf-cry -- observed 3.16px and 7.07px on
//     clean clicks within three runs), NOT a claim that the product is physically incapable of a warp.
//   * ZERO unexplained motion gaps in the action window is a PASS -- direct evidence: nothing moved
//     while the action ran, whatever the desktop did earlier or elsewhere.
//
// FOREGROUND/FOCUS are judged differently because the product CAN legitimately touch them (the
// UIA flash tier raises, then restores outside the sample window; a regression could keep it). If
// the control window saw no unexplained switches there, an unexplained switch in the action window
// is genuinely ours to answer -- fail. If the desktop was stealing focus on its own during the
// control, the same switch in the action window is unattributable -- inconclusive.
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
 * @param {{minSamples?:number, humanGapFactor?:number, control?:Array}} [opts]
 *   control = the pre-action window (sampled while nothing was done). It cannot excuse motion in the
 *   action window -- the structural rule already handles that -- but it decides whether the
 *   foreground/focus dimensions are evaluable at all.
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

  const v = verdictFor(attribution, control, r.length);
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
 *   cursor  : 0 motion gaps            => pass  (nothing moved during the action -- direct evidence)
 *             1 motion gap             => inconclusive (an isolated jump is unattributable on a live
 *                                          desktop: not human per the input age, and the product has
 *                                          no cursor-moving code to blame; a single warp by ANY
 *                                          process looks identical. The number is surfaced, never
 *                                          laundered into a pass.)
 *             >=2 motion gaps          => fail  (STRUCTURED motion -- a drag/sweep/servo. Whatever
 *                                          wrote it was driving the cursor over time; ambient
 *                                          position corrections do not do that.)
 *   fg/focus: 0 unexplained switches   => pass
 *             action >0, control clean => fail  (the desktop was demonstrably not doing this seconds
 *                                          before; the switch during our action is ours to explain)
 *             action >0, control also  => inconclusive (the desktop steals on its own right now;
 *                                          this switch cannot be pinned on us)
 *   unreadable instrument on most gaps => inconclusive (silence is not innocence)
 * Overall = worst dimension: fail > inconclusive > pass.
 */
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
  if (gaps === 0) dims.cursor = 'pass';
  else if (gaps === 1) dims.cursor = 'inconclusive';
  else dims.cursor = 'fail';

  const cFg = control ? (control.unexplainedForegroundSwitches ?? 0) : 0;
  const cFc = control ? (control.unexplainedFocusChanges ?? 0) : 0;
  const aFg = a.unexplainedForegroundSwitches ?? 0;
  const aFc = a.unexplainedFocusChanges ?? 0;
  if (aFg === 0) dims.foreground = 'pass';
  else dims.foreground = control && cFg > 0 ? 'inconclusive' : 'fail';
  if (aFc === 0) dims.focus = 'pass';
  else dims.focus = control && cFc > 0 ? 'inconclusive' : 'fail';

  const parts = [];
  if (dims.cursor === 'fail') parts.push(`cursor moved unexplained across ${gaps} separate gaps (max ${ux}px) -- sustained multi-gap motion is the signature of cursor driving, and no single ambient correction produces that`);
  if (dims.cursor === 'inconclusive') parts.push(`isolated ${ux}px cursor jump with no physical input in the gap -- a single position delta cannot be attributed to any specific cause (us or another process), so it is reported, not passed and not blamed`);
  if (dims.foreground === 'fail') parts.push(`${aFg} unexplained foreground switch(es) while the control showed the desktop was not switching -- ours to explain`);
  if (dims.foreground === 'inconclusive') parts.push(`${aFg} foreground switch(es), but the desktop was switching on its own during the control too -- unattributable`);
  if (dims.focus === 'fail') parts.push(`${aFc} unexplained focus change(s) with a clean control`);
  if (dims.focus === 'inconclusive') parts.push(`${aFc} focus change(s) mirroring the desktop's own behaviour during the control`);

  const values = Object.values(dims);
  const verdict = values.includes('fail') ? 'fail' : values.includes('inconclusive') ? 'inconclusive' : 'pass';
  const reason = verdict === 'pass'
    ? `no unexplained cursor motion in ${sampleCount - 1} gaps, no unexplained foreground/focus switches`
    : parts.join('; ');
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
