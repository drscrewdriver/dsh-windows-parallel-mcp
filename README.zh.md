# dsh-windows-parallel-mcp

[English](README.md) · **中文** · [日本語](README.ja.md) · [한국어](README.ko.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [Italiano](README.it.md) · [Español](README.es.md) · [Português](README.pt.md) · [Русский](README.ru.md)

> 一个让代理驱动**自己**的 Windows 窗口的 DSH 插件——默认静默，按需可见。窗口接受窗口消息时完全不夺焦点；只有 UI Automation 可达时，焦点仅发生一次有界闪烁并自动还原；显式请求接管档时，光标移动到目标点并始终还原，HUD 提供三种中断方式。其他情况一律拒绝，并给出代码与原因。

> **English canonical text follows.** The localized summary above is the orientation; the text below is the authoritative specification (structure, commands and numbers are identical across all 10 languages).
> **Current release: 0.5.0** — this document describes the contract as of that version. What
> changed in it, and in every version before it, is in [CHANGELOG.md](CHANGELOG.md), newest first.

A DSH plugin that lets an agent drive **its own** Windows windows — quietly by default, and visibly
on request. Where a window accepts a window message, you never lose focus at all. Where it only
exposes UI Automation, you lose focus for one bounded flash that is reversed automatically. Where you
explicitly ask for the takeover tier, the cursor moves to the point and is always restored, with a
HUD that can stop it three ways. Everywhere else it refuses, with a code and a reason — never with
silence: every refusal carries a code from a closed set of fourteen and the next step.

**The takeover tier defaults off, and that is structural.** The cursor is only ever moved because you
opened `takeoverAllowed` **and** asked for it on the call (`takeover:true`), so an upgrade cannot
start moving your cursor by itself. Keyboard injection lives inside that tier only, only when asked
(`keyInput:"inject"`), and only for targets with no other door — and, measured, it does **not** work
on this host's terminal, so the terminal stays refused rather than becoming a promise.

Source, the measurement scripts behind every number below, and the release history live at
**<https://github.com/drscrewdriver/dsh-windows-parallel-mcp>** — issues are the right place for
"this target refused and I think it should not have".

Not affiliated with `dsh-windows-mcp`. Different plugin, different trade-off: that one is a carrier
bundle with a broad tool surface; this one is a single action tool whose entire design is about
*not* disturbing the desktop.

## What it does

One tool, eight actions:

| action | what it returns |
|---|---|
| `windows` | live windows that can be driven: hwnd, title, class, pid, rect |
| `status` | what currently holds the foreground and the keyboard focus, and whether the engine is paused |
| `click` | click at a screen coordinate inside the named window, or at a snapshot `label` |
| `type` | write text into the target (a classic edit child, a named UIA element, or a `label`) |
| `focus` | move keyboard focus to a named control inside the target, or to a `label` |
| `snapshot` | the accessibility tree as a NUMBERED element table: continuous `label`, control type, name, automation id, screen rect, patterns |
| `screenshot` | the window rect captured to a PNG, plus the coordinate mapping as data (`screenRect`, `imageSize`, `scale`, `identity`, `frame`, `dpiAware`) |
| `preview` | the marker drawn at a point, and the element under it reported as TEXT — no picture needed |

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
`uia_tree_empty`, `uia_probe_failed`, `terminal_no_door`, `needs_facts`, `takeover_unavailable`,
`keyinject_unavailable`, `action_failed`, `restore_failed`, `takeover_aborted`, `stale_ref`. Each
carries a reason and a next step — see [docs/refusals.md](docs/refusals.md).

## Reading the frame instead of guessing

The three read actions exist so the two halves of a click — *where the thing is* and *where the
picture is* — stop being the caller's arithmetic.

`label` is not a coordinate in disguise. It is resolved back to the UIA **element** by its runtime id
(measured stable across queries, 71 of 71), so `click`/`type`/`focus` with `label` + `snapId` still
take the silent pattern path. A labelled `click` keeps `x`/`y` required, and the point must fall
inside the labelled element's rect — the point stays the contract. A label whose `snapId` was
superseded is refused with `stale_ref`: element numbers only mean something in the frame that printed
them.

Image coordinates are never multiplied by the caller:

```jsonc
{"action":"screenshot","hwnd":"1310720"}
// -> screenRect=0,0,1920,1032 imageSize=1920x1032 scale=1 identity=true frame=dwm
{"action":"click","hwnd":"1310720","space":"image","shotId":"shot-…","x":350,"y":250}
// the ENGINE converts, then still asserts the point belongs to the target window
```

The picture is not returned inline — a plugin cannot mint an inline image block without the host's
attachment service — so the PNG is written to `%LOCALAPPDATA%\wpm\shots\` (newest `shotsKeep` kept)
and read with the host's image reader. `preview` is the cheaper confirmation: it draws the marker at
the point and answers, as text, which element the OS says is there. Confirming a point therefore
never depends on looking at a picture, and a preview writes no input-queue entry, takes no focus and
produces no proof window.

### The frame rule, and why 8px mattered

One rectangle decides everything: `DwmGetWindowAttribute(EXTENDED_FRAME_BOUNDS)`. Measured here,
`GetWindowRect` is **8px larger on every edge** — the invisible resize shadow — and the accessibility
tree mixes the two spaces: its root element reports the shadow-inclusive rect while its children
report the real one, so arithmetic that mixes them is 8px wrong and *looks right*. Labels and the
captured picture therefore come from the same function. When DWM is unavailable (RDP, Basic theme)
the fallback to `GetWindowRect` is **reported** as `frame=win32` rather than swallowed, and
`frameInset` prints the shadow width as data.

The plan for this release proposed a runtime invariant — "every element rect is inside `screenRect`" —
and measurement refuted it: real Chromium/Electron trees report virtualized content far outside the
viewport (overhangs of 3px, 18px, 287px and 2720px measured here). What replaced it: elements that do
not overlap the capture are **excluded and counted** (`outsideFrame=…`, because a number you cannot
point at would be a trap), the frame is cross-checked against the window rect the tree itself reports
(`frameCheck=pass|fail|unknown`), and a structural gate pins the single-source rule by mutating a copy
of the engine and requiring the corresponding red.

### Deciding outside the main context

The expensive habit this replaces is re-reading a 70-row table on every step. Hand the frame to a
clean deciding side and take back one number:

1. `snapshot` with `intent:"close the settings dialog"` — the intent travels with the frame, and is
   written to `%LOCALAPPDATA%\wpm\last-snapshot.json`;
2. give the numbered table and the intent to a clean subagent;
3. it answers with a single `label` — not a selector, not a coordinate;
4. click with that `label` + `snapId`.

`sinceSnapId` serves the same goal: an unchanged tree answers `no changes since <id>` instead of
repeating itself, and a delta names only what actually moved (`added` / `removed` / `changed`, keyed
by runtime id).

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
gate confines `SetCursorPos` to `takeover.ps1` and `SendInput` to `input-inject.ps1`, bans
`MOUSEEVENTF_*`/`mouse_event`/`keybd_event` everywhere, and a second gate asserts the structural
promises around them (the HUD is checked before any primitive runs; the cursor move and its restore
share one `try/finally`). A regression fails at build time with certainty instead of being hunted at
runtime among ambient motion. In the takeover tier the cursor motion is **declared**, so it is
reported rather than accused — but `cursorRestored=false` (borrowed and not returned) is a hard
`proof=fail`.

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

## The takeover tier (opt-in)

Off by default (`takeoverAllowed=false`, `keyInjectAllowed=false`), because moving someone's pointer
is not something an upgrade should switch on. When you turn it on and pass `takeover:true`:

1. **arming** — **amber** HUD (`#3A2C0C` surface, `#F0AD18` accent bar). Says what is about to be
   borrowed (cursor / keyboard / focus), with the interrupt key that actually registered. Default
   800 ms; this is the cancellation window.
2. **active** — **red** HUD (`#3A1212` / `#E84040`). The cursor is placed on the action point, the
   action runs through the cheapest existing door, and the HUD counts elapsed/limit and characters
   injected.
3. **done** — **green** HUD (`#0E2E1E` / `#34C77B`). The cursor is restored (read-back verified), the
   focus is returned through the same one-shot table, and the HUD says so.

The colour is not decoration: while an agent borrows the pointer the owner is looking at the *target*
window, so the phase is encoded twice — the whole surface tint **and** a 5px accent bar — and
`test/hud-test.ps1` reads the real pixels to assert the three are distinct (C18). Amber = not yet
(cancellable), red = holding something of yours right now, green = returned.

**The keys, which are easy to mix up:**

| | key |
|---|---|
| interrupt the running takeover | **`Ctrl+Alt+X`** (the one that registered; candidates `X→Z→C→V→B→N` then `Ctrl+Shift+X`, displayed as `abortChord=`) |
| same thing, no keyboard | the HUD's 取消 / 停止 button (same flag, no priority) |
| pause the whole engine (also aborts a running takeover) | **`Ctrl+Alt+Q`**, here **`Ctrl+Alt+W`** because another app owns Q; `status` reports `pauseHotkey=` |

The abort chord lives only while the HUD exists (its window owns the registration); the pause key is a
permanent server-side switch. Three interruption paths, all writing the same flag/file: HUD button,
abort chord, and the host's cancellation (`exec.signal` → a latch file the engine polls, because the
worker is single-threaded and cannot read a request while an action is running). Interruption returns
`takeover_aborted` **with** `cursorRestored` and `injectedChars` — it is not a fault, it is the feature.

Keyboard injection (`keyInput:"inject"`) exists only inside this tier, because `SendInput` writes to
the **foreground** window: measured, text sent while another window was in front landed in that
window and not in the intended one. The engine therefore asserts `GetForegroundWindow() == target`
before sending, re-asserts at send time, and refuses with `keyinject_unavailable` otherwise. It never
injects mouse events — `MOUSEEVENTF_*` is banned repo-wide, so the module is structurally unable to
click. Success is reported as `effect=reported-by-send`, never as "verified". Unicode injection
carries no hardware scancode, which is why a rare scancode-only target would ignore it — documented,
not a bug.

## What it does not do

- **No mouse injection.** `MOUSEEVENTF_*`, `mouse_event` and `keybd_event` are banned in every
  shipped file. The takeover tier moves the cursor instead of clicking synthetically — that is why
  "the agent can type into the foreground" does not become "the agent can click anything".
- **No takeover without the HUD.** `takeover_unavailable` is a refusal, not a warning, and the
  request is never downgraded silently into the quiet tier.
- **No forged-Alt foreground trick.** That route works and other plugins use it, but it injects a
  real key event — a keystroke you make in that window can land in whichever window the trick just
  raised.
- **No OCR / Set-of-Marks / pixel fallback.** Not part of this claim, and already done well elsewhere.
- **No watchdog.** The restore is one-shot and happens inline. A watchdog that keeps chasing the
  foreground would fight you.
- **Terminals are still refused** (`terminal_no_door`), and now for a measured reason. The 0.2.0 plan
  was to drive one by typing into it; two probes say otherwise on this host: 242 `KEYEVENTF_UNICODE`
  events with the terminal in the foreground and Enter sent produced nothing, and a scan-code arm
  (262 events, layout-correct) produced nothing either. Their text surface also exposes no writable
  child and no `Document` element. The code stays, the reason names what does work (a target with a
  real door), and the claim is withdrawn rather than shipped as a promise.

## Install

```bash
dsh plugin --profile <profile> add dsh-windows-parallel-mcp
```

Requires Windows with Windows PowerShell 5.1 (it ships with Windows) — **no Python, no uv, no MSVC
runtime, no native module**. The engine is a PowerShell sidecar started lazily on the first tool
call, not at plugin load.

`engines.dsh` is an explicit two-sided range. There is no runtime version probing and no silent
degradation.

## Typed surface

`types/index.d.ts` is written by hand, not emitted from an implementation. It covers the whole
contract: the eight actions, every argument including the takeover fields and the image-space /
label surface, and all fourteen refusal codes as a closed union.

Its wiring is measured in both resolution modes a consumer can use, rather than assumed from the
presence of a file:

- a `nodenext` consumer resolves it through the `types` condition inside `exports`. That condition is
  load-bearing: delete it and the same consumer fails with `TS7016`, because once `exports` exists it
  is the only entry point and the legacy field below is never consulted;
- a classic resolver falls back to the top-level `types` field. Delete `exports` entirely and the
  consumer still type-checks.

Neither field is decoration, so neither is removable on the assumption that the other covers it.

The declarations are also checked against the implementation, in the direction that catches drift:
`lib/` is type-checked under `allowJs + checkJs + strict` **against those same declarations**, so
renaming a field in one without the other fails a repo gate instead of a user's build. This stays
inside the package's zero-install-dependency promise — the compiler is borrowed from the workspace
when one is present, and the gate reports a named SKIP rather than a red when one is not.

## Settings

| key | default | effect |
|---|---|---|
| `enabled` | `true` | server-side gate: when off, every action refuses with `paused` before the engine is reached |
| `settleMs` | `350` | how long the app gets to commit state before the effect is judged |
| `requestTimeoutMs` | `20000` | a worker that stops answering is killed and restarted on the next call |
| `powershellPath` | `""` | override the interpreter (pwsh accepted) |
| `logWorkerStderr` | `false` | forward worker diagnostics to the host log |
| `takeoverAllowed` | `false` | allow `takeover:true`: cursor may move (always restored), focus held, HUD mandatory |
| `keyInjectAllowed` | `false` | allow `keyInput:"inject"` inside the takeover tier (keyboard only, foreground asserted) |
| `takeoverMaxMs` | `10000` | hard ceiling for one takeover action (500–60000); the HUD shows the clock |
| `takeoverArmMs` | `800` | length of the arming phase: the window in which you can cancel before anything moves |
| `snapshotMaxElements` | `300` | cap on elements per snapshot (1–5000); a tighter cap is a smaller frame for a deciding subagent |
| `screenshotMaxWidth` | `0` | downscale captures to this width; `0` means no scaling and `scale=1` — a resized image is a different coordinate system, so it is never chosen silently |
| `shotsKeep` | `10` | how many PNGs stay in `%LOCALAPPDATA%\wpm\shots`; older files are deleted after each capture |

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

### 0.2.0's four new measurements (all re-runnable from `scripts/`)

- **The cursor can be placed exactly and put back** — `scripts/probe-setcursor-pos.ps1`:
  `SetCursorPos(+40,+20)` read back as exactly the requested point and the restore landed on the
  original point. The elevated-foreground arm could not be arranged (a non-elevated process cannot
  raise Task Manager), so it is recorded as unmeasured rather than guessed — the decision table
  refuses elevated targets before this primitive anyway.
- **Injected characters go to the FOREGROUND window, not to the window you meant** —
  `scripts/probe-sendinput-unicode.ps1`: with window B in front, the text landed in B and window A
  received nothing; the reverse arm (A in front, including Chinese characters) landed in A. That is
  the measurement S1 rests on.
- **The terminal cannot be typed into from here** — `scripts/probe-console-inject.ps1` and
  `scripts/probe-console-scan.ps1`: Unicode and scan-code arms both accepted by `SendInput`, both
  with the terminal in the foreground, neither executed. This is why the terminal claim is withdrawn.
- **A WPF window can be click-through on empty space while its button stays clickable** —
  `scripts/probe-hittest-children.ps1`: the naive `HwndSource` hook received `WM_NCHITTEST` but its
  return value did not reach hit-testing (empty point still answered `HTCLIENT`); a `WNDPROC`
  subclass returning `HTTRANSPARENT` outside the button rect works — measured `-1` on empty space,
  `WindowFromPoint` no longer returning the HUD, and `HTCLIENT` on the button. That is what
  `hud.ps1` ships.

## Verifying the copy you actually installed

Every test above imports the repository checkout, so a package that installs to the wrong place or ships
a stale `lib/` would still pass all of them. `node test/smoke-installed.mjs <path-to-installed-package>`
drives the **installed** copy: it lists a real window, runs a takeover click, asserts
`takeover=on cursorRestored=true abortChord=…`, and checks that the HUD is torn down afterwards. Run once
against the desktop profile after installing, as the last step of a release.

## License

MIT
