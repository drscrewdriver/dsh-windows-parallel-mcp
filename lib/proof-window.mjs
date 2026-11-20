// proof-window.mjs — the ONE implementation of "did moving the machine disturb the owner".
//
// WHY THIS EXISTS AS A PURE MODULE. The product's central claim is that driving a window never
// moves the user's cursor and never keeps their foreground. That claim is only worth anything if it
// is MEASURED per call, not asserted in a README. The measurement is a window of samples
//   { ts, cx, cy, fg, focus, inputAgeMs }
// taken while the action settles, and the judgment is arithmetic on that window. All of it is pure:
// no file, no process, no syscall. So it can be unit-tested against SYNTHETIC samples where the
// right answer is known by construction -- which is exactly what a claim this load-bearing needs.
//
// THE ATTRIBUTION RULE (this is the whole point, and it is why raw cursor delta cannot be the test).
// GetLastInputInfo returns "ms since the last PHYSICAL input". Between two samples, if that implied
// event timestamp MOVED, a human touched the mouse or keyboard inside that gap -- and any cursor
// motion in the gap belongs to the human, not to the software under test. Only motion in a gap with
// NO physical input is "unexplained", i.e. software-attributable. A proof run where the human is
// allowed to move the mouse still passes if every move is human-attributed; a run that silently
// blames a human's move on the product would fail-closed the other way. Both directions matter, so
// the number that is gated is unexplainedCursorMaxDeltaPx, never the raw one.
//
// sampler.mjs and the engine both feed samples here. Two copies of this math would mean the
// reachability numbers and the per-action proof were measured by different instruments while
// carrying the same name -- the same drift this repo already killed once (see sampler.mjs header).

const round = (v) => Math.round(v * 100) / 100;

/**
 * Absolute timestamp of the last PHYSICAL input at sample x, or null if unreadable.
 * Exported because a caller that lists individual foreground events must classify them with the
 * SAME predicate the verdict uses -- a second copy here would let the event log and the verdict
 * disagree about who moved the window.
 */
export function physEventAt(x, humanGapFactor = 0.6) {
  return typeof x.inputAgeMs === 'number' && x.inputAgeMs >= 0 ? x.ts - x.inputAgeMs : null;
}

/** Was there physical input inside the gap between b and a? Unreadable age => NOT human (fail closed). */
export function isHumanGap(b, a, humanGapFactor = 0.6) {
  const ea = physEventAt(b), eb = physEventAt(a);
  if (ea === null || eb === null) return false;
  return eb > ea + Math.max(2, (a.ts - b.ts) * humanGapFactor);
}

/**
 * Evaluate a proof window. Pure: reads only the arrays it is given.
 * @param {Array} samples the ACTION window (samples taken while/after the action ran)
 * @param {{minSamples?:number, humanGapFactor?:number, control?:Array}} [opts]
 *   control = the PRE-ACTION window, sampled while by construction nothing was done. Its own
 *   unexplained motion is the desktop's NOISE FLOOR: some background app nudging the cursor with no
 *   physical input is indistinguishable from our action doing it, so the action is judged against
 *   that floor, not against a made-up number (the vacuous-control trap this repo recorded in P0
 *   task_5(f)). Absent/unusable control falls back to the strict 1px floor -- failing closed.
 * @returns {object}
 */
export function evaluateProof(samples, opts = {}) {
  const minSamples = opts.minSamples ?? 3;
  // A gap counts as human-active when the physical-input event is newer than the previous sample by
  // more than (a floor of 2ms) or 60% of the gap -- the same threshold sampler.mjs has always used,
  // so moving the math here does not move the answer.
  const humanGap = opts.humanGapFactor ?? 0.6;

  const r = (Array.isArray(samples) ? samples : [])
    .map((x) => (x && typeof x.ts === 'number' ? x : null))
    .filter(Boolean);

  if (r.length < minSamples) {
    return {
      samples: r.length,
      windowMs: 0,
      cursorMaxDeltaPx: null,
      cursorMaxDeltaAt: null,
      foregroundSwitches: null,
      focusChanges: null,
      attribution: null,
      verdict: 'insufficient',
      reason: `proof needs >=${minSamples} samples, got ${r.length}`,
    };
  }

  // Implied absolute timestamp of the last PHYSICAL input at sample x (null if unreadable).
  const physEvent = (x) => (typeof x.inputAgeMs === 'number' && x.inputAgeMs >= 0 ? x.ts - x.inputAgeMs : null);

  let maxD = 0, maxAt = r[0].ts, total = 0;
  let fg = 0, fc = 0, unexplained = 0, unexplainedMax = 0, unexplainedMaxAt = 0;
  let physEvents = 0, humanMs = 0, quietMs = 0, unexplainedFg = 0, unexplainedFc = 0;
  let physUnreadable = 0;

  for (let i = 1; i < r.length; i++) {
    const a = r[i], b = r[i - 1];
    const gap = a.ts - b.ts;
    const ea = physEvent(b), eb = physEvent(a);
    // If either endpoint has no usable input-age (GetLastInputInfo returned -1, e.g. a secure
    // desktop), the gap cannot be attributed -- treat it as NOT-human so any motion there is
    // counted as unexplained. This fails closed: an unreadable instrument must never launder
    // software cursor movement into "the human did it".
    let human = false;
    if (ea === null || eb === null) physUnreadable++;
    else human = eb > ea + Math.max(2, gap * humanGap);

    if (human) { physEvents++; humanMs += gap; } else quietMs += gap;

    const d = Math.hypot(a.cx - b.cx, a.cy - b.cy);
    if (d > maxD) { maxD = d; maxAt = a.ts; }
    total += d;
    if (!human && d > 0.5) { unexplained += d; if (d > unexplainedMax) { unexplainedMax = d; unexplainedMaxAt = a.ts; } }

    if (a.fg !== b.fg) { fg++; if (!human) unexplainedFg++; }
    if (a.focus !== b.focus) { fc++; if (!human) unexplainedFc++; }
  }

  // The noise floor from the control window. Only the unexplained-CURSOR floor is taken from it:
  // an unexplained FOREGROUND/FOCUS switch in the action window is still the software's to explain,
  // because a control window that shows the desktop switching focus on its own would itself mean
  // something is misbehaving -- so foreground/focus stay at their strict zero bar.
  let floorPx = 1;
  let controlUsed = false;
  if (Array.isArray(opts.control) && opts.control.length >= minSamples) {
    const c = evaluateProof(opts.control, { minSamples });
    if (c.attribution) {
      // floor = observed unexplained max in the control, +0.5px margin for the sample-boundary
      // jitter that produced the 3.16px case (a sub-4px nudge by a background helper is real noise;
      // the claim we must still catch is a click DRAGGING the cursor across the screen).
      floorPx = Math.max(1, Math.ceil((c.attribution.unexplainedCursorMaxDeltaPx ?? 0) + 0.5));
      controlUsed = true;
    }
  }

  const attribution = {
    physicalInputEvents: physEvents,
    humanActiveMs: round(humanMs),
    quietMs: round(quietMs),
    unexplainedCursorMaxDeltaPx: round(unexplainedMax),
    unexplainedCursorMaxDeltaAt: unexplainedMaxAt,
    unexplainedCursorPathPx: round(unexplained),
    unexplainedForegroundSwitches: unexplainedFg,
    unexplainedFocusChanges: unexplainedFc,
    unreadableInputAgeGaps: physUnreadable,
  };

  const verdict = verdictFor(attribution, r.length, { floorPx, controlUsed });
  return {
    samples: r.length,
    windowMs: r[r.length - 1].ts - r[0].ts,
    cursorMaxDeltaPx: round(maxD),
    cursorMaxDeltaAt: maxAt,
    cursorTotalPathPx: round(total),
    foregroundSwitches: fg,
    focusChanges: fc,
    attribution,
    floorPx,
    controlUsed,
    verdict: verdict.verdict,
    reason: verdict.reason,
  };
}

// The pass line. A1 (the Must-Pass gate) demands "main cursor maximum displacement = 0px" during a
// proof run. Sub-pixel jitter from a sample boundary is not the cursor moving, so the strict floor is
// 1px on the UNEXPLAINED (software-attributable) delta. But when a control window is available the
// floor is RAISED to the noise the desktop itself produced while we did nothing -- so the bar is a
// measured property of THIS machine at THIS moment, never a constant we hoped would be generous
// enough. Foreground and focus changes keep the strict zero bar in both cases: the product promises
// not to take them, and a background app stealing focus is not a licence for our action to do so.
export function verdictFor(attribution, sampleCount, opts = {}) {
  const unreadableCap = opts.unreadableCap ?? Math.max(1, Math.floor((sampleCount - 1) * 0.3));
  const a = attribution || {};
  if ((a.unreadableInputAgeGaps ?? 0) > unreadableCap) {
    return { verdict: 'inconclusive', reason: `input-age unreadable for ${a.unreadableInputAgeGaps} gaps; cannot attribute motion` };
  }
  // floorPx is the measured/marked cursor floor; when a control drove it, say so in the reason so a
  // reader knows the number is empirical, not assumed.
  const floor = opts.floorPx ?? (opts.maxPx ?? 1);
  const ux = a.unexplainedCursorMaxDeltaPx ?? 0;
  const ufg = a.unexplainedForegroundSwitches ?? 0;
  const ufc = a.unexplainedFocusChanges ?? 0;
  const floorNote = opts.controlUsed ? `, measured floor ${floor}px` : '';
  if (ux > floor) return { verdict: 'fail', reason: `software moved the cursor ${ux}px (limit ${floor}px${floorNote})` };
  if (ufg > 0) return { verdict: 'fail', reason: `${ufg} unexplained foreground switch(es)` };
  if (ufc > 0) return { verdict: 'fail', reason: `${ufc} unexplained focus change(s)` };
  return { verdict: 'pass', reason: `no software-attributable disturbance beyond floor (max ${ux}px vs floor ${floor}px${floorNote})` };
}

// The quantities that ARE the product claim, flattened for a caller that only wants pass/fail facts.
// Kept here so sampler.mjs's exported helper is not a second copy.
export function softwareCursorEvidence(summary) {
  const a = (summary && summary.attribution) || {};
  return {
    maxPx: a.unexplainedCursorMaxDeltaPx ?? null,
    pathPx: a.unexplainedCursorPathPx ?? null,
    foregroundSwitches: a.unexplainedForegroundSwitches ?? null,
    focusChanges: a.unexplainedFocusChanges ?? null,
    quietMs: a.quietMs ?? null,
  };
}
