# 拒绝码词典

本文件是引擎拒绝语义的**对外文档形态**，也是 `src/schema/tools.json` 里 `refusals` 数组的人工可读版。
两侧由 `scripts/check-refusals.mjs` 强制对齐：代码里的字面量 ⊆ 本表，本表 ⊆ schema 数组。

## 为什么需要这本词典

R2′ 把「拒绝」当成本产品的**正常结果**（`engine.ps1` 首段注释），而不是异常路径。既然如此，
拒绝就必须携带两样东西才能用：

1. **一个封闭的码**——让调用方可以分支，而不是读一句人话去猜；
2. **一个可执行的下一步**——否则就变成 R3.2 明确禁止的「底噪式套话」：报了错，但没人知道该做什么。

所以下表每一行都写「下一步」，而不是只写「为什么失败」。

## 两层，不是一个集合

代码里实际有两个层，历史注释只描述了一层，这是本词典要显式化的第一件事：

| 层 | 出处 | 数量 | 语义 |
|---|---|---|---|
| 决定层 | `src/engine/decide.ps1` 的 `$WpmRefusals` | 10 | 动作**在执行之前**被合法否决，目标本身没被碰过 |
| 运行时失败层 | `src/engine/engine.ps1` 执行/回还段 | 4 | 决定说「能做」，做的过程中通道炸了、回还没成、**被所有者/宿主中断**，或调用里引用的上一代产物**已经不存在了** |

混在一起会让人以为「10 个码都是设计好的分支」，实际 `action_failed` 与 `restore_failed` 是**兜底**：
它们出现就意味着引擎的判断与实际能力不一致，属于需要调查的信号，不该被当成正常分支来轮询。
`takeover_aborted` 是 R3 明确设计的中断结果（不是故障），`stale_ref` 也是设计好的分支（引用过期，
有可执行的下一步）——两者之所以归在运行时层，是因为它们只能在执行的当下被判定，而不是在执行前。

## 决定层（10 码）

| 码 | 触发条件（代码位置） | 语义 | 下一步动作 | 实测状态 |
|---|---|---|---|---|
| `no_hwnd` | `engine.ps1:180`（hwnd 不是活窗口）／`decide.ps1:85`（未给 hwnd） | 没有可用目标 | 先调 `wpm_windows` 拿 hwnd，再重试；不要用屏幕坐标猜 | **REAL** — `test/refusals-test.ps1` R1：`hwnd=1` 直接返回该码 |
| `paused` | `decide.ps1:79`（`[WpmCtl]::Paused`） | 所有者按了暂停 | 停手。这是**服务端**拒绝，不是提示层建议；不要换目标绕过 | **REAL** — R2：真实桌面上把 paused 打开，`status` 返回该码 |
| `elevated_target` | `decide.ps1:89`（`facts.elevatedTarget`）；flag 由 `win.ps1` 的 `WpmWin::IsElevatedTarget` 实测置真 | 目标完整性级别更高，当前进程写不进去 | 让所有者用非提权方式重开该程序；不要提权重试 | **REAL** — 2026-11-20 `test/integrity-probe.ps1`：桌面上任务管理器（0x3000 high）被识别，`Get-WpmFacts` → `elevatedTarget=True`，决策 `refuse/elevated_target`；其余 19 个 medium 窗零误判 |
| `unreachable` | `decide.ps1:143`（测过：无消息门、无可用 pattern，**且树里有内容**）；运行时窄路 `engine.ps1:246,255,261,275,281,291` | 树是活的、点也认了，但那个点/那个名字上没有任何可用 pattern——「换一处或换目标」的世界 | 换目标、换坐标或换元素名；或让目标暴露可寻址子窗（原生 Win32/WinForms） | **REAL** — R3：WinForms 目标按名字取控件 → 消息门被抑制、WinForms 无 pattern → 该码 |
| `uia_tree_empty` | `decide.ps1:140`（`facts.uiaTreeEmpty`，由 `win.ps1` 的 `Test-WpmUiaTreeHasContent` 实测：树内 **0 个内容元素**） | 树里只剩壳，一个可驱动的内容元素都没有。**主成因**（2026-11-21 普查实测）：应用侧没开无障碍（uTools：raw=1/1/1、其中 0 个可交互元素，三连读全等；同日普查测得 raw=0/0/0——壳来去，内容从不出现）。**已知第二成因**（同轮挂泵靶窗实测）：泵挂死的应用对 WM_GETOBJECT 不作答，UIA 立即回 0 个元素——同一观察，成因不同 | 让应用以开启无障碍的方式重启（Chromium：`--force-renderer-accessibility`，启动期开关）；或换目标。若目标同时处于「未响应」状态，先等应用恢复。**不要重试轮询**——三次原位重查证明等不出内容 | **REAL** — 2026-11-21 对 uTools 真窗实测引擎端到端返回该码（扫描与点两条路）；对照 DSH 同桌首读即出真树（普查 514、复测 1019） |
| `uia_probe_failed` | `decide.ps1:136`（`facts.uiaProbeFailed`，即探针 `uiaErr` 非空） | 探针本身抛了异常（元素在测量中途被销毁等），**树测没测成**——对目标下任何结论都无凭据 | 读 reason 里 `[uia: …]` 段的异常原文再判断；不要把它当成「目标不可达」的证据，也不要自动重试 | **REAL** — 2026-11-21 探针异常实例：WM_CLOSE 于调用后 40ms 落进探针（`IsWindow` 已过、`FromHandle` 抛「无法识别的错误」），返回该码且 reason 带 `[uia: …]` 异常原文 |
| `terminal_no_door` | `decide.ps1`（family=terminal 且两门皆无） | 终端文字面**有 3 个子 HWND，但无一可写**：`DRAG_BAR_WINDOW_CLASS` 是标题栏拖拽条，`DesktopWindowContentBridge` 是 DirectComposition 渲染目标（不接受 `WM_CHAR`/`WM_SETTEXT`），`InputSite.WindowClass` 是 0×0 的输入接收器；也没有可用的 UIA pattern | **换目标**（浏览器地址栏／文本框／WinForms 编辑框）。**「改用键盘注入」这条路已被实测否决**：Unicode 与扫描码两臂都被 SendInput 接受、前台也对，终端就是不执行——所以本码不再把注入写成下一步 | **REAL（窗口普查 + 注入实测）** — 2026-11-23：只读枚举 CASCADIA 终端 3 子窗无一可写（findings §B）；`scripts/probe-console-inject.ps1`（242 事件、Enter 已发、文件未生成）与 `scripts/probe-console-scan.ps1`（262 事件、同样失败）见 findings §G3 |
| `needs_facts` | `decide.ps1` | 调用方没给这个目标的实测事实 | 先测量再决定。**拒绝，而不是默认走安静档** | **REAL（表级）** — 引擎内不可达：`facts` 恒被测量，本码只在表被单独使用时出现 |
| `takeover_unavailable` | `decide.ps1`（`facts.takeoverRequested && !facts.hudReady`）；宿主侧 `lib/index.js` 在 `takeoverAllowed=false` 时直接拒，零 worker 请求 | 要求接管档，但**接管面不存在**：HUD 没起来，或设置里 `takeoverAllowed` 关着 | 在设置里打开 `takeoverAllowed`；HUD 是**硬前置**，不是装饰。不想接管就**去掉 `takeover:true`** 走静默档——本码存在的意义正是「绝不静默降级」 | **REAL** — `test/plugin-test.mjs`（宿主闸：默认关 + `takeover:true` ⇒ 该码且工作进程 0 请求）；`test/takeover-test.ps1` 决策臂 |
| `keyinject_unavailable` | `decide.ps1`（注入不在接管档内／`keyInjectAllowed` 关／目标不是前台且抬不起来）；`engine.ps1`（发送瞬间前台已变） | 要求键盘注入，但注入会打到**别的窗口**或没被授权。依据是实测：`SendInput` 只写前台（`scripts/probe-sendinput-unicode.ps1` arm B：文本落在前台窗 B，而不是调用方以为的 A） | 先自己把目标切到前台（或用 `focus` 动作把它抬上来），或关掉 `keyInput` 用静默档；不允许「盲注入」 | **REAL** — `test/keyinject-test.ps1` K1（非前台拒绝，注入零次）、K5（双闸独立）；判定层两条用例 |

## 运行时失败层（4 码）

| 码 | 触发条件 | 语义 | 下一步动作 | 实测状态 |
|---|---|---|---|---|
| `action_failed` | `engine.ps1:218`（通道调用抛异常） | 决定说能做，实际调用炸了 | 报给所有者并附异常原文；同一目标不要自动重试第二次 | **NOT-COVERED** — 需要可稳定抛错的真实目标，本轮未构造 |
| `stale_ref` | `engine.ps1`（`space:"image"` 的 `shotId` 不在本进程的截图表里；`label`+`snapId` 不是最新帧；宿主侧 `lib/index.js` 对 `space:"image"` 缺 `shotId` 做前置拒绝） | **引用过期**：这次调用指的是引擎上一代产物（一张已被保留策略删掉的截图，或一帧已被新快照取代的编号表）。编号只在印出它的那一帧里有意义 | 重新 `snapshot` / `screenshot` 拿新 id 再动作。**不要**把图像像素当屏幕像素直接用——那正是本码要挡的「看起来对」的位置错误 | **REAL** — `test/refusals-test.ps1` 执行 `click-stale-shot`：未发过的 `shotId` ⇒ 该码且不进探测 |
| `restore_failed` | `engine.ps1`（表判 restore、OS 拒绝 SetForegroundWindow） | 所有者被留在了一个不是他选的窗口里 | 立刻上报；不要静默重试，也不要启动看门狗抢第三次 | **NOT-COVERED** — 需提权窗配合，属 task_52 |
| `takeover_aborted` | `engine.ps1`（HUD 按钮／中断键／宿主取消，三路汇聚后置位） | 接管被**人**或**宿主**中止了。这不是故障，是 R3 承诺的能力：结果里仍带 `cursorRestored` 与 `injectedChars`，让读者知道做到哪一步 | 读 `injectedChars` 判断已写入多少；要接着做就**重新发起**一次动作（不会从断点续写）。不要把它当成失败来重试 | **REAL** — `test/takeover-test.ps1` 三臂（volatile 标志／latch 文件／长文本中途中断），每臂都断言光标回位 |

## 三个诚实的缺口（写在文档里，而不是留白）

1. **`elevated_target` 已接线（2026-11-20，task_52 的识别半边）。** 检测是只读的 token 比较
   （`OpenProcess(QUERY_LIMITED)` → `TokenIntegrityLevel` → 最后一个子授权 RID），读不到一律按
   未知→不拒绝——猜「已提权」会把每个句柄读取失败的窗口都拒掉，那是反向的错检测。
   接线过程中被实测抓出三个「静默恒 false」缺陷：size-probe 的返回值语义（文档规定该调用**必然
   返回 FALSE**）、`GetLengthSid` 在本机返回 TRUE+len=0、SID 头未校验就索引。三者都让检查「看起来
   在工作」而实际全部 unknown——这正是「错的检测比没有更糟」的具体形态。
   **仍缺的**：`restore_failed` 兜底路径（提权窗 + 抬前台被 OS 拒绝的端到端）需要提权窗口在跑
   battery 时在场；本轮 Task Manager 在场时测到了识别与拒绝，恢复兜底未触发。
2. **`action_failed` / `restore_failed` 没有实测样例。** 表中标 NOT-COVERED，不写「已支持」。
3. **`terminal_no_door` 的措辞已在 2026-11-23 依据实测修正**：不再是「不暴露子 HWND」，而是
   「有 3 个子 HWND 但无一可写」（findings §B 只读枚举）。该码保留的价值是**诊断 + 指出下一步**
   （`takeover:true` + `keyInput:'inject'`），不是死路；终端的**可写不可读**限制写在
   `docs/takeover.md`。
4. **`uia_probe_failed` 的可执行用例只有判定层一条**（schema 里 `click-uia-probe-failed`，decision 模式）。
   引擎级用例需要「探针必然抛异常」的稳定构造，本轮拿到了**真样本**但没固化成可复跑用例：构造是
   「引擎调用开始后 N ms，由一个原生 OS 线程向靶窗投递 WM_CLOSE」（销毁落在 `IsWindow` 与
   `FromHandle` 之间的窗口里）；2026-11-21 扫描 40ms 一档即命中（reason 带 `[uia: …FromHandle…
   无法识别的错误…]`）。它是竞态：延迟档位选错就落到 `no_hwnd`（先销毁）或 `unreachable`
   （后销毁），而「只销毁控件不销毁窗体」和「泵挂死」两个变体都会被逐元素的内部 catch 吞掉、
   读成 `uia_tree_empty` 而不是抛错——所以做成 schema 可执行用例需要一个能精确中断跨进程 COM
   的靶窗，留给后续轮次。

## 与工具 schema 的关系

- `src/schema/tools.json` 的 `refusals` 数组是机器可读形态；每个动作型工具（`wpm_click` / `wpm_type` /
  `wpm_focus`）列出它可能返回的码，并带**可执行**的拒绝路径用例。
- R3 新增三码（`takeover_unavailable` / `keyinject_unavailable` / `takeover_aborted`）**同批**写进代码、
  schema 与本表，由 `scripts/check-refusals.mjs` 三方对齐检查；`takeover_aborted` 是运行时结果，
  其 schema 用例声明为 uncovered 并附理由（`tools.json` 的 `uncoveredReason`）。
- `wpm_windows` / `wpm_status` 是只读查询，**不产生拒绝码**。与其编造一条假分支，不如在 schema 里写
  `noRefusalReason` 并让门禁检查它非空。
- `test/schema-test.mjs` 校验：码集合三方一致、用例参数能通过该工具的 inputSchema、每个动作型工具至少一条用例。
