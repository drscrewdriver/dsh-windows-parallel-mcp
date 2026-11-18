# G0-VERDICT: the channel matrix, and what it does to R2

Date: run `cx6` (24 measured rounds + 6 control rounds, zero discards).
Instruments: `scripts/channel-raise-matrix.ps1`, `scripts/invoke-raise-check.ps1`,
`scripts/diag-msgchan-xproc.ps1`.

REPRODUCED: the same matrix run twice more as `cx13`/`cx14` (6 rounds each) gives the same
structure — control 0/6, UIA pattern channels absent on WinForms, both message channels 0
raises with app-side verified effects (11 of 12 rounds), zero cursor movement. Reproduced on a
different pre-action foreground than cx6, which is the point: the headline result survived
being measured again under a different desktop state.

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

## The coverage number, measured (neutral-coverage-census.ps1)

A neutral channel needs a window ADDRESS. Measured on this desktop as it stands, read-only,
57 live titled top-level windows after excluding 5 DWM-cloaked ones (9 of the 57 minimized):

```
family                   windows   w/door     iconic clickables writables     door%
uap-framed                    30        0          2         0         0        0%
winui-notepad                 11       11          1         0        11      100%
electron/chromium-app          7        0          2         0         0        0%
win32-shell                    3        3          3         9         0      100%
other:Zed::Window, qt, CEF-OSC-WIDGET, EVERYTHING, Progman, TaskManager  (6 windows, 3 with doors)

WINDOW-LEVEL: 17 of 57 live windows have at least one classic child HWND a message could address (30%)
```

The two largest families -- UWP-framed (30 windows) and Chromium/Electron (7) -- have **zero**
message doors. By app rather than by window, the doors belong to Notepad, the Explorer shell,
and a few classic utilities.

The UIA side is worse, and the way it is worse is the finding:

```
POSITIVE CONTROL (our own WinForms window, a child HWND known to exist):
  UIA descendants=3 carrying an HWND=3   => the property read WORKS in this process
sampled windows: 12   UIA actionable elements: 173   of which carrying an HWND: 0
ACTIONABLE-ELEMENT door ratio (UIA side): 0%
```

The control had to come first: "0% of actionable elements anywhere are addressable" is the
strongest claim in this file and therefore the least deserving of belief uncontrolled. With
the control passing, the 0% is a fact about the desktop. But note the disagreement -- Notepad
has 11 writable classic child windows per the Win32 tree, while its UIA elements report
`NativeWindowHandle=0` for all 15 actionable ones. Both are true, and the consequence is a
design cost, not a coverage win: **the engine cannot route from the element the agent chose to
the window the message must be sent to.** It would have to walk the classic child tree and
match by bounding rectangle and class, which makes "is this the control the user meant?" a
positional heuristic -- and writing into the wrong child window fails silently, the same class
of error that made an earlier experiment read the address bar instead of the page.

The control also caught a filter error that would have erased the engine's only working target:
our own WinForms TextBox/Button/RichTextBox surface as `ControlType=Pane`, not as Button/Edit,
so a coverage figure drawn from actionable *control types* reports zero for the one family where
the message channel demonstrably works.

## The sharper finding: the two kinds of door are complementary AND mutually exclusive

`probe-winform-patterns.ps1` asked UIA what the elements themselves claim to implement
(`Current.SupportedPatterns`, which is the provider's own statement, not one failed
`TryGetCurrentPattern` call), on our own WinForms window, with every legacy-accessibility
AppContext switch set in BOTH the driver and the target:

```
descendants: 3
  [0] ct=Pane native=1907024  name='abc'       patterns=        <- the EDIT child
  [1] ct=Pane native=1905528  name='Press'     patterns=        <- the BUTTON child
  [2] ct=Pane native=2367310  name='rich-abc'  patterns=        <- the RichEdit child
  frame: ct=ControlType.Window patterns=
```

No control type, no patterns, nothing on the frame either. Yet those exact handles are the
targets WM_CHAR and WM_SETTEXT write into successfully, verified app-side, 6/6 rounds.

Combining this with the rest of the evidence gives a table that is more damning than a
coverage percentage:

| toolkit | UIA pattern door | message door | what the pattern door does |
|---|---|---|---|
| WinForms / classic Win32 | **absent** to this client | **present, and neutral** | — |
| WPF | present | **absent** (no classic child HWNDs) | raises the window, 12/12 vs 0/12 control |
| UWP/WinUI (`uap-framed`) | present (Calculator 8/8, Store) | absent (`NativeWindowHandle=0`) | raises the window |
| Chromium / Electron | present (lazy a11y, page write 6/6) | absent | raises the window |

So the quiet door exists only where the identifiable door does not, and the identifiable door
exists only where acting through it is the thing that steals the desktop. There is no family
on this machine where an agent can BOTH point at a specific control through UIA AND act on it
without foreground disturbance. Any engine that wanted to be quiet would have to address
controls by raw handle plus class plus rectangle -- positional matching -- which is the
heuristic that previously made an experiment type into the browser's address bar while
believing it had reached the page.

**Detector caveat, stated rather than glossed.** The "message channels do not raise" result was
measured on WinForms, where no UIA pattern was available to serve as an in-run raising control.
The raise detector is the comparison `foreground-after == acted-upon-handle`, and the same
comparison fired 6/6 and 12/12 elsewhere in this session, including with the acting window
being ours and the pre-action foreground being a third window's -- which is also the state every
WinForms round was in (foreground held by Calculator's frame throughout, before and after).
The detector is only partly re-verified on this window class. A known raise WAS attempted here
(the target's own process activating its own window, the one route the foreground lock permits):
it took the foreground in 1 of 6 attempts — permission-dependent — and the detector fired 1/1
on it, so the detector is not blind on WinForms. That is evidence, not a characterization; full
detection power still rests mainly on the identical detector firing 6/6 (Calculator) and 12/12
(WPF) on other classes within the same runs. A residual possibility remains that a raise
produced specifically by a WinForms message would go undetected; it is small, it is not proven
away, and the verdict does not rest on it alone: the 30% coverage figure and the pattern-absence
result are independent of it. (The earlier text here claimed the foreground was "Calculator's
frame throughout, before and after" — true of the cx6 run, false of cx13/cx14, which re-verify
at rest that the target does NOT hold the foreground; corrected so the record matches the
instrument that produced it.)


## Mitigating the raise: AttachThreadInput DOES unlock the hand-off (2026-11-19, unresolved)

The G0 verdict killed R2 because UIA pattern actions raise their window, and an earlier check
rejected *undoing* that on the grounds that `SetForegroundWindow` is refused to a non-owning
process (measured 30/36). That rejection covered only the bare call. `fg-restore-attempt.ps1`
tested the documented unlock — `AttachThreadInput` into the thread owning the current
foreground, then `SetForegroundWindow` — and the key **turns**: AttachThreadInput succeeded
6/6 and SetForegroundWindow returned TRUE 6/6, with the foreground held to +3s in most
rounds. So the blanket statement "the damage cannot be undone from a separate process" is
**false**; a bounded-disturbance UIA channel (raise, then reverse within tens of ms) is not
dead on the old argument.

But it is NOT yet bankable, for a reason that is itself the lesson:

- **The decisive control is not reproducible across runs.** The persist arm (raise, then don't
  touch) is supposed to show the raise STANDING so a restore "success" is causal, not ambient.
  Run fgr3: persisted 4/4 (clean causal signal). Run fgr4: self-reverted 4/6. When the control
  flips sign between adjacent runs of one command, no verdict follows — the run that would
  "prove" the mitigation works is indistinguishable from the desktop settling.
- **My own fix caused the flip.** fgr4 added `ReleaseOurs` = `ShowWindow(minimize)` then
  `ShowWindow(SW_SHOWNA)` as per-round baseline hygiene (to stop a stuck-foreground cascade
  that ate half of fgr3). Minimize is a foreground-affecting operation on the WPF window, so
  the cleanup perturbed exactly the focus behaviour the persist arm measures — the same family
  as "launch a process to test whether the desktop is idle": an instrument that disturbs its
  subject while trying to steady it.
- A separate, earlier defect (fgr3) was the denominator counting PRECOND-FAIL rounds as failed
  restores; fixed by an explicit outcome whitelist.

Status: mitigation is **promising but unresolved**. The correct next measurement is a single
clean design — interleaved arms, one baseline method that does NOT perturb focus (e.g. restore
via the proven AttachThreadInput path rather than minimize, and never between the persist
observation points) — run at a higher round count. Until the persist control is stable, neither
"the mitigation works" nor "it does not" is supported, and the product decision stays open.

## The third target class: terminals, measured rather than omitted

G0 line 3 names three classes — browser, terminal, file manager. None was open at census time,
so the terminal was the one the ticked box quietly failed to cover. Measured directly
(`probe-terminal-doors.ps1`, on a `wt.exe` window this script created and closed):

```
cls=CASCADIA_HOSTING_WINDOW_CLASS
classic children: DRAG_BAR_WINDOW_CLASS, DesktopWindowContentBridge, InputSite.WindowClass
  -> children that look like a text surface: 0
UIA descendants: 21; elements carrying an addressable HWND: 2 (both chrome); Document: 0
  tab/button elements all report native=0
```

Windows Terminal is the terminal family but a XAML/Composition host, and it behaves like
`uap-framed`, not like `conhost`: the text surface has **no message door** (no edit-like child
HWND) **and no `Document`/TextPattern element** to write through. Tab and button names came
back localized (`关闭标签页`, `新建标签页`), re-confirming that Name cannot be used to gate
reachability or safety.

This is the sharpest consequence of the verdict for the narrow product: **the target class a
developer would most want driven quietly — a terminal — is precisely the class the neutral
channel cannot reach.** An engine that refuses foreground-raising actions could drive Notepad
and the Explorer shell, and could not type into Windows Terminal. "Runs in parallel for a
well-defined minority of targets" turns out to exclude the flagship use case, which is the kind
of fact that should end a discussion about whether the minority scope is worth building.

## Verdict against the plan's own G0 criterion



The checklist says: 覆盖率预估 → 成本收益判断, and *if the conclusion is "only a minority of
scenarios can run in parallel" → 判死, record under RM-3.* The measured answer is 30% of
windows, concentrated in a handful of classic-tooled apps, with 0% of it discoverable through
UIA's own element metadata. **That is the minority case, so the headline claim as written in R2
is dead**, and continuing to P2 on the premise "drive your own windows while the user keeps
working, generally" would be building the engine around a number this repo measured and
rejected.

What survives is narrower and still honest, and it is a different product: *for targets that
have a message door (classic Win32, WinForms, and Notepad-family editors), drive them with zero
cursor movement and zero foreground change -- verified 6/6 per channel against a 0/6 base rate --
and REFUSE everything else with the reason.* Roughly a third of windows on this particular
machine, and a well-defined minority on any Windows machine dominated by UWP/Chromium toolkits.
Whether that narrow scope is worth building is a product decision, not a measurement, and it
belongs to the owner of the plan rather than to the agent executing it.

## G0 line 1 — external unmet complaints, verified against the live pages

Each was fetched and read; state and date are from the page, not from memory. Two prior
notes in `findings.md` were WRONG and are corrected here rather than carried forward.

| # | title | state | what it actually complains about |
|---|---|---|---|
| 369 | PowerShell tool spawns a visible console window that steals focus (missing CREATE_NO_WINDOW) | closed, fixed via PR #397 | focus stolen + keystrokes lost while an agent session runs |
| 419 | `switch_app()` reports success without verifying the window reached the foreground | closed, fixed via PR #430 | agent believes a focus claim and types into the wrong window |
| 465 | indicator heartbeat stall fails open, so `USER_CONTROL` is reported with no physical input | closed, fixed via PR #535 | trigger is parallel tool calls; **direction is the inverse of focus-stealing** |
| 332 | WatchDog UIA focus listener crashes the MCP server after long uptime | open | server death from `HandleFocusChangedEvent` spam — focus is the TRIGGER, not the harm |
| 595 | **PR, not issue**: keep AI control until the agent releases it or the user takes over | merged | argues the 15s lease drops TOO EARLY ("49 of 131 consecutive pairs…") |

Verbatim, from 369: "With an agent session running many shell calls in a row, this makes the
machine effectively unusable for anything else."
Verbatim, from 419: "the tool asserts the target is focused, so the agent proceeds to send
keystrokes, and they land in whatever window actually holds focus."

**CITABLE for the focus-disturbance complaint: 369 and 419** — the G0 requirement is ≥2, and
that is exactly 2, both about the user's own input being stolen, both real.

Not citable, and why: 465 and 595 are complaints about the *consent gate misfiring*, i.e. the
engine refusing itself, which is evidence that focus contention is the axis this toolkit's
users fight over but NOT evidence that the agent steals the desktop; 332 is a crash bug.
**464 does not exist as a distinct complaint** (it is #465's accidental duplicate, closed as
not planned). **`drscrewdriver/dsh-computer-use` issues #3 and #4 do not exist — the whole
repo 404s**, and the same-named repos under other owners have unrelated #3/#4. That citation
was in my own notes and it was fabricated; six candidate repos were checked one by one and
none is a substitute. Deleting it is the fix, not re-attributing it.

One honest reading of the two citable issues: both describe a *window the tool itself opened*
taking the foreground (a console flash; an unverified `switch_app`), and BOTH ARE FIXED
upstream. So the specific complaint R2 was written to answer has been answered in the shipped
baseline, which raises rather than lowers the bar for this project: the remaining unserved
complaint is the one in #465/#595 — a gate that cannot tell agent input from user input — and
that is exactly what the sampler-based attribution in this repo does differently.

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

## 目标改写：R2 → R2′（2026-11-19，计划所有者决定）

G0 判死的是 R2 的「不可见」半；计划所有者明确**接受秒级抢前台**后，可测靶子改为
**有界干扰 + 自我逆转 + 可拒绝**（spec.md §R2′，12 条 + G0′ 5 项门禁）。要点：

- 通道优先级维持实测结论并**倒转**：有消息门只用消息（抢前台 0/6、效果 6/6、光标 0px）；
  无门才用 UIA，且必须计入「显著干扰档」并触发恢复。
- 「光标零位移」保留为绝对断言（全通道 0px，从未被推翻）。
- 恢复必须按 **HWND** 而非 pid（本机实测 `ApplicationFrameHost` 持有每个 UWP 框架，pid 归因两头都错）。
- 恢复只在「当前前台 == 本次抬起的那个窗」时执行；被第三方抢走不动。这一条把「不抢主人新窗」
  做成构造性质，而不是靠祈祷。
- **对话框例外**：新前台与目标同 pid ⇒ 应用自己的对话框 ⇒ 不恢复，否则会把 AI 刚打开的
  「另存为」废掉（框在但打不了字）。
- **不做永久守护**：实测恢复后 3s 仍守住 7/10，丢掉的 3 次是别窗合法抢走；硬守会与主人抢。

G0′ 未全过（尤其 G0′-1 归因稳定性）之前，P2 起仍禁止写引擎代码——与 G0 同一规则。

**竞品对照（本次核实）**：`dongcaodeliyu/dsh-independent-input`（26★）主张「不抢输入焦点」但
**未实现**——无焦点表/无恢复/无 `AttachThreadInput`，`FocusWindow`（Alt 技巧+采集 prev）与
`Set-UiaFocus` 都是从未被调用的死代码，实际点击走实测 6/6 抬前台的 UIA pattern。
⇒ 「焦点表 + 恢复 + 对话框判据」在公开插件里没有对应物，R2′ 的差异化独立成立。
另 `mini-yifan/dsh-orb`（320★）走 `SendInput` 物理注入且主动抢前台，不主张并行，与本路线不冲突。

