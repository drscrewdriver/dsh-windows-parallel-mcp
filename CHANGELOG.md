# Changelog

Dates are the registry `time` values for each version, not git commit dates — a commit date records
when someone typed, a publish time records when a version became installable, and only the second
one is a promise to anyone installing it.

## 0.1.2 — 2026-11-20

(Registry time `2026-11-20T17:15:15Z` UTC = `2026-11-21 01:15` Beijing; the date follows the same
UTC convention as the entries below, because the header's rule is "the publish time is the promise".)

The proof chain became real: what started as "the README says the cursor never moves" ended as a
per-call measurement, a build-time guarantee, and — recorded honestly — three judgment designs that
the real desktop rejected before one survived.

**Added**
- Every `click` carries a disturbance proof: `proof=pass|inconclusive|fail|insufficient(…)` in the
  text plus structured `proof` / `proofDimensions`. The engine samples cursor/foreground/focus/
  last-physical-input-age in two windows — a pre-action control (nothing running, by construction)
  and inside the settle wait it already pays; four read-only syscalls, no new process.
- `lib/proof-window.mjs` — the one pure implementation of the judgment. `sampler.mjs` delegates to
  it too: the fleet reachability numbers and the per-action proof cannot drift into two instruments
  sharing one name. 32 synthetic unit arms pin the semantics, including cases that must FAIL —
  a verdict function that only ever says pass is worthless, and the arms check it can say otherwise.
- `scripts/check-no-cursor-control.mjs` — build gate: no shipped engine file may contain
  `SetCursorPos` / `SendInput` / `mouse_event` / `keybd_event`. Verified non-vacuous (injecting
  SetCursorPos turns it red; removing it turns it green, no residue).
- `scripts/idle-baseline.mjs` — re-runnable probe of what the cursor does with NOTHING running.
  Measured answer on the authoring machine: up to 3 unexplained gaps / 11 px. This is why the
  runtime cursor dimension reports and never accuses.
- Marker placement through the shipped plugin is verified end-to-end against an independent oracle:
  a real click puts the marker over the point it hit in physical pixels, and the marker is proven
  (via `EnumWindows`) topmost-over-the-target while `GetForegroundWindow` stays unchanged.

**Corrected**
- The cursor guarantee was MEASURED OUT of the runtime sensor and INTO the build gate. Two runtime
  rules failed on clean clicks (a strict 1 px bar: 3.16 px; a control-window noise floor: 7.07 px,
  the floor itself duration-biased). Positions cannot attribute motion to a cause; the idle baseline
  proves even multi-gap motion is ambient on a live desktop. Tuning the number until reds disappear
  would have been laundering, so the rule changed shape instead: zero unexplained gaps passes,
  anything else is inconclusive with the number surfaced, and the actual promise (no cursor control
  exists in the shipped code) is decidable at build time.
- The disturbance sensor no longer contradicts the product contract: the bounded-flash tier raises
  foreground deliberately and restores it; those switches are reported as `declared`, not failed.
  ("Never KEEP the foreground" is owned by the restore table — `restore_failed` — not by sampling.)
  A pass verdict can no longer print "no switches" while carrying declared ones.
- Overlay cold-start wait raised to 6 s: the runspace JITs WPF past the old 2.5 s budget on a cold
  worker, and the caller read a false "overlay not running".
- Gate philosophy for occluded desktops, applied to a TOCTOU case (a fullscreen video window moving
  over the point between premise-probe and click): the engine's refusal is correct behaviour, so the
  arms re-probe and convert to a NAMED SKIP. Desktop the test doesn't control never reads as red;
  and a silent skip never reads as tested either.
- A real product bug in the marker path, caught by the gate going red intermittently (and fixed at
  the cause, not the symptom): the overlay's readiness handshake **polled one flag and judged
  another**. It waited for `OverlayHwnd` — assigned right after `Show()`, before the ex-style trio
  is applied — but reported `running = OverlayOn`, set only after trio + hotkey + pump. So during
  that window `status` said "not running" about an overlay that was initialising, AND read back a
  half-styled window (`exStyle=0x00080008`, TOPMOST|LAYERED but NO TRANSPARENT — WPF's own bits
  before the explicit trio lands). The Node half's fire-and-forget `markPoint` sequenced placement
  behind the handshake; the handshake rejected; the marker request was skipped for a click that had
  already answered, so nobody ever retried and the marker stayed parked at (-2000,-2000). One
  warning, then silence forever. That was not a flake to be slept past:
  the readiness flag is now the judgment flag (`OverlayOn`), a budget that merely expired reports a
  third state (`starting`) instead of masquerading as a crash, and placement retries on a bounded
  6 s deadline that stops immediately when the start is *provably* dead (a reason + not starting).
  Patience lives where a stop condition can be named — the worker-side sleep cannot.

**Verified for this version**
- 12-arm gate green; live clicks through the SHIPPED plugin: proof=pass across 18–22 sample gaps
  with `[cursor=pass fg=pass focus=pass]`; four-run stability: 3 pass + 1 ambient inconclusive
  surfaced as WARN (anti-vacuity: weaker-than-pass never prints as INFO).
- The independent marker oracle now ANCHORS on the overlay handle the product reports via
  `status` (`overlayHwnd=...`). Matching by title alone could grade a leaked same-titled window from
  an earlier run — certifying a marker we never placed; more than one candidate is now reported as
  ambiguous rather than silently resolved to `$hits[0]`.
- `lib/proof-window.mjs` confirmed inside the tarball (20 entries).



## 0.1.1 — 2026-11-20

The same product as 0.1.0. This version exists to fix the packaging chain, not the behaviour.

**Changed**
- Repository line endings normalised to LF. 0.1.0 was published from a tree where an editing script
  had converted ten files to CRLF, so the registry tarball (sha256 `84196f21…`) and this repository
  no longer hashed the same even though the code was identical. 0.1.1 restores "the repository and
  the published artifact are the same bytes".
- `publishConfig` is now explicit: `{ "access": "public", "tag": "latest" }`. The default was
  already `latest`, but a default is a property of npm while a declaration is a property of this
  package — the difference only shows up the first time someone publishes a prerelease.

**Verified for this version**
- 11 local gates green: PowerShell parse / encoding / static-call, refusal vocabulary, tool schema,
  package contents, host half + sidecar, overlay promises, marker end-to-end, JS syntax.
- The overlay marker is measurably click-through: `exStyle 0x08080028`, foreground unchanged across
  `Show()`, an independent process confirming `WindowFromPoint` at the marker's centre returns the
  window underneath, and the marker covering the clicked point in physical pixels.
- The pause chord is measured, not assumed: `Ctrl+Alt+Q` is a first candidate, and on the machine
  this was built on it was owned by another app (Win32 1409), so the engine walked a candidate list
  and registered `Ctrl+Alt+W`. `status` reports the chord that actually registered.

**Not fixed in this version** (unchanged from 0.1.0, stated rather than implied)
- The settings pill and the four-value switch surface do not exist yet.
- `restore_failed` has no end-to-end test: it needs an elevated window that can be raised, and no
  such window was present at build time. The decision-table branch is covered by unit tests; the
  live path is not.

## 0.1.0 — 2026-11-20

First version with a working plugin in it. Everything before this was a reservation stub.

- One tool, `wpm`, with five actions: `windows`, `status`, `click`, `type`, `focus`.
- A PowerShell sidecar (Windows PowerShell 5.1, nothing to install) driven over a JSON line protocol,
  lazily started so the host's boot path does not pay for a tool nobody called.
- Eight refusal codes as a three-way contract: what fires, what the schema promises, what the docs
  explain. A gate fails when the three disagree.
- A click-through, always-on-top marker placed at the point a click hit, and a global pause chord.
- Measured: window-message tier causes 0 foreground changes in 6/6 rounds with 0 px cursor movement;
  the UI Automation tier's focus takeover returns in 15–95 ms net against a 120 ms budget.

## 0.0.1 — 2026-11-18

Reservation stub. The name was reserved before the measurement was done; installing this version
gives you a README and nothing else. Kept for history, not for use.

## 0.0.0-stage — 2026-11-18

The first reservation, same story as 0.0.1.
