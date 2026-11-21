# dsh-windows-parallel-mcp

> **0.1.6 — a refusal now says which world it saw.** `unreachable` used to cover two failures with
> different fixes: a tree that holds no content at all (the application has UI Automation off;
> nothing to re-query for — which is why the engine never retries) is now `uia_tree_empty`, and a
> probe that threw before it could measure (no conclusion about the target is licensed; the
> exception text rides the reason) is now `uia_probe_failed`. 0.1.5 made a click act on the point
> it names; 0.1.3 added `effect=` — who reported the success — and let it enter the judgment, so a
> call that accomplished nothing can no longer read as `proof=pass`; 0.1.2 added the proof chain
> (`proof=`, `proofDimensions`, measured against the desktop around your own call); 0.1.1 is
> 0.1.0's behaviour with a corrected packaging chain. Full history: [CHANGELOG.md](CHANGELOG.md).

A DSH plugin that lets an agent drive **its own** Windows windows without moving your cursor. Where
a window accepts a window message, you never lose focus at all. Where it only exposes UI Automation,
you lose focus for one bounded flash that is reversed automatically. Everywhere else it refuses, with
a code and a reason.

Source, the measurement scripts behind every number below, and the release history live at
**<https://github.com/drscrewdriver/dsh-windows-parallel-mcp>** — issues are the right place for
"this target refused and I think it should not have".

Not affiliated with `dsh-windows-mcp`. Different plugin, different trade-off: that one is a carrier
bundle with a broad tool surface; this one is a single action tool whose entire design is about
*not* disturbing the desktop.

## What it does

One tool, five actions:

| action | what it returns |
|---|---|
| `windows` | live windows that can be driven: hwnd, title, class, pid, rect |
| `status` | what currently holds the foreground and the keyboard focus, and whether the engine is paused |
| `click` | click at a screen coordinate inside the named window |
| `type` | write text into the target (a classic edit child, or a named UIA element) |
| `focus` | move keyboard focus to a named control inside the target |

The engine picks the cheapest available door per call:

- **quiet tier** — a classic child window receives the click/text as a window message. Measured:
  0 foreground changes in 6 of 6 rounds, cursor moved 0 px. (Those 6 rounds also read the target
  app's own state to confirm the click landed — that was a *separate* experiment, not the `effect=`
  field, which says only who reported the call returned; see the table below.)
- **bounded-flash tier** — only UI Automation can reach the control, which raises the target. The
  engine records the focus table *before* acting, reverses it **once** afterwards, and never pulls
  focus from a window you chose. Measured net return **15–95 ms** from three independent
  measurements (the 120 ms budget was never approached).

## What you see while it works

After a successful `click` a small marker is placed at the point that was clicked. It is a
click-through, always-on-top window with `WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT`:
measured that `Show()` does not change `GetForegroundWindow`, that `WindowFromPoint` at the marker's
centre returns the window *underneath*, and that a real click through the shipped plugin puts the
marker over the point it hit (physical pixels; the process declares DPI awareness, because using
WPF's device-independent units put the marker at half scale on a 150% display). It hides itself
1.5 s after the last placement. Cost: ~19 ms per placement, fired after the action has already
answered; the first action pays a one-time ~875 ms while the overlay starts.

**The pause key is not a fixed key.** `Ctrl+Alt+Q` is the first candidate, but it can already be
owned by another app — on the machine this was measured on it was (Win32 1409), and seven of the
other eight measured candidates were free. The engine walks a candidate list, registers the first
free chord, and **reports what it actually registered** in `status` as `pauseHotkey=...`. It never
silently claims the documented key works. `overlay=true` in settings controls the marker; the pause
flag itself is engine-side and refuses actions with `paused`.

Refusals are a normal result, not an error: `no_hwnd`, `paused`, `elevated_target`, `unreachable`,
`uia_tree_empty`, `uia_probe_failed`, `terminal_no_door`, `needs_facts`, `action_failed`,
`restore_failed`. Each carries a reason and a next step — see [docs/refusals.md](docs/refusals.md).

**Every real click carries its own disturbance proof.** `click` returns a `proof=pass|inconclusive|…`
verdict plus a `proofDimensions` field (cursor / foreground / focus). Around your call the engine
samples cursor position, foreground window, keyboard focus and last-physical-input age — in a short
pre-action control window (when, by construction, nothing was running) and inside the settle wait it
already pays. The judgment is one pure function (`lib/proof-window.mjs`, unit-tested against 40
synthetic windows whose answers are known by construction). What it honestly can and cannot say:
a switch of foreground on a quiet tier fails — the control shows the desktop was not doing it, so it
is the action's to explain; a cursor jump is *reported*, never accused, because with nothing running
this desktop's cursor showed multi-gap unexplained motion on its own (a re-runnable probe ships:
`scripts/idle-baseline.mjs`). The cursor promise therefore lives where blame is decidable: a build
gate asserts no shipped file contains `SetCursorPos`/`SendInput`/`mouse_event`/`keybd_event`, so a
regression that adds cursor control fails at build time with certainty instead of being hunted at
runtime among ambient motion.

**And it says who reported the success.** Every action result carries `effect=` in the text and
`effect` in the structured output. The three values are not degrees of confidence in the
application — they name the speaker:

| `effect` | who is speaking | it proves | it does **not** prove |
|---|---|---|---|
| `unverified` | nobody | nothing | anything |
| `reported-by-send` | the window-message channel | the message was **delivered** | that the target app processed it |
| `reported-by-pattern` | the UI Automation pattern call | the call **returned** without throwing | that the interface actually changed |

Since 0.1.3 the effect also enters the judgment, which closes the one honest gap 0.1.2 still had:
a still desktop could outvote a total no-op. A call whose channel reported nothing is capped at
`inconclusive` — never `pass`. A batch caller that passes its per-attempt results (`actions`) gets
`fail` when **no** attempt took effect, however few pixels moved. Displacement proves we did not
disturb you; it never proves we accomplished anything. A single `reported-by-*` stays a `pass` with
the caveat spelled out in the reason field (`未独立验证` — nobody observed the app), because turning
weak-but-real evidence into a red would train its readers to ignore the verdict.

## What it does not do

- **No synthetic input.** There is no `physical` option: it is absent from the schema, not disabled
  by default. No `SendInput`, no `keybd_event`, no `mouse_event`.
- **No forged-Alt foreground trick.** That route works and other plugins use it, but it injects a
  real key event — a keystroke you make in that window can land in whichever window the trick just
  raised.
- **No OCR / Set-of-Marks / pixel fallback.** Not part of this claim, and already done well elsewhere.
- **No watchdog.** The restore is one-shot and happens inline. A watchdog that keeps chasing the
  foreground would fight you.
- **Terminals are refused** (`terminal_no_door`): their text surface exposes neither a child window
  nor a `Document` element. That is the target a developer most wants driven quietly, and it is the
  one that cannot be.

## Install

```bash
dsh plugin --profile <profile> add dsh-windows-parallel-mcp
```

Requires Windows with Windows PowerShell 5.1 (it ships with Windows) — **no Python, no uv, no MSVC
runtime, no native module**. The engine is a PowerShell sidecar started lazily on the first tool
call, not at plugin load.

`engines.dsh` is an explicit two-sided range. There is no runtime version probing and no silent
degradation.

## Settings

| key | default | effect |
|---|---|---|
| `enabled` | `true` | server-side gate: when off, every action refuses with `paused` before the engine is reached |
| `settleMs` | `350` | how long the app gets to commit state before the effect is judged |
| `requestTimeoutMs` | `20000` | a worker that stops answering is killed and restarted on the next call |
| `powershellPath` | `""` | override the interpreter (pwsh accepted) |
| `logWorkerStderr` | `false` | forward worker diagnostics to the host log |

## What measurement established

The hard gate was run on a real Windows desktop before any of this shipped, and part of the original
goal statement did not survive it. Kept here rather than quietly dropped:

- **Cursor: true.** Every channel tested produced 0 px of cursor displacement across 24 action
  rounds, against a control arm that made no call.
- **"Keyboard focus never changes": false as a general property.** UIA pattern actions raised their
  own target in 12/12 and 6/6 rounds with no mouse button down, no modifier key down and the cursor
  outside the target rect; a no-call control arm raised 0/6 in the same conditions.
- **Window messages: true but narrow.** 6/6 effective, 0/6 raising. But a message needs an
  *address*: only 17 of 57 live windows here have one, and the two largest families (UWP/WinUI,
  Chromium/Electron) have none.
- **The complementary-exclusive catch:** on the toolkit where messages work (WinForms/classic),
  UIA exposes no patterns at all; on the toolkits where UIA works (WPF/UWP/Chromium), there is no
  message door. The identifiable door and the quiet door are never on the same window.
- **Restoration is measured, not assumed.** After a raise, the widget that held focus came back
  6/6 and 6/6 in two independent runs, and internal focus (not just the window) returned 4/4.
- **The engine is often quieter than the budget suggests.** Under its real operating condition,
  UIA `Invoke` was foreground-neutral in 0 of 12 rounds — the earlier 6/6 and 12/12 were measured
  under a construction that first took the foreground away. The flash tier is a fuse, not a promise
  of disturbance.
- **An empty accessibility tree is a switch, not a delay.** The alternative reading — Chromium
  activates renderer accessibility on demand, so the tree might be merely slow — was tested, not
  assumed away: the same window was re-read in place three times (+0/+700/+1500 ms,
  `scripts/uia-tree-content.ps1`). uTools read **0/0/0** descendants, zero interactive content
  elements every time (one earlier peek the same day saw a single `Chrome Legacy Window` shell
  pane appear, content still 0); DSH on the same desktop read a real tree on the **first** query
  (514 at census time, 1019 raw / 85 content on re-read). Nothing ever trickled in. So the
  engine refuses with `uia_tree_empty` and does **not** poll — there is nothing to wait for — and
  the actual switch is a launch-time state (`--force-renderer-accessibility`) the engine cannot
  impose on a browser the user already has open. `unreachable` is the other world: the tree is
  alive and offers nothing at the named point or element.

`elevated_target` is measured live: the engine compares the target's integrity RID against its own
and refuses before acting (verified on an elevated Task Manager; 19 medium windows, zero
misrefusals). The **restore-failure path on an elevated target** (`restore_failed`) remains
unmeasured end-to-end and is stated as such in [docs/refusals.md](docs/refusals.md).

## License

MIT
