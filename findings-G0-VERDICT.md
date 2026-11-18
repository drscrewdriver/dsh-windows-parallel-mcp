# G0-VERDICT: the channel matrix, and what it does to R2

Date: run `cx6` (24 measured rounds + 6 control rounds, zero discards).
Instruments: `scripts/channel-raise-matrix.ps1`, `scripts/invoke-raise-check.ps1`,
`scripts/diag-msgchan-xproc.ps1`.

## The measurement

| channel | usable | effect verified | took its own foreground | cursor moved | verdict |
|---|---|---|---|---|---|
| (control: no call) | 6 | — | **0** | 0 | base rate 0/6 |
| `uiA.invoke` (InvokePattern) | 6 | 6/6 | **6 (100%)** | 0 | RAISES ITS WINDOW |
| `uiA.setvalue` (ValuePattern) | 6 | 6/6 | **6 (100%)** | 0 | RAISES ITS WINDOW |
| `msg.WM_CHAR` | 6 | 6/6 | **0** | 0 | never took foreground |
| `msg.WM_SETTEXT` | 6 | 6/6 | **0** | 0 | never took foreground |

Both arms ran identical settle, identical guard sampling, identical duration, interleaved
round by round. The control arm exists because "no raise observed" is not a result: without
a measured base rate, a clean-looking channel is indistinguishable from a desktop that never
got around to doing anything.

Every effect was verified by the application's own state, not by the call returning: the WPF
button's Name counter, the WPF edit's re-resolved value, and the WinForms app-side state
oracle for the message channels.

## R2 as written does not survive, and R2 as a product does

R2's claim — an agent drives its own target window while the real cursor never moves and the
keyboard focus never changes — is **half true, and the true half is the half the plan
deprioritised**:

* The cursor claim **holds**. Across every channel above, `cursorMoves=0`. Nothing moved the
  pointer. That part of R2 was never in danger.
* The foreground/focus claim **fails for UIA patterns** and **holds for window messages**.
  `InvokePattern.Invoke` and `ValuePattern.SetValue` each took their target to the foreground
  in 6/6 rounds against a base rate of 0/6, with no mouse button down, no Alt/Ctrl/Win chord
  down and the cursor never inside the target rect during any measured action.
* R2.2 specified the order: *UIA pattern first, target-window messages second*. The
  measurement says that order is exactly backwards for the property the whole project exists
  to provide. The preferred channel is the disruptive one.

The decision the matrix output states: **the engine restricts itself to the message channels
and refuses the UIA-pattern channels** — or refuses the action outright where only a pattern
channel exists. This is a plan inversion, not a plan cancellation, and it is the kind of
inversion G0 exists to catch before P2 writes a kernel around the wrong premise.

## The catch that decides whether it is still a product

The neutral channels were measured on WinForms, which has real child HWNDs to address. The
toolkit census says `uap-framed` is the largest family on this machine (27 of 73 visible
windows), and the probe record says modern apps report `NativeWindowHandle=0` — meaning a
message channel has **no address to write to** there. Chromium pages likewise have no child
HWND per element.

So the open, product-deciding number is not "does a neutral channel exist" (yes, two of them)
but **what fraction of the reachable actions on this desktop can be routed through a neutral
channel**. If that fraction is small, an engine that refuses the disruptive channels is
correct and nearly useless, and the honest move is to ship the refusal, not a slower version
of the same disturbance. This is the coverage measurement, and it is what P0 task_6 must
produce before P2 starts.

## Two secondary findings the run produced

**`WM_GETTEXT` across processes is blind, and it made the matrix report a working channel as
dead.** The message channels initially scored 0/6 "no verified effect". An in-process control
had shown them working perfectly, so the instrument was believed rather than the result — and
the app-side oracle settled it the other way: `abc` → `abcZ` → `QabcZ` → `QPabcZ` while
`WM_GETTEXT` returned `abc` throughout, and returned `''` for a RichTextBox holding
`rich-abc`. Cross-process reads of another process's edit control are the thing being
measured, never the thing measuring it. Same lesson the Chromium page experiment already
taught, arrived at independently for the third time.

**`ValuePattern.SetValue` on this WPF edit does not round-trip.** The value read back through
UIA after each write carried additional leading whitespace that grew every round (56 spaces by
round 6), while the write itself clearly landed. A UIA text write that cannot be read back
identically is a corruption path: an agent that reads, appends, and writes back would grow the
padding on every turn. Recorded because the engine will need to know whether the corruption is
in the write or in the read path before it trusts `uiA.setvalue` on any toolkit — and because
this run cannot distinguish those two, it must not claim to.

## Why the earlier two attempts at this number were wrong, in one line each

* Requiring a physically idle desktop: the largest `GetLastInputInfo` age observed in 6160
  sampler rows was 109ms, so the precondition can never be met on a machine in use, and the
  run would print "could not tell" forever.
* Guarding only against mouse input: Alt+Tab, Alt+Esc and Win+number change the foreground
  with no button and no cursor movement, so a clean round could never convict — and the first
  version of this script drew the *opposite* conclusion from an empty control arm, printing
  "NO channel is foreground-neutral" with zero usable rounds. Absence of evidence rendered as
  evidence of absence, in the one place the plan depends on it.
