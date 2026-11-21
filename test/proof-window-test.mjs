// proof-window-test.mjs -- the product's central claim ("driving a window never disturbs the owner")
// is testable ONLY if the judgment can be pinned against windows whose right answer is known by
// construction. This is that file. No syscall, no process: every sample below is hand-authored, so a
// PASS here is a proof about the ARITHMETIC, not about a lucky desktop.
//
// The cases are chosen to fail in BOTH directions, which is the only way to know the attribution is
// real and not a constant: a verdict function that only ever returns 'pass' and one that only ever
// returns 'fail' are both worthless. The three-verdict design (pass / inconclusive / fail) is
// exercised here from the three-run desktop investigation recorded in proof-window.mjs's header.
import { evaluateProof, softwareCursorEvidence, verdictFor } from '../lib/proof-window.mjs';

let pass = 0;
const failures = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
};

// inputAgeMs is "ms since last physical input". An AGING age (each sample's implied event time
// unchanged) means NO new physical input; a DROPPING age means a human touched something in the gap.
const mk = (n, over) => Array.from({ length: n }, (_, i) => ({
  ts: 1000 + i * 20,
  cx: 500, cy: 400,
  fg: '111', focus: '222',
  inputAgeMs: 5000 + i * 20,   // monotonic aging => the same physical event ages, nobody new
  ...over?.(i),
}));

// 1. quiet window, cursor still => PASS. The direct, strong case.
{
  const ev = evaluateProof(mk(20));
  ok('quiet window => pass', ev.verdict === 'pass', JSON.stringify({ v: ev.verdict, r: ev.reason }));
  ok('  zero unexplained motion gaps', ev.attribution.unexplainedCursorMotionGaps === 0,
    String(ev.attribution?.unexplainedCursorMotionGaps));
  ok('  dimensions all pass', ev.dimensions.cursor === 'pass' && ev.dimensions.foreground === 'pass'
    && ev.dimensions.focus === 'pass', JSON.stringify(ev.dimensions));
}

// 2. a HUMAN moved the mouse; the software did not. All motion is human-attributed, so zero
//    UNEXPLAINED gaps remain and the verdict is still pass -- proof the human path is excluded.
{
  const withHuman = mk(20).map((s, i) => {
    if (i >= 8 && i <= 14) return { ...s, cx: 500 + (i - 8) * 40, inputAgeMs: 5 }; // human: move + fresh event
    if (i > 14) return { ...s, cx: 740 };                                           // released, cursor still
    return s;
  });
  const ev = evaluateProof(withHuman);
  ok('human-only motion => pass', ev.verdict === 'pass',
    JSON.stringify({ v: ev.verdict, gaps: ev.attribution?.unexplainedCursorMotionGaps }));
  ok('  raw path is large but unexplained gaps are zero',
    ev.cursorTotalPathPx > 100 && ev.attribution.unexplainedCursorMotionGaps === 0,
    `rawPath=${ev.cursorTotalPathPx} gaps=${ev.attribution?.unexplainedCursorMotionGaps}`);
  ok('  at least one physical event was attributed', ev.attribution.physicalInputEvents > 0,
    String(ev.attribution.physicalInputEvents));
}

// 3. THE ISOLATED AMBIENT NUDGE => INCONCLUSIVE, never a wolf-cry fail, never a laundered pass.
//    This is the 3.16px/7.07px real-desktop case: one gap of cursor motion with NO physical input.
//    A single position delta cannot name its cause (us or some other process), so the gate reports it.
{
  const jump = mk(20, (i) => i === 10 ? { cx: 1300 } : (i > 10 ? { cx: 1300 } : {})); // one 800px warp, then still
  const ev = evaluateProof(jump);
  ok('isolated single-gap cursor jump => inconclusive (not fail, not pass)',
    ev.verdict === 'inconclusive', JSON.stringify({ v: ev.verdict, gaps: ev.attribution?.unexplainedCursorMotionGaps }));
  ok('  exactly one unexplained motion gap', ev.attribution.unexplainedCursorMotionGaps === 1,
    String(ev.attribution?.unexplainedCursorMotionGaps));
  ok('  the number is surfaced in the reason', String(ev.reason).includes('800'), String(ev.reason));
}

// 4. MULTI-GAP cursor motion => INCONCLUSIVE, not fail. This reversal is measured, not conceded:
//    the idle baseline (scripts/idle-baseline.mjs) saw up to 3 unexplained gaps at 11px with NOTHING of
//    ours running, so even structured-looking motion cannot be blamed on the action from positions.
//    The cursor promise is enforced at build time (check-no-cursor-control.mjs); this sensor reports.
{
  const drag = mk(20, (i) => i >= 6 ? { cx: 500 + (i - 6) * 100 } : {}); // motion across many gaps
  const ev = evaluateProof(drag);
  ok('multi-gap cursor drag => inconclusive (positions cannot blame; build gate owns the promise)',
    ev.verdict === 'inconclusive', JSON.stringify({ v: ev.verdict, gaps: ev.attribution?.unexplainedCursorMotionGaps }));
  ok('  more than one unexplained motion gap still measured', ev.attribution.unexplainedCursorMotionGaps >= 2,
    String(ev.attribution?.unexplainedCursorMotionGaps));
  ok('  the drag still cannot read pass', ev.verdict !== 'pass', ev.verdict);
  ok('  softwareCursorEvidence carries the gap count', softwareCursorEvidence(ev).motionGaps >= 2,
    JSON.stringify(softwareCursorEvidence(ev)));
}

// 5. FOREGROUND/FOCUS with a clean control => FAIL. The control window proves the desktop was NOT
//    stealing seconds before, so a switch during the action is ours to explain.
{
  const cleanControl = mk(20);
  const switched = mk(20, (i) => i >= 12 ? { fg: '999' } : {});
  const ev = evaluateProof(switched, { control: cleanControl });
  ok('foreground switch with clean control => fail', ev.verdict === 'fail',
    JSON.stringify({ v: ev.verdict, dims: ev.dimensions }));
  ok('  the foreground dimension is the failing one', ev.dimensions.foreground === 'fail'
    && ev.dimensions.cursor === 'pass', JSON.stringify(ev.dimensions));

  const focusLost = mk(20, (i) => i >= 10 ? { focus: '888' } : {});
  const evFc = evaluateProof(focusLost, { control: cleanControl });
  ok('focus change with clean control => fail', evFc.dimensions.focus === 'fail',
    JSON.stringify(evFc.dimensions));
}

// 6. FOREGROUND/FOCUS when the CONTROL also switched => INCONCLUSIVE. The desktop was stealing focus on
//    its own seconds before; we cannot pin its behaviour on our action. Reporting it is the honest
//    answer -- fail would blame us for the desktop, pass would hide that focus left.
{
  const busyControl = mk(20, (i) => i >= 5 ? { fg: 'CHURN' } : {});   // desktop stealing in the control
  const alsoSwitch = mk(20, (i) => i >= 12 ? { fg: '999' } : {});
  const ev = evaluateProof(alsoSwitch, { control: busyControl });
  ok('foreground switch mirroring a busy control => inconclusive', ev.verdict === 'inconclusive',
    JSON.stringify({ v: ev.verdict, dims: ev.dimensions }));
  ok('  foreground dimension is inconclusive, not fail', ev.dimensions.foreground === 'inconclusive',
    JSON.stringify(ev.dimensions));
}

// 7. unreadable instrument (secure desktop, every age = -1) => INCONCLUSIVE. Silence is not innocence:
//    the gate cannot exonerate the software, and a real drag on an unreadable instrument must still
//    never read as pass.
{
  const unreadable = mk(20).map((s) => ({ ...s, inputAgeMs: -1 }));
  const evIdle = evaluateProof(unreadable);
  ok('unreadable age everywhere => inconclusive (not pass)', evIdle.verdict === 'inconclusive',
    JSON.stringify({ v: evIdle.verdict, r: evIdle.reason }));
  const jumpUnreadable = mk(20, (i) => i >= 10 ? { cx: 1500 } : {}).map((s) => ({ ...s, inputAgeMs: -1 }));
  ok('unreadable age + cursor jump => never pass', evaluateProof(jumpUnreadable).verdict !== 'pass',
    evaluateProof(jumpUnreadable).verdict);
}

// 8. too few samples => 'insufficient'. The caller must not invent a verdict from nothing.
{
  ok('2 samples => insufficient', evaluateProof(mk(2)).verdict === 'insufficient');
  ok('0 samples => insufficient', evaluateProof([]).verdict === 'insufficient');
  ok('malformed entries dropped, not fatal',
    evaluateProof([{ ts: 1 }, null, { ts: 2, cx: 0, cy: 0, fg: 'a', focus: 'b', inputAgeMs: 10 }, { ts: 3 }]).verdict !== 'pass');
}

// 9. THE VERDICT ORDERING: fail > inconclusive > pass, decided PER DIMENSION and folded worst-first.
//    A clean cursor but a focus steal must not be rescued by the good dimension.
{
  const okControl = mk(20);
  const cursorQuietFocusStolen = mk(20, (i) => i >= 10 ? { focus: 'X' } : {});
  const ev = evaluateProof(cursorQuietFocusStolen, { control: okControl });
  ok('clean cursor + focus steal (clean control) => overall fail', ev.verdict === 'fail',
    JSON.stringify({ v: ev.verdict, dims: ev.dimensions }));
}

// 10. THE CURSOR DIMENSION NEVER FAILS, at any gap count or size -- this is the recorded boundary:
//     blame belongs to the build-time no-cursor-primitive gate, measurement belongs to the sensor.
{
  const base = { unexplainedCursorMaxDeltaPx: 5000, unexplainedForegroundSwitches: 0, unexplainedFocusChanges: 0, unreadableInputAgeGaps: 0 };
  ok('1 gap 5000px => inconclusive', verdictFor({ ...base, unexplainedCursorMotionGaps: 1 }, null, 20).dimensions.cursor === 'inconclusive');
  ok('10 gaps 3px  => inconclusive (never fail -- idle motion is multi-gap too)',
    verdictFor({ ...base, unexplainedCursorMotionGaps: 10, unexplainedCursorMaxDeltaPx: 3 }, null, 20).dimensions.cursor === 'inconclusive');
  ok('0 gaps => pass', verdictFor({ ...base, unexplainedCursorMotionGaps: 0 }, null, 20).dimensions.cursor === 'pass');
}

// 10b. DECLARED FLASH: the bounded-flash tier raises foreground by design and restores it after the
//      sample window. A switch during OUR declared flash is not a secret steal; the restore table
//      owns "never KEEP the foreground" (restore_failed). The sensor reports 'declared', passes.
{
  const flashAttribution = { unexplainedCursorMotionGaps: 0, unexplainedForegroundSwitches: 2,
    unexplainedFocusChanges: 0, unreadableInputAgeGaps: 0 };
  const undeclared = verdictFor(flashAttribution, null, 20);
  const declared = verdictFor(flashAttribution, null, 20, { declaredFlash: true });
  ok('foreground switch, quiet tier, clean control => fail', declared && undeclared.dimensions.foreground === 'fail',
    JSON.stringify(undeclared.dimensions));
  ok('same switch on the DECLARED flash tier => not failed (contract says raise-then-restore)',
    declared.dimensions.foreground === 'declared' && declared.verdict === 'pass',
    JSON.stringify({ d: declared.dimensions, v: declared.verdict }));
  ok('  the switch is still REPORTED in the reason, never silently passed',
    String(declared.reason).includes('DECLARED'), String(declared.reason));
  // The flash tier's declared-ness must NOT excuse a focus change that isn't part of the contract:
  const focusSteal = { ...flashAttribution, unexplainedForegroundSwitches: 0, unexplainedFocusChanges: 1 };
  ok('focus change on the flash tier is still fail (the contract covers foreground, not a focus grab)',
    verdictFor(focusSteal, null, 20, { declaredFlash: true }).dimensions.focus === 'fail');
}

// 11. NO CONTROL falls back conservatively, never widening: an action foreground switch with no
//     control data is still the software's to explain (fail), and an isolated jump stays inconclusive.
{
  const fgSwitchNoControl = mk(20, (i) => i >= 10 ? { fg: '9' } : {});
  ok('foreground switch, NO control => fail (fail closed, never widen the bar on missing data)',
    evaluateProof(fgSwitchNoControl).verdict === 'fail', JSON.stringify(evaluateProof(fgSwitchNoControl).dimensions));
}

// 12. THE EFFECT DIMENSION: "who reported the success", so a clean window can never outvote a
//     total no-op. Same quiet samples throughout -- the ONLY thing that changes is the effect, which
//     proves the verdict moves on the effect and not on the (unmoving) desktop. The old plan named
//     this case (50 failed calls, zero displacement, green light) and never landed it; these four
//     arms are that case, direction by direction.
{
  const quiet = mk(20);

  // (a) nothing to report at all => never a pass. Silence is not innocence here either.
  const unv = evaluateProof(quiet, { effect: 'unverified' });
  ok("zero displacement + effect 'unverified' => NOT pass", unv.verdict !== 'pass',
    JSON.stringify({ v: unv.verdict, dims: unv.dimensions }));
  ok('  the effect dimension is what refuses the pass', unv.dimensions?.effect === 'inconclusive',
    JSON.stringify(unv.dimensions));

  // (b) THE ANTI-SELF-DECEPTION CASE: 50 attempts, every one failed, not one pixel of displacement.
  const allFailed = evaluateProof(quiet, {
    effect: 'unverified',
    actions: Array.from({ length: 50 }, () => ({ ok: false, effect: 'unverified' })),
  });
  ok('zero displacement + 50 failed attempts => fail', allFailed.verdict === 'fail',
    JSON.stringify({ v: allFailed.verdict, dims: allFailed.dimensions }));
  ok('   the reason says the actions never took effect (动作未生效)', /动作未生效/.test(allFailed.reason),
    allFailed.reason);

  // (c) a channel reported the call returned. Not a red -- nobody proved it did not -- but the reason
  //     must refuse to call it verified, or the tool is over-claiming exactly like the README may not.
  const sent = evaluateProof(quiet, { effect: 'reported-by-send' });
  ok("zero displacement + 'reported-by-send' => pass (no false red)", sent.verdict === 'pass',
    JSON.stringify({ v: sent.verdict, dims: sent.dimensions }));
  ok('   but the reason carries 未独立验证 (the channel spoke, nobody observed the app)',
    /未独立验证/.test(sent.reason), sent.reason);

  // (d) ONE pattern-reported attempt stays a pass: the false-red defence. Half-landed evidence is not
  //     a failure, and collapsing it into one would train callers to ignore the verdict.
  const pat = evaluateProof(quiet, { effect: 'reported-by-pattern' });
  ok("zero displacement + a single 'reported-by-pattern' => pass", pat.verdict === 'pass',
    JSON.stringify({ v: pat.verdict, dims: pat.dimensions }));
  ok('  the effect dimension passes, and the caveat is still printed', pat.dimensions?.effect === 'pass'
    && /未独立验证/.test(pat.reason), JSON.stringify(pat.dimensions));
}

console.log('');
console.log(`proof-window: ${pass} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);
