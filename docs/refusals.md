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
| 决定层 | `src/engine/decide.ps1` 的 `$WpmRefusals` | 6 | 动作**在执行之前**被合法否决，目标本身没被碰过 |
| 运行时失败层 | `src/engine/engine.ps1` 执行/回还段 | 2 | 决定说「能做」，做的过程中通道炸了或回还没成 |

混在一起会让人以为「8 个码都是设计好的分支」，实际后 2 个是**兜底**：它们出现就意味着
引擎的判断与实际能力不一致，属于需要调查的信号，不该被当成正常分支来轮询。

## 决定层（6 码）

| 码 | 触发条件（代码位置） | 语义 | 下一步动作 | 实测状态 |
|---|---|---|---|---|
| `no_hwnd` | `engine.ps1:109`（hwnd 不是活窗口）／`decide.ps1:73`（未给 hwnd） | 没有可用目标 | 先调 `wpm_windows` 拿 hwnd，再重试；不要用屏幕坐标猜 | **REAL** — `test/refusals-test.ps1` R1：`hwnd=1` 直接返回该码 |
| `paused` | `decide.ps1:69`（`$script:WpmPaused`） | 所有者按了暂停 | 停手。这是**服务端**拒绝，不是提示层建议；不要换目标绕过 | **REAL** — R2：真实桌面上把 paused 打开，`status` 返回该码 |
| `elevated_target` | `decide.ps1:77`（`facts.elevatedTarget`）；flag 由 `win.ps1` 的 `WpmWin::IsElevatedTarget` 实测置真 | 目标完整性级别更高，当前进程写不进去 | 让所有者用非提权方式重开该程序；不要提权重试 | **REAL** — 2026-11-20 `test/integrity-probe.ps1`：桌面上任务管理器（0x3000 high）被识别，`Get-WpmFacts` → `elevatedTarget=True`，决策 `refuse/elevated_target`；其余 19 个 medium 窗零误判 |
| `unreachable` | `decide.ps1:111`（测过：无消息门、无可用 pattern）；运行时窄路 `engine.ps1:150,159,165,185,195` | 目标没有任何可在不注入物理输入的前提下使用的门 | 换目标；或让目标暴露可寻址子窗（原生 Win32/WinForms） | **REAL** — R3：WinForms 目标按名字取控件 → 消息门被抑制、WinForms 无 pattern → 该码 |
| `terminal_no_door` | `decide.ps1:84`（family=terminal 且两门皆无） | 终端文字面既不暴露子 HWND，也没有 Document 元素 | 换目标（浏览器地址栏/记事本等），终端不在可驱动面内 | **SIMULATED** — 判定层注入。真实终端窗实测刻意推迟，理由见下 |
| `needs_facts` | `decide.ps1:65,107` | 调用方没给这个目标的实测事实 | 先测量再决定。**拒绝，而不是默认走安静档** | **REAL（表级）** — 引擎内不可达：`facts` 恒被测量，本码只在表被单独使用时出现 |

## 运行时失败层（2 码）

| 码 | 触发条件 | 语义 | 下一步动作 | 实测状态 |
|---|---|---|---|---|
| `action_failed` | `engine.ps1:218`（通道调用抛异常） | 决定说能做，实际调用炸了 | 报给所有者并附异常原文；同一目标不要自动重试第二次 | **NOT-COVERED** — 需要可稳定抛错的真实目标，本轮未构造 |
| `restore_failed` | `engine.ps1:266`（表判 restore、OS 拒绝 SetForegroundWindow） | 所有者被留在了一个不是他选的窗口里 | 立刻上报；不要静默重试，也不要启动看门狗抢第三次 | **NOT-COVERED** — 需提权窗配合，属 task_52 |

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
3. **`terminal_no_door` 只有判定层实测。** 本轮不拉真实终端窗口，是因为 `findings.md:311-316` 记录过一次
   `wt --headless` 残留 Error 弹窗事故（单实例转发 + 弹窗归属真实宿主，`Stop-Process` 够不到）。
   真实证据是覆盖率普查：`findings-G0-VERDICT.md` 的 `uap-framed` 30 窗 0 门。

## 与工具 schema 的关系

- `src/schema/tools.json` 的 `refusals` 数组是机器可读形态；每个动作型工具（`wpm_click` / `wpm_type` /
  `wpm_focus`）列出它可能返回的码，并带**可执行**的拒绝路径用例。
- `wpm_windows` / `wpm_status` 是只读查询，**不产生拒绝码**。与其编造一条假分支，不如在 schema 里写
  `noRefusalReason` 并让门禁检查它非空。
- `test/schema-test.mjs` 校验：码集合三方一致、用例参数能通过该工具的 inputSchema、每个动作型工具至少一条用例。
