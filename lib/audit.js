// audit.js -- one JSONL line per action, appended to %LOCALAPPDATA%\wpm\audit.log.
//
// WHY THIS EXISTS AT ALL. Every other field in this product answers "what did the caller get back".
// None of them answers the question that is asked AFTER something went wrong, at 3 a.m., by someone who
// needs to know what the agent did to this machine and when: `policy_denied` is visible to the caller
// and gone a second later. This file is the only artifact that survives the call, and per the plan it is
// written for ALLOW as well as DENY -- an audit trail that only records refusals documents the times the
// guard worked and is silent about the times it didn't have to.
//
// WHAT IS DELIBERATELY NOT HERE, because an audit log is a copy of what it records:
//   * clipboard CONTENT -- op, format and character count only (R8: the clipboard may hold a token);
//   * typed text -- its LENGTH, never its value, for the same reason;
//   * anything else that is content rather than a decision.
// The line is a decision record: who asked, what was permitted, what tier it cost, what the engine
// reported. That is enough to reconstruct an incident and not enough to leak one.
//
// BEST-EFFORT WRITE, VISIBLE FAILURE. An audit that can throw would turn a successful action into a
// failed one -- so failures are counted and reported in the result text (`auditNote=...`) rather than
// raised. Silently swallowing a broken audit is the exact opposite of what this file is for.
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir, tmpdir } from 'node:os';

/** The same base the engine uses (win.ps1 Get-WpmDataDir) -- one directory to open when reviewing. */
export function auditDir() {
  const base = process.env.LOCALAPPDATA || join(homedir() || tmpdir(), 'AppData', 'Local');
  return join(base, 'wpm');
}
export function auditPath() { return join(auditDir(), 'audit.log'); }

/**
 * Build the line. Kept separate from the write so a test can assert the SHAPE without touching the disk,
 * and so the "never content" rule is one function deep rather than a habit.
 * @param {{ts?:number, action:string, hwnd?:string, tier?:string, policy?:string,
 *   decision:string, code?:string, userActiveAgeMs?:number, effect?:string, latencyMs?:number,
 *   detail?:string, target?:string, args?:string, op?:string, format?:string, chars?:number,
 *   resultChars?:number, forced?:boolean}} rec
 * @returns {string} one JSON object, no newline
 */
export function auditLine(rec) {
  // Built as an open record because the shape is CONDITIONAL by design: a launch line carries target and
  // arguments, a clipboard line carries op/format/length, and an ordinary action carries neither. A
  // closed literal would force every line to carry every field (and so to record a clipboard `text` it is
  // not allowed to record) or force a cast per branch -- which is exactly how a "not here"
  // privacy rule becomes a "here, because the type said so" leak.
  /** @type {Record<string, any>} */
  const out = {
    ts: rec.ts ?? Date.now(),
    action: String(rec.action ?? ''),
    hwnd: String(rec.hwnd ?? ''),
    tier: String(rec.tier ?? ''),
    policy: String(rec.policy ?? ''),
    // decision is one of 'allow' | 'deny'. `code` is the refusal code when it is a deny, empty when it
    // is an allow -- and it is recorded for BOTH so a reader can sort by outcome instead of guessing
    // from a missing field.
    decision: rec.decision === 'deny' ? 'deny' : 'allow',
    code: String(rec.code ?? ''),
    userActiveAgeMs: Number.isFinite(rec.userActiveAgeMs) ? rec.userActiveAgeMs : -1,
    effect: String(rec.effect ?? ''),
    latencyMs: Number.isFinite(rec.latencyMs) ? rec.latencyMs : -1,
  };
  if (rec.target !== undefined) out.target = String(rec.target);
  if (rec.args !== undefined) out.args = String(rec.args);
  if (rec.op !== undefined) out.op = String(rec.op);
  if (rec.format !== undefined) out.format = String(rec.format);
  // Length, never payload. The field name says which, so a reader of the log cannot mistake `chars`
  // for content and neither can a reviewer of this line.
  if (rec.chars !== undefined) out.chars = Number(rec.chars);
  if (rec.forced === true) out.forced = true;
  if (rec.detail) out.detail = String(rec.detail);
  return JSON.stringify(out);
}

/**
 * Append one decision, then keep the file bounded. The prune rewrites the file (read last N lines,
 * write, swap), which is the same newest-first discipline the screenshot retention uses -- a log that
 * grows without bound is a disk problem that arrives at the worst possible moment, and a truncation that
 * drops the NEWEST lines instead of the oldest is a cover-up.
 * @param {string} line @param {{keep?:number}} [opts]
 * @returns {{ok:boolean, wrote:boolean, error?:string}}
 */
export function auditWrite(line, opts = {}) {
  const keep = Math.max(1, Math.min(200000, opts.keep ?? 2000));
  try {
    const path = auditPath();
    if (!existsSync(dirname(path))) mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, line + '\n', 'utf8');
    // Prune only when the file is plausibly over budget: a line count on every action would read the
    // whole log each time, and an audit must never become the slow part of a click.
    let lines = 0;
    try {
      const buf = readFileSync(path, 'utf8');
      lines = buf.split('\n').filter((l) => l !== '').length;
    } catch { lines = 0; }
    if (lines > keep * 1.25 || lines > keep + 500) {
      const tail = readFileSync(path, 'utf8').split('\n').filter((l) => l !== '').slice(-keep);
      const tmp = path + '.new';
      writeFileSync(tmp, tail.join('\n') + '\n', 'utf8');
      try { renameSync(tmp, path); } catch { }
    }
    return { ok: true, wrote: true };
  } catch (err) {
    // `catch` binds `unknown` under checkJs+strict, so the message is reached through a type test rather
    // than a cast: an audit failure that itself threw on the way out would be a worse bug than the one it
    // is meant to make visible.
    const message = err && typeof err === 'object' && 'message' in err ? String(/** @type {{message?: string}} */ (err).message) : String(err);
    return { ok: false, wrote: false, error: message };
  }
}
