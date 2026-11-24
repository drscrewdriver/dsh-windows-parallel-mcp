# Changelog

[English](CHANGELOG.md) · [中文](CHANGELOG.zh.md) · [日本語](CHANGELOG.ja.md) · [한국어](CHANGELOG.ko.md) · [Français](CHANGELOG.fr.md) · [Deutsch](CHANGELOG.de.md) · [Italiano](CHANGELOG.it.md) · [Español](CHANGELOG.es.md) · [Português](CHANGELOG.pt.md) · **Русский**

> **Русский translation — work in progress.** The English canonical text follows below; task-specific polishing replaces it section by section. The structure, code samples and numbers are already final — only the prose is pending. See the en document for the authoritative wording.

Dates are the registry `time` values for each version, not git commit dates — a commit date records
when someone typed, a publish time records when a version became installable, and only the second
one is a promise to anyone installing it.

## 0.8.2 — 2026-11-24

> Published <REGISTRY-TIME> (registry `time` for 0.8.2, read from the packument, not from a commit date).

> 0.8.2 меняет одну фразу отказа — и её корень на стороне тестов. Когда точка действительно лежит внутри дочернего окна цели, но перекрыта другим окном, движок отвечал «под этой точкой нет дочернего окна цели»: две разные ситуации делили одну фразу. Ни один код отказа не меняется (их по-прежнему семнадцать); во втором случае теперь называется класс перекрывающего окна и единственный работающий следующий шаг (вывести цель вперёд). Это измерено, а не предположено: если накрыть цель WinForms браузером владельца (цель visible=true, прямоугольник её кнопки содержит точку) и отправить этой кнопке WM_LBUTTONDOWN/UP, ответ будет ok, а приложение ни разу не выполнит обработчик — подпись остаётся Press, focusTaken=false. В этом toolkit клик сообщением требует захвата мыши, а перекрытое окно его не получает. Поэтому первая попытка исправления — принимать точку, раз «сообщению не нужна видимость», — отменена: она заставляла продукт сообщать об успехе клика, которого не было. Сторона тестов: llm-action-battery молча загружал установленную копию из профиля desktop (0.2.0, тогда как репозиторий на 0.8.1); две «базовые ошибки» в findings — это говорила та копия, и обе исчезают на репозитории. Теперь тест отказывается запускаться, если тестируемая поверхность другой версии. Плечо foreground теперь снимает показания до и после КАЖДОГО действия, а не по одному разу в начале и в конце. У фикстуры появился -Topmost (по умолчанию выключен): только Z-порядок, без переднего плана, потому что блокировка переднего плана действительно отвергает SetForegroundWindow из фонового процесса. Батарея освобождает worker и имеет жёсткий предел 240 с: без этого второй запуск подряд зависал на утёкшем worker. В lib/ и src/schema/ ничего не меняется.

## 0.8.1 — 2026-11-24

> Published 2026-11-24T01:35:11.785Z (registry `time` for 0.8.1, read from the packument, not from a commit date).

> 0.8.1 исправляет ровно один поставляемый файл, который реестр отверг бы: в 0.8.0 поле `description` в server.json занимало 800 символов, а JSON Schema реестра (2025-12-11) ограничивает его 100 -- ajv сказал это одной строкой. В поведении плагина не было ничего неверного -- MCP-сервер, действия, заслонки и аудит побайтово совпадают с 0.8.0, -- но манифест это то, как каталог находит пакет, а отвергнутый манифест есть форма поставки, существующая только внутри репозитория. Исправление: `description` стала фразой в 92 символа, а описание возможностей переехало в `_meta` под `publisher-provided` (ключ, который реестр действительно сохраняет, потолок 4 КБ; здесь около 1,2 КБ). schema-test теперь проверяет сами лимиты реестра (description 1..100, title 1..100, name в форме reverse-DNS не длиннее 200 символов, конкретная версия вместо диапазона, `_meta` меньше 4096 байт, и у каждой объявленной переменной окружения есть name); прежнее двустороннее сравнение «объявлено == читается» осталось. package.json / dsh.plugin.json / server.json / строка релиза в README теперь 0.8.1, и описание dsh.plugin.json наконец упоминает вторую форму поставки, пропущенную ещё в 0.8.0. Найдено так же, как большинство дефектов здесь: проверкой против настоящей вещи. Schema реестра был скачан заново перед выпуском 0.8.0 (в плане R7 сказано, что реестр в preview и правила могут меняться), а валидация идёт на ajv из дерева установки DSH, поэтому «server.json проходит» -- это команда с кодом возврата, а не мнение.

## 0.8.0 — 2026-11-24

> Published 2026-11-24T01:21:32.334Z (registry `time` for 0.8.0, read from the packument, not from a commit date).

> 0.8.0 открывает второй канал для того же движка, не делая второй реализации: MCP-сервер поверх stdio (bin: wpm-mcp), а форма плагина DSH остаётся нетронутой — тот же apply(), те же одиннадцать действий, те же семнадцать кодов отказа, тот же порядок заслонок и тот же журнал аудита. Это сознательная отмена решения от 2026-11-19 («form = A, MCP не делать»), записанная в файл-контракт, а не только в сообщение коммита: в tools.json появился mcpProjection рядом с hostProjection, а строка status говорит, какое решение отменено, когда и зачем (Registry принимает только MCP-серверы, а DSH умеет их подключать — одна реализация, два канала). Ни нового действия, ни нового кода; в src/engine/ не изменён ни один файл. tools/list ГЕНЕРИРУЕТСЯ из tools.json, а не переписывается: по ветке oneOf на действие, наследующей properties/required/additionalProperties поле в поле, enum действий равный таблице контракта, и в описании каждое действие идёт с тем уровнем, который оно объявляет, а каждый код отказа — с тем summary, который в контракте уже есть. Инструмент по-прежнему один: wpm. Настройки берутся из окружения (WPM_*), никогда из вызова: вызывающий, который мог бы сам поднять себе потолок или вписать себя в белый список launch, превращает модель авторизации в декорацию; значения по умолчанию остаются в одном месте (lib/index.js). Скриншот прикладывает пиксели в base64 помимо текста (путь по ту сторону pipe ничего не значит), но screenRect/scale/identity/frame/captureBackend остаются в тексте; измерено через мост DSH: у хоста без хранилища вложений изображение сворачивается в диагностику [image unavailable: …], а все числа сохраняются — значит, прикрепление пикселей по умолчанию не может лишить вызывающего той информации, ради которой он звал. server.json — манифест Registry (пространство имён io.github.drscrewdriver/dsh-windows-parallel-mcp, единственный разрешённый npm-адрес, транспорт stdio, девятнадцать описанных переменных окружения; schema-test проверяет в обе стороны, что обещанное читается и читаемое обещано). Исправлены два настоящих дефекта: неверный аргумент собирался ответиться как -32603, то есть как сбой сервера, — теперь это ошибка инструмента, в тексте которой назван аргумент; а поисковик DSH вызывал npm через execFileSync, что на Windows даёт ENOENT (npm — это .cmd), и заявлял «DSH не установлен» на машине, где он стоит. Gate 22 check-mcp-schema запускает настоящий сервер, читает то, что прочтёт клиент, и сверяет поле в поле; самоспроверка мутирует ОБЕ стороны: четыре правки генератора обязаны покраснеть, две правки КОНТРАКТА (переименовать параметр, перевернуть additionalProperties) обязаны остаться зелёными И сдвинуться — ломать только генератор значит не отличить порождённую схему от скопированной, которая сегодня случайно совпадает. mcp-stdio: 38 проверок (ни одной строки stdout вне JSON, уведомление без ответа, мусор не убивает цикл, параллельные вызовы сопоставлены по id и не перепутаны, закрытие stdin ⇒ exit 0). mcp-bridge: 17 проверок тем самым client SDK и createMcpToolDefinition, которые поставляет хост; обе формы, вызванные в одном процессе, обязаны дать одинаковую первую строку, а без установки DSH рука честно говорит SKIP. Полный gate: 22 руки, GATE GREEN ×3. Авторитетна английская запись.

## 0.7.0 — 2026-11-23

> Published 2026-11-23T18:54:04.951Z (registry `time` for 0.7.0, read from the packument, not from a commit date).

> 0.7.0 закрывает дыру «нельзя даже запустить программу», добавляет три десктопных действия и заменяет бинарный шлюз ОДНИМ потолком: каждое действие объявляет минимальную ступень, которая ему когда-либо нужна (requiresTier: readonly < quiet < flash < takeover), а владелец задаёт единственный policy (по умолчанию balanced). Выше потолка — policy_denied, и следующий шаг в нём — поднять настройку, а не повторять вызов. Для launch нужны два независимых переключателя (appLaunchAllowed и точный, нечувствительный к регистру appLaunchAllow; пустой список = ничего нельзя запускать, без wildcard и без совпадения по префиксу); отказ не стоит ни одного запроса к worker. Процесс без окна отвечает ok:true, пустой hwnd и detail=window-not-yet (измерено: холодный notepad 1348 мс с MainWindowHandle=0). ЧТЕНИЕ буфера обмена сообщает только длину и никогда содержимое (лимит 64 КБ, truncated указывается открыто); запись изображения принимает shotId. Все пять операций window проверяются обратным чтением состояния окна (IsIconic, rect, WS_EX_TOPMOST), а поскольку restore активирует по определению, результат сообщает foregroundTaken, вместо это скрывать. Действий 8 → 11 (четыре копии синхронизированы; лог check-types теперь читает эти числа из tools.json). Если владелец за клавиатурой — отказ (user_active), а не диалоговое окно; явный выход forceUserActive:true попадает в аудит. Три новых кода (app_launch_denied, policy_denied, user_active), каждый указывает на настройку. Журнал аудита: строка JSONL на каждое действие, и allow, и deny, но никогда содержимое. Исправлены два настоящих дефекта: Clipboard.Flush() отсутствует в PowerShell 5.1 (.NET Framework), а обработчик отказа читал ключ, который его ветвь никогда не выставляла. Gate 21 check-policy-table проверяет, что обе лестницы (JS и PS) — один и тот же список в том же порядке; check-jsdoc теперь проверяет, что в покрытие попадает каждый файл lib/ — раньше новый модуль молча оставался unchecked. Сознательное ужесточение: takeover:true теперь требует policy=full в дополнение к takeoverAllowed. Полный gate: 21 плечо, GATE GREEN ×3. Авторитетна английская запись.

## 0.6.0 — 2026-11-23

> Published 2026-11-23T17:25:44.824Z (registry `time` for 0.6.0, read from the packument, not from a commit date).

> 0.6.0 поднимает `type` с «я отправил» на «в поле действительно это значение»: четвёртый `effect=readback-verified` — только когда прочитанное обратно значение совпадает с предсказанием, построенным на измерениях, которые СООБЩИЛ САМ КОНТРОЛЬ (прежнее значение, WM_GETTEXTLENGTH, точка вставки EM_GETSEL); masked-поле отвечает `readback=unavailable`, приложение переформатировало ввод — `readbackMismatch=true`; ни то ни другое не повышает статус и не является ошибкой. `caretPosition: idle|start|end` — измерено: `EM_SETSEL(-1,-1)` на WinForms EDIT не работает, поэтому `end` использует (len,len), а результат раздельно сообщает `asked=` и `applied=`. Фокус переизмеряется в момент отправки (`focusMoved`); отключённое окно даёт `disabled=true`, а `effect` принудительно `unverified`. Снимок теперь предпочитает BitBlt и сообщает `captureBackend=bitblt|gdiplus` (на неподвижной сцене: 0 расхождений по каналам, PNG совпадают побайтово; узкое место — кодирование, а не захват). Новый гейт 20 `check-shot-backend` (семь мутаций, каждая красная) и `test/readback-truth.mjs` (36 проверок, сверяемых с самоотчётом приложения). Исправлен давний дефект: `SendMessageStrW` отсутствует в user32.dll, поэтому `replace:true` падал на каждой мишени. Новые коды отказа не добавлены. Авторитетна английская запись.

## 0.5.0 — 2026-11-23

> 0.5.0 делает «рамку» читаемой для вызывающей стороны и убирает расчёт координат из рук модели: три действия только на чтение (`snapshot` как нумерованная таблица элементов, `screenshot` возвращает соответствие координат, `preview` текстом сообщает элемент под точкой), адресация по `label` с возвратом к элементу по RuntimeId, `space:"image"` преобразуется движком, и четырнадцатый код отказа `stale_ref`. Запланированный инвариант «каждый rect элемента лежит внутри screenRect» опровергнут измерением (выходы за границы 3/18/287/2720px; rect — абсолютная экранная координата и от рамки не зависит): заменён на подсчитанное исключение непересекающихся элементов, взаимную проверку рамки с rect, который сообщает само дерево (frameCheck/frameInset), и структурный гейт единственного источника рамки. Гейтов 17→19, добавлены две независимые oracle-серии. Подробности в английской записи. Ещё две правки: `uia_tree_empty` больше не выдаётся для окон, у которых есть дверь, но она подавлена через `elementName` (WinForms теперь честно отвечает `unreachable`), а утверждение о дрейфе курсора, из-за которого гейт изредка краснел, теперь исключает движение владельца через `GetLastInputInfo` (SKIP с age/окном при наличии ввода; точный read-back двигателя остаётся строгим утверждением).

## 0.4.1 — 2026-11-23

> Published 2026-11-23T11:07:25.234Z (registry `time` for 0.4.1, read from the packument, not from a commit date).

> 0.4.1 — выпуск только документации и проверок, без изменений в рантайме (`lib/`, `src/engine/` побайтно не изменены). Исправлен заголовок README, который продолжал объявлять 0.2.0, и добавлен полностью отсутствовавший раздел о `types/index.d.ts`. Три новые проверки: строка версии сверяется с `package.json`, побайтное совпадение английского текста в девяти переводах, и потребительский тест, разрешающий пакет по имени (прежний использовал только относительный путь, поэтому удаление условия `types` оставляло всё зелёным). Подробнее — в английской записи.

## 0.4.0 — 2026-11-23

> Published 2026-11-23T10:47:57.110Z (registry `time` for 0.4.0, read from the packument, not from a commit date).

> Изменений в рантайме нет: вся работа делает утверждение «этот комментарий правдив» машинно проверяемым. Весь `lib/` размечен JSDoc и проверяется под checkJs (107 ошибок → 0), написанный вручную `types/index.d.ts` становится единственным источником истины на стороне реализации (правка в нём даёт красный), а неизменность кода доказана узел за узлом (идентичные AST). Исправлены две настоящие причины нестабильности тестового стенда (гонка вокруг pre-layout oracle, перекрытое целевое окно). Новых зависимостей нет. Подробнее — в английской записи.

## 0.3.0 — 2026-11-23

> Десять языков и типизированный публичный интерфейс. Документация выходит на десяти языках экосистемы DSH, русский — равноправный переключатель рядом с английским. Два варианта установки: desktop (только встроенный pnpm, никогда `dsh plugin add`) и не-desktop. Добавлен `types/index.d.ts`. Подробнее — в английской записи.

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