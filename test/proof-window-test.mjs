// proof-window.test.mjs -- the product's central claim ("driving a window never disturbs the
// owner") becomes a TESTABLE statement only if the judgment can be pinned against windows whose
// right answer is known by construction. This is that file. No syscall, no process: every sample
// below is hand-authored, so a PASS here is a proof about the ARITHMETIC, not about a lucky desktop.
//
// The five cases are chosen to fail in BOTH directions, which is the only way to know the
// attribution is real and not a constant 'pass':
//   1. quiet window, cursor still            -> pass
//   2. a HUMAN moved the mouse, software did not -> pass  (motion is attributed to the human)
//   3. the SOFTWARE moved the cursor, human idle -> fail  (this is the thing we forbid)
//   4. the SOFTWARE switched the foreground, human idle -> fail
//   5. input-age unreadable (secure desktop) -> inconclusive, and a real software move with an
//      unreadable instrument must NEVER be laundered into a pass.
import { evaluateProof, softwareCursorEvidence, verdictFor } from '../lib/proof-window.mjs';

let pass = 0;
const failures = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
};

// inputAgeMs is "ms since last physical input". An AGING age (each sample older than the last) means
// NO new physical event; a DROPPING age means a human just touched something inside that gap.
const mk = (n, over) => Array.from({ length: n }, (_, i) => ({
  ts: 1000 + i * 20,
  cx: 500, cy: 400,
  fg: '111', focus: '222',
  inputAgeMs: 5000 + i * 20,   // monotonic aging => no physical input ever
  ...over?.(i),
}));

// 1. quiet, cursor still
{
  const ev = evaluateProof(mk(20));
  ok('quiet window => pass', ev.verdict === 'pass', JSON.stringify({ v: ev.verdict, r: ev.reason }));
  ok('  raw cursor max delta is 0', ev.cursorMaxDeltaPx === 0, String(ev.cursorMaxDeltaPx));
  ok('  unexplained delta 0, events 0', ev.attribution.unexplainedCursorMaxDeltaPx === 0
    && ev.attribution.physicalInputEvents === 0, JSON.stringify(ev.attribution));
}

// 2. a HUMAN moved the mouse; the software never touched it. The whole cursor path is human motion,
//    so the SOFTWARE-attributable path must be 0 and the verdict stays pass.
{
  // The human grabs the mouse at i=8 and lets go at i=14. Movement and the DROPPED input-age must
  // cover EXACTLY the same gaps. After releasing, the cursor HOLDS at 740 -- a snap-back to 500 in
  // a now-human-quiet gap would itself be software motion and correctly fail, which is the wrong
  // lesson for this case. So: drag 8..14, then still.
  const withHuman = mk(20).map((s, i) => {
    if (i >= 8 && i <= 14) return { ...s, cx: 500 + (i - 8) * 40, inputAgeMs: 5 }; // human: move + fresh event
    if (i > 14) return { ...s, cx: 740 };                                           // released, cursor still
    return s; // i < 8: cursor at 500, age aging (nobody touching)
  });
  const ev = evaluateProof(withHuman);
  ok('human-only motion => pass', ev.verdict === 'pass', JSON.stringify({ v: ev.verdict, raw: ev.cursorMaxDeltaPx, unexp: ev.attribution?.unexplainedCursorMaxDeltaPx }));
  // cursorMaxDeltaPx is the largest PER-GAP delta (the human moved 40px each gap), not the total.
  // The point: a lot of RAW movement happened (max 40px, total path 280px) yet NONE of it is
  // software-attributable -- unexplained path stays ~0. Asserting total path catches the metric mixup.
  ok('  raw path is large but unexplained path is ~0',
    ev.cursorTotalPathPx > 100 && (ev.attribution.unexplainedCursorPathPx ?? 0) < 1,
    `rawPath=${ev.cursorTotalPathPx} unexpPath=${ev.attribution?.unexplainedCursorPathPx}`);
  ok('  at least one physical event was attributed', ev.attribution.physicalInputEvents > 0,
    String(ev.attribution.physicalInputEvents));
}

// 3. the SOFTWARE moved the cursor while the human was idle (age keeps aging). This is forbidden.
{
  const samples = mk(20, (i) => i === 10 ? { cx: 500 + 800 } : (i === 11 ? { cx: 500 + 800 } : {}));
  const ev = evaluateProof(samples);
  ok('software moved cursor, human idle => fail', ev.verdict === 'fail', JSON.stringify({ v: ev.verdict, unexp: ev.attribution?.unexplainedCursorMaxDeltaPx }));
  ok('  the unexplained delta equals the jump', ev.attribution.unexplainedCursorMaxDeltaPx >= 799,
    String(ev.attribution?.unexplainedCursorMaxDeltaPx));
  ok('  softwareCursorEvidence surfaces the number', softwareCursorEvidence(ev).maxPx >= 799,
    JSON.stringify(softwareCursorEvidence(ev)));
}

// 4. the SOFTWARE switched the foreground with the human idle.
{
  const samples = mk(20, (i) => i >= 12 ? { fg: '999' } : {});
  const ev = evaluateProof(samples);
  ok('software switched foreground, human idle => fail', ev.verdict === 'fail',
    JSON.stringify({ v: ev.verdict, ufg: ev.attribution?.unexplainedForegroundSwitches }));
  ok('  unexplained foreground switch counted', ev.attribution.unexplainedForegroundSwitches >= 1,
    String(ev.attribution?.unexplainedForegroundSwitches));
}

// 5. input-age unreadable (every sample -1, e.g. secure desktop): the instrument cannot exonerate
//    the software, so a real cursor jump there must be INCONCLUSIVE, never laundered into a pass.
{
  const unreadable = mk(20).map((s) => ({ ...s, inputAgeMs: -1 }));
  const evIdle = evaluateProof(unreadable);
  ok('unreadable age, cursor still => inconclusive (not pass)', evIdle.verdict === 'inconclusive',
    JSON.stringify({ v: evIdle.verdict, r: evIdle.reason }));

  const jumpUnreadable = mk(20, (i) => i >= 10 ? { cx: 1500 } : {}).map((s) => ({ ...s, inputAgeMs: -1 }));
  const evJump = evaluateProof(jumpUnreadable);
  ok('unreadable age + cursor jump => fail or inconclusive, NEVER pass',
    evJump.verdict !== 'pass', JSON.stringify({ v: evJump.verdict }));
}

// 6. too few samples: honest 'insufficient', the caller must not invent a verdict.
{
  ok('2 samples => insufficient', evaluateProof(mk(2)).verdict === 'insufficient');
  ok('0 samples => insufficient', evaluateProof([]).verdict === 'insufficient');
  ok('malformed entries are dropped, not fatal',
    evaluateProof([{ ts: 1 }, null, { ts: 2, cx: 0, cy: 0, fg: 'a', focus: 'b', inputAgeMs: 10 }, { ts: 3 }]).verdict !== 'pass');
}

// 7. verdictFor is reusable and the 1px floor treats sub-pixel jitter as still.
{
  const subPixel = { unexplainedCursorMaxDeltaPx: 0.5, unexplainedForegroundSwitches: 0, unexplainedFocusChanges: 0, unreadableInputAgeGaps: 0 };
  ok('0.5px jitter => pass (not treated as motion)', verdictFor(subPixel, 20).verdict === 'pass',
    JSON.stringify(verdictFor(subPixel, 20)));
  ok('2px => fail', verdictFor({ ...subPixel, unexplainedCursorMaxDeltaPx: 2 }, 20).verdict === 'fail');
  // a focus-only disturbance (no cursor move) must still fail
  ok('focus change only => fail', verdictFor({ unexplainedCursorMaxDeltaPx: 0, unexplainedForegroundSwitches: 0, unexplainedFocusChanges: 1, unreadableInputAgeGaps: 0 }, 20).verdict === 'fail');
}

// 8. THE CONTROL WINDOW. This is what makes the claim honest on a machine where something OTHER than
//    our action moves the cursor with nobody touching the mouse. Found by the real click arm: on a
//    desktop with an ambient nudge, a clean click measured 3.16px of unexplained motion and failed
//    against a hardcoded 1px. The floor is now MEASURED from a window where by construction we did
//    nothing -- and the arms below pin both directions so the control cannot become a rubber stamp.
{
  // A control window where the desktop itself produced ~4px of unexplained motion.
  const jittery = (px) => mk(20, (i) => i === 5 ? { cx: 500 + px } : (i > 5 ? { cx: 500 + px } : {}));
  const control = jittery(4);
  const cEval = evaluateProof(control);
  ok('control window itself shows ~4px unexplained', cEval.attribution.unexplainedCursorMaxDeltaPx >= 3.5,
    String(cEval.attribution?.unexplainedCursorMaxDeltaPx));

  // Same 4px in the ACTION window: against a measured floor it is PASS (ambient, not ours);
  // without a control it is still FAIL (strict 1px, fail closed). Both directions matter.
  const sameAction = jittery(4);
  const withControl = evaluateProof(sameAction, { control });
  const withoutControl = evaluateProof(sameAction);
  ok('4px action + 4px control => pass', withControl.verdict === 'pass',
    JSON.stringify({ v: withControl.verdict, floor: withControl.floorPx, used: withControl.controlUsed }));
  ok('  floor was measured from control and reported', withControl.controlUsed === true && withControl.floorPx >= 4,
    `floorPx=${withControl.floorPx} controlUsed=${withControl.controlUsed}`);
  ok('4px action, NO control => fail (fail closed, never hope the floor is generous)',
    withoutControl.verdict === 'fail', JSON.stringify({ v: withoutControl.verdict, floor: withoutControl.floorPx }));

  // THE CONTROL MUST NOT BECOME A RUBBER STAMP. A real drag (500px) on a jittery desktop still fails.
  const drag = mk(20, (i) => i >= 6 ? { cx: 500 + (i - 6) * 100 } : {});
  const dragged = evaluateProof(drag, { control });
  ok('a real 500px drag still fails despite a jittery control', dragged.verdict === 'fail',
    JSON.stringify({ v: dragged.verdict, unexp: dragged.attribution?.unexplainedCursorMaxDeltaPx, floor: dragged.floorPx }));

  // Foreground/focus keep the ZERO bar even with a control that is itself switching: a background
  // app stealing focus is not a licence for our action to do it. This is the asymmetry that makes
  // 'floor' mean cursor noise only.
  const fgControl = mk(20, (i) => i >= 5 ? { fg: '999' } : {});
  const fgAction = mk(20, (i) => i >= 10 ? { fg: '888' } : {});
  const fgEval = evaluateProof(fgAction, { control: fgControl });
  ok('unexplained foreground switch fails even when the control also switched', fgEval.verdict === 'fail',
    JSON.stringify({ v: fgEval.verdict, ufg: fgEval.attribution?.unexplainedForegroundSwitches }));

  // A control too short to judge is IGNORED, and the action falls back to the strict floor --
  // "no usable control" must never silently widen the bar.
  const tinyControl = mk(2);
  const tinyEval = evaluateProof(jittery(4), { control: tinyControl });
  ok('unusable control (too few samples) => strict floor, 4px fails',
    tinyEval.controlUsed === false && tinyEval.verdict === 'fail',
    JSON.stringify({ v: tinyEval.verdict, used: tinyEval.controlUsed, floor: tinyEval.floorPx }));
}

console.log('');
console.log(`proof-window: ${pass} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);
