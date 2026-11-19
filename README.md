# dsh-windows-parallel-mcp

> **0.1.0 — first usable package.** The name was reserved earlier under a weaker claim; the claim
> below is the measured one. See [What measurement established](#what-measurement-established) for
> what did **not** survive.

A DSH plugin that lets an agent drive **its own** Windows windows without moving your cursor. Where
a window accepts a window message, you never lose focus at all. Where it only exposes UI Automation,
you lose focus for one bounded flash that is reversed automatically. Everywhere else it refuses, with
a code and a reason.

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
  0 foreground changes in 6 of 6 rounds, effect verified by the app's own state, cursor moved 0 px.
- **bounded-flash tier** — only UI Automation can reach the control, which raises the target. The
  engine records the focus table *before* acting, reverses it **once** afterwards, and never pulls
  focus from a window you chose. Measured net return **15–95 ms** from three independent
  measurements (the 120 ms budget was never approached).

Refusals are a normal result, not an error: `no_hwnd`, `paused`, `elevated_target`, `unreachable`,
`terminal_no_door`, `needs_facts`, `action_failed`, `restore_failed`. Each carries a reason and a
next step — see [docs/refusals.md](docs/refusals.md).

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

An elevated window's restore-failure path is **wired but not yet measured on a real elevated
target**; `elevated_target` is a declared-but-unwired detection branch (a wrong integrity check
would be worse than none). Both are stated in [docs/refusals.md](docs/refusals.md) rather than
claimed as supported.

## License

MIT
