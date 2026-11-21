# Changelog

Dates are the registry `time` values for each version, not git commit dates — a commit date records
when someone typed, a publish time records when a version became installable, and only the second
one is a promise to anyone installing it.

## 0.1.6 — 2026-11-21

Two failures that shared one refusal code are split — because the reader's next step differs.

**The defect.** Everything door-less came back `unreachable`. Two of its causes are opposites: a
tree that was never populated (the application has UI Automation off — measured on this desktop:
uTools walks to zero content elements on three in-place reads spanning 2.2 s and never grows one),
and a probe that threw (the tree could not be measured at all). The probe's own diagnostic was
already being produced and then wasted: `uiaErr` reached the result object only as a reason-string
suffix that nothing branched on — 0.1.5's point-probe work found it as dead data. A caller reading
`unreachable` could not tell "pick another target" from "make the app enable accessibility" from
"read the exception".

**Fixed**
- **`uia_tree_empty`** — the walked tree holds **zero content elements**. The criterion is
  structural, not numeric: Pane/Group/Image/Text/Thumb/Separator/TitleBar are the window's own
  shell; anything else (Button, Edit, Document, Custom) is something an application chose to
  expose. Count alone lies — an a11y-off Chromium window still exposes one
  `Chrome_RenderWidgetHostHWND` shell pane, and the same uTools window measured raw=0 and raw=1
  the same day depending on its own state while content stayed 0 throughout. The reason states
  the observation, not an exclusive cause: a provider that answers nothing (a hung pump) reads as
  empty too, instantly, without throwing — that second cause is documented, not hidden.
- **`uia_probe_failed`** — the probe threw before it could measure; no conclusion about the
  target is licensed. The exception text rides the reason as `[uia: …]`. Measured: WM_CLOSE
  landing 40 ms into the call (between the `IsWindow` check and `FromHandle`) returns this code
  with the original exception text, not `unreachable`. Probe failure outranks tree-empty — a
  measurement that threw cannot also certify emptiness — and a usable door outranks both.
- **The refusal reason carries the probe's context for all three codes**: which point was probed
  and what it found there, plus the exception when one exists. A diagnosis with the evidence
  redacted is not a diagnosis.

**Also**
- The reverse assertion about Chromium's "lazy" accessibility is written where the next reader
  will trip over it (`scripts/chromium-a11y-flag.mjs` conclusion, README's measurement section):
  the same window re-read in place three times (+0/+700/+1500 ms) never grew content, an a11y-on
  tree answers completely on the first query — so the engine does NOT re-query with a deadline
  and no retry exists anywhere. The instrument ships:
  `scripts/uia-tree-content.ps1` reads the same two counters with the same shell-type table the
  engine decides on.

Measured instances behind every claim above: real-window end-to-end refusals for all three codes
(`uia_tree_empty` via both the scan and the point path on uTools; `unreachable` on a tree-alive
window; `uia_probe_failed` on a mid-probe destroy), decision-table arms for each new branch and
its precedence, and `refusals-test` 11 passed with 2 codes still declared uncovered
(`action_failed`, `restore_failed`).

## 0.1.5 — 2026-11-21

A click that acted on the wrong control, and returned `ok:true` while doing it.

**The defect.** The contract (`src/schema/tools.json`) makes `x`/`y` **required** for `click` and says
a point that does not resolve inside the target is refused "instead of being sent somewhere else".
The message tier honours that (`Resolve-WpmChildAtPoint`). The **UIA tier did not read `x`/`y` at
all**: it scanned descendants and invoked the FIRST element carrying any usable pattern, then
reported success. On any target without a message door — WPF, UWP, WinUI3, i.e. most modern
applications — `click` at the coordinates of one control operated on a different one entirely, and
the marker was still drawn at the requested point, so the product's own evidence pointed at a place
it had not acted on. This is worse than a refusal: a refusal is honest, this was a wrong action
wearing a success report.

Measured, not inferred. A two-button WPF target at known coordinates, with the click counters
written by the handlers themselves:
- pre-fix engine, click aimed at **Bravo**: `alpha 0->1`, `bravo 0->0`, `last='alpha'`, result `ok:true`
- fixed engine, same call: `bravo 0->1`, `alpha 0->0`, `last='bravo'`, `channel=uia tier=bounded-flash`

**Fixed**
- The UIA tier resolves the element **at the point** (`Resolve-WpmUiaElementAtPoint`,
  `AutomationElement.FromPoint`), climbs to the nearest ancestor carrying a usable pattern, and
  refuses when the point does not belong to the named window. Naming an element with
  `elementName` still takes the by-name path: there the caller asked for that control.
- **Ancestry is proven before the pattern is looked for.** The first version of this fix searched
  while climbing and returned on the first pattern — which reproduced the original defect one level
  down: a point outside the target climbed into the taskbar, found a patterned button there,
  invoked it and answered `ok:true`. Caught by the "point outside the target" arm of the new test,
  not by review.
- `uiaErr` was produced and read by nobody (`grep` found zero consumers), so a walk that *threw*
  reached the caller as "no message door and no usable UIA pattern" — a factual claim that may be
  false. The probe now also carries `uiaReason`, and a refusal appends what the point probe found,
  so `unreachable` no longer collapses two different worlds into one sentence.

**Added**
- `test/uia-click-target.ps1` — a two-button WPF target that publishes its button centres in
  **physical pixels** (the test that computed them itself was 1.5x off; that DPI lesson is written
  into the file) and writes click counts from the handlers that fired.
- `test/uia-click-truth.mjs` — 12 arms, and a new gate (`scripts/check.mjs`, now 13). It fails in
  both directions: point-at-Bravo must bump Bravo and not Alpha; a point outside the target must be
  refused, must fire neither button, and must say *why*.

**Unchanged** — the refusal-code set, the pure judgment, the message tier, the marker.

## 0.1.4 — 2026-11-21

(Registry time is the authority for the timestamp; same convention as below.)

The source became reachable. Until now the package had **no repository, homepage or bugs field** —
not an oversight at authoring time, but a consequence of the repo not existing: there was no URL to
put there. `git remote -v` was empty through 0.1.0–0.1.3, so every claim in the README pointed at a
tarball and nowhere else. Creating the repository is what unblocks this, and it is the only reason
this release exists.

**Added**
- `repository`, `homepage` and `bugs` in `package.json`, so npmjs.com links to the source and to an
  issue tracker instead of leaving a reader with a download and no way to report a refusal that
  should not have happened.
- README now names the repository in its opening section, next to the non-affiliation notice.

**Unchanged**
- No behaviour. `lib/`, `src/engine/` and the schema are byte-identical to 0.1.3 — this release only
  makes the existing artifact findable. The gate is still green (12 checks), and the profile on the
  authoring machine keeps running 0.1.3 code with an identical `lib` hash.

## 0.1.3 — 2026-11-21

(Registry time `2026-11-21T01:20:58Z` UTC (= `2026-11-21 09:20` Beijing; the date follows the same UTC convention as the entries below — the publish time is the promise.)

0.1.2 shipped a proof that answered "did we disturb you". It never answered "did the thing happen" —
the engine computed `effect` on every action call and the Node half dropped it on the floor, so
`proof=pass` could mean *"clicked, and the app ignored it"*. This release closes that link, and then
closes the hole the missing link was hiding.

**Added**
- `effect=` in every action result's text and `effect` in the structured output, with three values
  that name the SPEAKER rather than the confidence: `unverified` (nobody), `reported-by-send` (the
  message was delivered), `reported-by-pattern` (the UIA call returned). README carries the table;
  the code comment above the branch pins the same three lines. A refusal reports no effect at all —
  no action ran, so nobody can have spoken.
- `lib/proof-window.mjs` gains an effect dimension: `evaluateProof(samples, { effect, actions })`.
  A call whose channel reported nothing is capped at `inconclusive`; a batch caller whose every
  attempt failed gets `fail` regardless of displacement. Both are opt-in — omitting `effect` leaves
  every pre-0.1.3 caller's behaviour untouched, which is why the 32 pre-existing arms did not move.

**Corrected**
- The gate could read a total no-op as a green light: zero cursor displacement, zero foreground
  switches, nothing accomplished => `pass`. The old plan named the case ("50 failed calls, zero
  displacement, FAIL") and never landed it. It is landed now, with the arms that fail in the
  direction that matters: `unverified` + a still desktop is not a pass, and 50 failed attempts is a
  `fail` whose reason says 动作未生效.
- Word boundaries: `reported-by-send` says the message was DELIVERED. It does not say the application
  processed it, and `reported-by-pattern` does not say the interface changed. Single `reported-by-*`
  evidence still passes (it is real, just not independent) and the reason says so out loud: 未独立验证.

**Verified**
- `node test/proof-window-test.mjs` — 40 arms, 0 failed (32 carried over unchanged, 8 new).
- `node test/plugin-test.mjs` — 54 arms, 0 failed, including a real `no_hwnd` refusal carrying no
  effect and the three legal values round-tripping through the shipped projection.
- `node scripts/check.mjs` — 12 gates green, including the marker end-to-end gate, which on this
  machine's real desktop printed
  `proof=pass [cursor=pass fg=pass focus=pass] :: effect=reported-by-send: a channel reported the call
  returned -- 未独立验证`.

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
