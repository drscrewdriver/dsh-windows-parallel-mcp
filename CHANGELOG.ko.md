# Changelog

[English](CHANGELOG.md) · [中文](CHANGELOG.zh.md) · [日本語](CHANGELOG.ja.md) · **한국어** · [Français](CHANGELOG.fr.md) · [Deutsch](CHANGELOG.de.md) · [Italiano](CHANGELOG.it.md) · [Español](CHANGELOG.es.md) · [Português](CHANGELOG.pt.md) · [Русский](CHANGELOG.ru.md)

> **한국어 translation — work in progress.** The English canonical text follows below; task-specific polishing replaces it section by section. The structure, code samples and numbers are already final — only the prose is pending. See the en document for the authoritative wording.

Dates are the registry `time` values for each version, not git commit dates — a commit date records
when someone typed, a publish time records when a version became installable, and only the second
one is a promise to anyone installing it.

## 0.8.1 — 2026-11-23

> Published <REGISTRY-TIME> (registry `time` for 0.8.1, read from the packument, not from a commit date).

> 0.8.1 은 레지스트리가 거절할 수 있는 출하 파일 하나만 고친다. 0.8.0 의 server.json description 은 800 자였고 Registry JSON Schema(2025-12-11) 는 이 칸을 100 자로 막아 ajv 가 한 줄로 말했다. 동작상 문제는 없다 — MCP 서버도 액션도 게이트도 감사도 0.8.0 과 바이트 단위 동일 — 하지만 매니페스트는 목록이 패키지를 찾는 통로이고, 거절되는 매니페스트는 저장소 안에만 존재하는 출하 형태다. 고친 방법: description 을 92 자 한 문장으로 줄이고 능력 설명은 Registry 가 실제로 보존하는 자리(_meta publisher-provided, 4KB 상한, 이번 것은 약 1.2KB) 로 옮겼다. schema-test 는 이후 레지스트리 제한 자체를 검증한다(description 1..100, title 1..100, name 은 reverse-DNS 형식에 200 자 이내, 버전은 범위가 아닌 구체값, _meta 4096 바이트 미만, 선언된 모든 환경 변수에 name 이 존재). 기존 '선언==읽기' 양방향 대조는 그대로. package.json / dsh.plugin.json / server.json / README 버전 표기를 0.8.1 로 통일하고, 0.8.0 부터 빠져 있던 두 번째 출하 형태를 dsh.plugin.json 설명에 보탰다. 발견은 이 프로젝트 대다수 결함처럼 진짜를 상대로 검사를 돌려서였다. Registry 스키마는 0.8.0 출시를 위해 다시 가져왔고(계획 R7: preview 라 규정이 움직일 수 있다), 검증은 DSH 설치 트리에 있는 ajv 로 했으므로 'server.json 검증 통과'는 의견이 아니라 종료 코드를 가진 한 번의 명령이다.

## 0.8.0 — 2026-11-24

> Published 2026-11-24T01:21:32.334Z (registry `time` for 0.8.0, read from the packument, not from a commit date).

> 0.8.0 은 같은 엔진에 두 번째 채널을 열었지만 두 번째 구현은 만들지 않았다. stdio MCP 서버(bin: wpm-mcp)를 추가했고 DSH 플러그인 형태는 그대로다 — 같은 apply(), 같은 11 액션, 같은 17 거절 코드, 같은 게이트 순서와 같은 감사 로그. 이는 2026-11-19 결정 "form = A, MCP 는 만들지 않는다"를 의도로 뒤집은 것이며, 되돌림은 커밋 메시지가 아니라 계약 파일에 적혔다: tools.json 에 mcpProjection 이 hostProjection 옆에 들어가고 status 행이 '어떤 결정을 언제, 왜 뒤집었는지'(Registry 는 MCP 서버만 받고 DSH 는 브리지할 수 있으므로 구현 하나로 두 채널에 닿는다)를 밝힌다. 이번 판은 액션도 거절 코드도 추가하지 않았고 src/engine/ 는 0 개 파일 변경이다. tools/list 는 tools.json 에서 생성(필사가 아니다): 액션마다 oneOf 분기 하나가 properties/required/additionalProperties 를 필드 단위로 물려받고, action enum 은 계약의 액션표 그 자체이며, 설명에서 각 액션은 자기가 선언한 단과, 각 거절 코드는 계약이 이미 가진 요약과 함께 실린다. 공개하는 도구는 여전히 wpm 하나. 설정은 환경 변수(WPM_*) 에서만 읽고 호출 인자에서는 읽지 않는다 — 자기 천장을 스스로 올리거나 launch 허용 목록에 자기를 추가할 수 있는 호출자는 권한 모델을 장식으로 만든다. 기본값은 lib/index.js 한 곳에만 남는다. 스크린샷은 텍스트 외에 base64 image content 를 첨부한다(파이프 저쪽에서는 이 기계의 경로를 열 수 없다)만, screenRect/scale/identity/frame/captureBackend 는 항상 텍스트 쪽에 남는다. DSH 브리지를 통해 실측: 첨부 저장이 없는 호스트에서는 이미지를 [image unavailable: …] 텍스트로 강등하고 수치는 전부 남긴다. 그래서 픽셀을 기본 첨부하는 것이 호출자가 실제로 필요로 하던 정보를 앗아가지는 않는다. server.json 은 Registry 매니페스트(네임스페이스 io.github.drscrewdriver/dsh-windows-parallel-mcp, Registry 가 승인하는 유일한 npm 소스, stdio transport, 환경 변수 19 개; schema-test 는 '선언한 것은 읽고, 읽는 것은 선언한다'를 양방향으로 검증) 이다. 실제로 고친 두 가지: 잘못된 인자가 -32603(서버 고장) 으로 답될 뻔한 것을 도구 수준 오류로 다시 분류해 WHICH 인자인지 본문에 남긴다. Windows 에서 npm 은 .cmd 라 execFileSync 가 ENOENT 를 던져 'DSH 미설치'로 보이던 문제도 잡았다. 새 게이트 22 check-mcp-schema 는 실제 서버를 띄워 실제 응답을 계약과 필드 단위로 비교하고, self-test 는 양쪽을 변형한다: 서버 쪽 4 개는 반드시 빨강, 계약 쪽 2 개(매개변수 이름 변경, additionalProperties 반전)는 반드시 초록을 유지하면서 반드시 따라 움직여야 한다 — 생성기만 망가뜨리는 검사로는 '생성'과 '오늘 우연히 들어맞는 필사'를 구분할 수 없다. mcp-stdio 38 검증(stdout 에 JSON 이 아닌 줄이 하나도 없음, 알림은 답이 없음, 쓰레기 줄로 죽지 않음, 동시 호출은 id 로 짝지어 뒤바뀌지 않음, stdin 닫힘 시 exit 0), mcp-bridge 17 검증(호스트가 번들한 client SDK 와 createMcpToolDefinition 을 쓰고, 두 형태를 한 프로세스에서 호출해 첫 행이 같음을 확인; DSH 가 없는 환경에서는 없는 그대로 SKIP). 전체 게이트 22 팔 ×3 GATE GREEN. 권위는 영어본.

## 0.7.0 — 2026-11-23

> Published 2026-11-23T18:54:04.951Z (registry `time` for 0.7.0, read from the packument, not from a commit date).

> 0.7.0 은 「프로그램 하나 켜지 못한다」는 구멍을 메우고 세 개의 데스크톱 동작을 추가하면서, 이진 권한 게이트를 하나의 천장으로 바꿨다. 각 액션은 가장 낮은 필요 단(requiresTier: readonly < quiet < flash < takeover)을 선언하고 소유자는 policy 하나만 정한다(기본 balanced). 천장 초과면 policy_denied — 다음 단계는 재시도가 아니라 설정 상향이다. launch 는 서로 암시하지 않는 두 스위치를 요구한다(appLaunchAllowed 와, 완전 일치·대소문자 무시의 appLaunchAllow. 비어 있으면 아무것도 실행 불가, 와일드카드·접두 일치 없음). 거절 시 worker 요청 0. 프로세스는 떴는데 창이 없으면 ok:true + hwnd 공백 + detail=window-not-yet(실측: 차가운 notepad 는 1348ms 동안 MainWindowHandle=0). clipboard 읽기는 길이만 알리고 본문을 절대 싣지 않으며(64KB 상한, truncated 명시), 이미지 쓰기는 shotId 를 직접 받는다. window 다섯 조작은 창 스스로의 상태(IsIconic/rect/WS_EX_TOPMOST)를 다시 읽어 검증하고, restore 은 정의상 포그라운드를 잡으므로 숨기지 말고 foregroundTaken 으로 보고한다. 액션 수 8→11(계약 네 곳을 동기화하고 check-types 로그를 tools.json 에서 읽는다). 주인이 자리에 있으면 대화 상자 대신 user_active 로 거절하고, 탈출구 forceUserActive:true 는 감사 로그에 남는다. 새 코드 15/16/17(app_launch_denied/policy_denied/user_active)은 모두 다음 단계로 설정을 지목한다. 감사 로그는 액션마다 한 줄, allow 와 deny 모두 적되 내용은 결코 적지 않는다. PS 5.1(.NET Framework) 에 없는 Clipboard.Flush() 와, 분기가 쓰지 않은 키를 읽던 결함을 실제로 고쳤다. 새 게이트 21 check-policy-table 은 JS·PS 두 사다리가 같은 순서임을 검증하고, check-jsdoc 은 lib/ 모든 파일이 검사 대상에 있음을 검증한다(이전엔 조용히 빠졌다). 의도적으로 조인 부분: takeover:true 는 takeoverAllowed 에 더해 policy=full 을 요구한다. 전체 게이트 21 팔 ×3 GATE GREEN. 권위는 영어본.

## 0.6.0 — 2026-11-23

> Published 2026-11-23T17:25:44.824Z (registry `time` for 0.6.0, read from the packument, not from a commit date).

> 0.6.0은 `type`을 "보냈다"에서 "필드에 실제로 이 값이 들어갔다"로 끌어올린다. 네 번째 `effect=readback-verified`를 추가했다 — 쓸 뒤 다시 읽은 값이 컨트롤 스스로 보고한 데이터(원래 값, WM_GETTEXTLENGTH, EM_GETSEL 착점)로 만든 예측과 완전히 맞을 때만 인정된다. 가려진 필드는 `readback=unavailable`, 앱이 입력을 다시整形한 경우는 `readbackMismatch=true`이며 둘 다 승격하지 않으되 ok:true는 유지된다. `caretPosition: idle|start|end`(실측 결과 WinForms EDIT에서 `EM_SETSEL(-1,-1)`는 동작하지 않으므로 end는 (len,len)를 쓰고, asked=와 applied=를 나눠 보고한다). 전송 직전 초점 재측정 `focusMoved`, 비활성화 대상은 `disabled=true`와 effect를 unverified로 고정. 스크린샷은 BitBlt를 먼저 쓰고 `captureBackend=bitblt|gdiplus`를 보고한다(정지 장면에서 두 경로가 채널 차 0·PNG 바이트 동일을 실측, 병목은 인코딩이지 캡처가 아니다). 20번째 게이트 check-shot-backend(7개 변이 모두 빨강)와 test/readback-truth.mjs(36 검증, 앱 자체 보고 값과 대조)를 추가했다. 오래된 결함도 고쳤다: `SendMessageStrW`는 user32.dll 내보내기 기호가 아니라 `replace:true`가 모든 대상에서 action_failed였다. 거절 코드 추가는 없다. 상세는 영어본이 권위이다.

## 0.5.0 — 2026-11-23

> 0.5.0은 「프레임」을 호출자가 읽을 수 있게 만들고 좌표 계산을 모델의 손에서 떼어낸 릴리스입니다. 읽기 전용 액션 3종(`snapshot` 번호 요소표, `screenshot`은 매핑까지 반환, `preview`는 지점 아래 요소를 텍스트로 보고), `label`을 RuntimeId로 요소에 되돌리는 방식, `space:"image"`의 엔진 환산, 14번째 거부 코드 `stale_ref`를 추가했습니다. 계획의 「모든 요소 rect는 screenRect 안에 있어야 한다」 불변식은 실측으로 반박되었습니다(3/18/287/2720px 초과, rect는 절대 화면 좌표라 프레임과 무관). 대신 초과 요소 제외·계수, 프레임과 트리 자기신고 사각형의 상호 검사, 단일 프레임 소스 구조 게이트로 바꿨습니다. 게이트 17→19. 자세한 내용은 영어 정본 항목 참조.두 가지 추가 수정: `uia_tree_empty`가 「원래 문이 있는데 elementName 때문에 억제된」 창에 더 이상 잘못 나오지 않고(WinForms는 `unreachable`), 게이트를 간헐적으로 붉히던 커서 이동량 판정은 `GetLastInputInfo`로 사용자의 입력을 제외(입력이 있으면 age/window를 출력하고 SKIP, 엔진 자체 read-back은 여전히 엄격)했다.

## 0.4.1 — 2026-11-23

> Published 2026-11-23T11:07:25.234Z (registry `time` for 0.4.1, read from the packument, not from a commit date).

> 0.4.1은 문서와 게이트만의 릴리스이며 런타임 변경은 없습니다(`lib/`, `src/engine/` 바이트 단위 그대로). README 첫머리가 계속 0.2.0을 선언하던 문제를 고치고, 언급조차 없던 `types/index.d.ts` 절을 추가했습니다. 게이트 세 개 추가: 릴리스 줄과 `package.json` 버전 대조, 9개 언어 영문 본문 바이트 일치, 패키지 이름으로 해석하는 소비자 테스트(기존에는 상대 경로만 써서 `types` 조건을 지워도 전부 초록이었습니다). 자세한 내용은 영문 항목 참조.

## 0.4.0 — 2026-11-23

> Published 2026-11-23T10:47:57.110Z (registry `time` for 0.4.0, read from the packument, not from a commit date).

> 런타임 변경은 없습니다. 모든 작업은 "이 주석은 사실이다"를 기계가 검증할 수 있게 만드는 데 쓰였습니다. `lib/` 전체를 JSDoc + checkJs로 검사(107 오류 → 0), 수기 `types/index.d.ts`가 구현 측 단일 진실 원천이 되고(바꾸면 빨개짐), 코드 미변경은 AST 노드 단위 비교로 증명. 테스트 불안정 원인 2건(pre-layout oracle 경합, 대상 창 가림)도 수정. 새 의존성 없음. 자세한 내용은 영문 항목 참조.

## 0.3.0 — 2026-11-23

> 10개 언어와 타입 공개 인터페이스. 문서는 DSH 생태계 10개 언어로 제공되며 한국어는 영어와 나란한 1등 전환입니다. 설치는 desktop / 비desktop 두 경우(desktop은 내장 pnpm으로만 수동, dsh plugin add 금지). types/index.d.ts 추가. 자세한 내용은 영문 항목 참조.

## 0.2.0 — 2026-11-23

> Published 2026-11-23T06:26:52Z (registry `time` for 0.2.0, read from the packument, not from a commit
> date).

**The promise changes shape, so the version changes major-minor.** 0.1.x said: no physical input at
all, ever. That was true and cheap to enforce by absence. 0.2.0 keeps it as the DEFAULT and adds an
opt-in tier that can move the cursor and type into the foreground window — which means the old claim
cannot stay as written, and a release that quietly kept the old wording would be the exact failure
mode this project keeps writing gates against.

### Added — the takeover tier (`takeover:true`)

- **A fourth tier.** `quiet` (window messages) and `bounded-flash` (UIA pattern, one reversed flash)
  are unchanged. `takeover` is entered only by an explicit request AND with both settings gates on;
  it places the real cursor on the action point, holds the focus for the duration, and always
  restores. `refuse` is unchanged.
- **The HUD's phase is a colour, not a sentence.** `arming` is amber, `active` red, `done` green —
  encoded twice (whole surface tint + a 5px accent bar) because the owner is looking at the target
  window, not at a 470×104 window in the corner. `test/hud-test.ps1` asserts it from the real pixels
  (C18, five arms: each phase's dominant hue, all three distinct, and the surface tint changing too).
- **A three-phase HUD as a hard precondition.** `arming` (default 800 ms, cancellable) → `active`
  (elapsed/limit clock and injected-character count) → `done`. `WS_EX_TOPMOST|WS_EX_NOACTIVATE`,
  `ShowActivated=false`, measured to leave `GetForegroundWindow()` unchanged. Empty space is
  click-through via a `WNDPROC` subclass returning `HTTRANSPARENT`; the button stays clickable.
  No HUD ⇒ `takeover_unavailable`, never a silent takeover.
- **Three interruption paths, one flag.** HUD stop button, a global abort chord (candidates from
  `Ctrl+Alt+X`; the one that actually registered is displayed and reported as `abortChord=`), and the
  host's cancellation (`exec.signal` → `%LOCALAPPDATA%/wpm/takeover-abort.<pid>` latch file, because
  the worker is single-threaded and cannot read a request mid-action). Interruption returns
  `takeover_aborted` WITH `cursorRestored` and `injectedChars`.
- **Keyboard injection, takeover-only** (`keyInput:"inject"`). `SendInput` + `KEYEVENTF_UNICODE`,
  per character, interruptible every 8 characters or 50 ms. The foreground is asserted to BE the
  target before sending and re-asserted at send time — measured: text sent while another window was
  in front landed in that window. Success reports `effect=reported-by-send`, never "verified".
  No hardware scancode is carried; a scancode-only target would ignore it (documented limitation).
- **New refusals, three copies kept in step:** `takeover_unavailable` and `keyinject_unavailable`
  (decision layer), `takeover_aborted` (runtime layer).
- **New settings:** `takeoverAllowed=false`, `keyInjectAllowed=false`, `takeoverMaxMs=10000`,
  `takeoverArmMs=800`. Both gates default OFF so an upgrade cannot start moving the cursor by itself.
- **New gates:** `check-no-cursor-control.mjs` became a whitelist (`SetCursorPos` only in
  `takeover.ps1`, `SendInput` only in `input-inject.ps1`, mouse events banned everywhere), and a new
  `check-takeover-path.mjs` asserts G1–G5 (file confinement, branch-scoped loading,
  HUD-checked-before-act, move-and-restore in one `try/finally`, keyboard-only events) and proves
  itself non-vacuous by injecting one violation per assertion. `check.mjs` now runs 11 gates.
- **`proof` grew a declared takeover:** cursor motion on this tier is reported as `declared`, but
  `cursorRestored=false` is a hard `proof=fail` with the reason 「借了未还」.

### Withdrawn — the terminal claim was measured false

The plan for this release was to drive a terminal by typing into it. Two probes disagree, on this
host, with everything else held correct: `scripts/probe-console-inject.ps1` sent 242 Unicode events
into a dedicated Windows Terminal window (foreground verified, Enter sent) and the shell executed
nothing; `scripts/probe-console-scan.ps1` repeated it with layout scan codes (262 events) and got the
same result. GUI targets are unaffected — the same code types Chinese text into a WinForms edit
successfully. So `terminal_no_door` stays, its reason now points at what DOES work (a target with a
real door), and the documentation says plainly that the terminal is neither writable nor readable
here. A capability that cannot be demonstrated is not shipped as a promise.

### Fixed / hardened

- **The marker had a white square behind it.** `overlay.ps1` set `AllowsTransparency` but never set
  `Background`, and a WPF `Window`'s default background is `SystemColors.WindowBrush` (white) — so the
  22px marker painted an opaque white tile with the blue ring inside it. Geometry could not see this
  (the rect was correct and click-through still worked), which is why it survived every existing arm.
  Fixed with an explicit `Transparent` background and pinned by a NEW PIXEL ARM in
  `test/overlay-test.ps1`: `PrintWindow(PW_RENDERFULLCONTENT)` the marker and assert the corners are
  unpainted while the centre still carries the ring. Measured before/after with the same probe — corner
  rgb **217,217,217 → 0,0,0**, centre rgb **166,204,217 → 0,38,51**; removing the fix turns the arm red.
- `lib/config.js`: on the Schemastery path, unknown setting keys were silently carried into the
  validated value (a typo looked accepted while doing nothing). They are now rejected, matching the
  shim's rule that the plugin test already pinned.
- `docs/refusals.md`: `terminal_no_door` no longer claims "no child HWND" — the measured truth is
  "three child HWNDs, none writable" (drag bar, DirectComposition target, 0×0 input sink).

### Measured for this release (re-runnable from `scripts/`)

- `SetCursorPos(+40,+20)` read back exactly, restore landed exactly (`probe-setcursor-pos.ps1`).
  The elevated-foreground arm could not be arranged from a non-elevated process — recorded as
  unmeasured, not guessed.
- Injected text goes to the FOREGROUND window, not the intended one (`probe-sendinput-unicode.ps1`, B
  in front ⇒ text in B and nothing in A; A in front with Chinese ⇒ landed in A).
- HUD click-through: `HwndSource` hook receives `WM_NCHITTEST` but cannot change hit-testing; a
  `WNDPROC` subclass works (`probe-hittest-children.ps1`).
- Desktop test arms (manual, because they move the real pointer): `test/hud-test.ps1` 19/19,
  `test/takeover-test.ps1` 22/22, `test/keyinject-test.ps1` 11/11 with one skip (the real-console
  arm, superseded by the two console probes above).
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