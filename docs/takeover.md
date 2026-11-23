# 接管档（Takeover Tier）

> 0.2.0 起，本插件有一个**默认关闭**的第三档：`takeover:true`。本文说明它借走什么、怎么还、怎么被中断，
> 以及**它明确做不到什么**。所有数字都出自 `scripts/` 里可复跑的探针与 `test/` 里可复跑的测试。

## 四档总表

| 档 | 何时进入 | 光标 | 焦点 | 键盘 | HUD |
|---|---|---|---|---|---|
| `quiet` | 窗口消息门存在（默认首选） | 0 px | 0 变更 | 零注入 | 无 |
| `bounded-flash` | 只有 UIA pattern | 0 px | 一次闪光，自动回还（实测净回还 15–95 ms） | 零注入 | 无 |
| **`takeover`** | 显式 `takeover:true` 且两关都开 | **移到动作点，必复位** | 持有至动作结束，然后按表回还 | 仅 `keyInput:"inject"` 时注入 | **必需，三段式** |
| `refuse` | 任何前置不满足 | — | — | — | 拒绝码 |

**接管档不新增点击通道。** 点击仍走 message/UIA；`SetCursorPos` 只是让所有者**看见** agent 指到哪，
`SendInput` 只在目标连门都没有时才作为最后手段。**鼠标注入永远不存在**：`MOUSEEVENTF_*` 全仓禁止。

## 两个开关，默认都关

| 设置 | 默认 | 含义 |
|---|---|---|
| `takeoverAllowed` | `false` | 允许 `takeover:true`；关着时**拒绝** `takeover_unavailable`，**不静默降级** |
| `keyInjectAllowed` | `false` | 允许接管档内的 `keyInput:"inject"`；关着时拒绝 `keyinject_unavailable` |
| `takeoverMaxMs` | `10000` | 单次动作上限（500–60000），HUD 实时显示时钟 |
| `takeoverArmMs` | `800` | 预警段时长：光标移动/按键之前的可取消窗口 |

默认全关是产品决定：升级不该让别人的指针自己动起来。

## 三段式 HUD

| 段 | 时长 | 配色（底色 / 左侧 5px 色条 / 文字） | 显示 | 可做的操作 |
|---|---|---|---|---|
| `arming` | `takeoverArmMs`（默认 800 ms） | **琥珀** `#3A2C0C` / `#F0AD18` / `#FFD88A` | 「即将使用你的鼠标/键盘/焦点 · <action>」+ **实际注册到的中断键** | 取消 |
| `active` | 至动作结束或上限 | **红** `#3A1212` / `#E84040` / `#FFBEBE` | 「占用中 · 已用 1.2s / 上限 10s · 已注入 N 字」 | 停止 |
| `done` | 默认 1500 ms | **绿** `#0E2E1E` / `#34C77B` / `#B2F0CD` | 「已归还：光标已复位」 | 无（按钮禁用） |

**为什么是三色而不是三种文案。** 接管期间所有者的注意力在目标窗口，不在右下角这块 470×104 的浮窗上；
读一句话的成本远高于扫一眼颜色。所以相位被编码**两遍**：整块底色 + 左侧 5px 色条（只靠底色在屏幕边缘容易漏看）。
配色按语义选，不按好看选：**琥珀=还没开始（可取消）**、**红=正在占用（此刻在花你的东西）**、
**绿=已归还（没占着任何东西）**。`test/hud-test.ps1` 的 C18 五臂直接读像素断言这三色互不相同且各自主导。

窗口属性（`test/hud-test.ps1` 实测）：`WS_EX_TOPMOST | WS_EX_NOACTIVATE`，`ShowActivated=false`，
**不加** `WS_EX_TRANSPARENT`（按钮要能点），启动前后 `GetForegroundWindow()` 不变。
**空白穿透**用 `WNDPROC` 子类化：按钮矩形外返回 `HTTRANSPARENT`，按钮内交回 WPF。
（`HwndSource` 的 hook 收得到 `WM_NCHITTEST`，但返回值不影响命中测试——实测失败方案，见
`scripts/probe-hittest-children.ps1`。）

## 三个键，别记混

| 想做什么 | 键 | 说明 |
|---|---|---|
| **打断正在进行的接管** | **`Ctrl+Alt+X`** | 本机实测注册成功的那个。候选表：`Ctrl+Alt+X` → `Z` → `C` → `V` → `B` → `N` → `Ctrl+Shift+X` → `Ctrl+Alt+Shift+X`，取第一个能注册的；**HUD 上显示的是真的那个**，不是文档承诺的那个 |
| 同一件事的备用手段 | **点 HUD 的「取消」/「停止」按钮** | 按钮与热键写的是同一个标志，没有优先级 |
| **暂停整个引擎**（不只是当前动作） | **`Ctrl+Alt+Q`** | 本机被别的程序占了（Win32 1409），实际注册为 **`Ctrl+Alt+W`**，`status` 里 `pauseHotkey=` 会如实报。**暂停也会立刻中断正在进行的接管** |
| 宿主取消 | 无键 | `exec.signal` → latch 文件，引擎每 50 ms 轮询 |

中断键与暂停键是**两个不同的东西**，这一点容易混：中断键只在接管期间存在（HUD 窗口拥有它，窗口销毁即注销），
暂停键是常驻的服务端开关（拒绝后续所有动作，并打断当前接管）。
## 三路中断

三条路写的是**同一个**标志/文件，所以不存在「哪个才算数」：

1. **HUD 的停止按钮** → `[WpmCtl]::TakeoverAbort = true`（跨线程只写 volatile，不做
   `Dispatcher.Invoke`——那条路实测 1818 ms 且有时不返回）。
2. **全局中断键** → 候选表从 `Ctrl+Alt+X` 起逐试，注册成功者写进 `AbortChordLabel`，
   **HUD 显示的是真的那个键**；全失败显示「中断键不可用，请点按钮」，不伪造。
3. **宿主取消**（`exec.signal`）→ Node 写 latch 文件
   `%LOCALAPPDATA%/wpm/takeover-abort.<worker pid>`，引擎每 50 ms `Test-Path`。
   **为什么是文件**：worker 是单线程的，动作进行中读不到新请求，所以进程内标志不够。

中断结果不是故障：返回 `takeover_aborted`，并**仍带** `cursorRestored` 与 `injectedChars`，
让读者知道做到哪一步。要接着做就重新发起（不会从断点续写）。

## 光标：借了必须还

- 移动前先读存证（`GetCursorPos`），移动后**读回校验**；读回不等于请求时 `cursorMoved=false`。
- 复位放在**同一个** `try/finally` 里：成功、异常、拒绝、中断四条路都到那里。
- 复位结果同样是读回：`cursorRestored=false` ⇒ 下游 `proof=fail`，理由写「借了未还」。
  **这是唯一一条硬红线**：桌面静不静都不能替它辩护。
- `scripts/check-takeover-path.mjs` 的 G4 把「移动与复位同处一个 try/finally」做成**静态**断言——
  运行时采样只能证明「这次没发生」。

## 键盘：只在接管档、只在前台、只能打字

- **S1 前台即目标。** `SendInput` 把键送进**当前前台**窗口，不看「你以为的目标」。实测
  （`scripts/probe-sendinput-unicode.ps1`）：B 在前台时，文本落到 B，A 什么都没收到。
  所以注入前断言 `GetForegroundWindow()==target`（子窗按根窗比对），抬不起来就拒绝
  `keyinject_unavailable`，**绝不盲注入**；发送瞬间还会再断言一次（预警窗口期间桌面可能变）。
- **S2 逐字可中断。** 每 8 字符或 50 ms 查一次中断；命中即停，返回**实际**发出的字符数。
- **S3 不动鼠标。** 只构造 `INPUT_KEYBOARD`；门禁禁止 `MOUSEEVENTF_*` 常量，结构上点不了。
- **字符方案：** `KEYEVENTF_UNICODE`（逐字），不受键盘布局与死键影响，中文/emoji 可用。
  **代价**：不带硬件扫描码，极少数只认扫描码的目标（某些游戏、远端 IP-KVM）不响应——已知限制。
- **effect 只能报 `reported-by-send`**：`SendInput` 返回的是「入队事件数」，不证明目标处理了。

## 终端：这条承诺被实测撤回

0.2.0 的计划是「终端无门 → 用键盘注入驱动它」。**实测否决**（2026-11-23，本机）：

| 探针 | 做法 | 结果 |
|---|---|---|
| `scripts/probe-console-inject.ps1` | 新建专用 Windows Terminal 窗，`KEYEVENTF_UNICODE` 逐字注入一条命令 + Enter | SendInput 接受 **242 事件**，`foregroundIsTarget=true`，Enter 已发，**文件未生成** |
| `scripts/probe-console-scan.ps1` | 同窗口，改用布局扫描码（`KEYEVENTF_SCANCODE` + `VkKeyScanW`） | **262 事件**，前台正确，**同样未执行** |

结论：本机终端**不接受合成输入**（GUI 目标正常——同一套代码在 WinForms 文本框里中文落字成功）。
因此 `terminal_no_door` **保留**，理由改成「换一个真有门的目标」，而不是把注入写成下一步。
**终端仍然不可写、不可读**：没有可用门，也没有 UIA `Document`，注入又无效——
不要从本文读出「能驱动终端」的暗示。

## 拒绝码与下一步

| 码 | 层 | 触发 | 下一步 |
|---|---|---|---|
| `takeover_unavailable` | decision | 请求了接管，但设置关着或 HUD 没起来 | 打开 `takeoverAllowed`；或去掉 `takeover:true` 用静默档 |
| `keyinject_unavailable` | decision | 注入不在接管档内／开关关着／目标不是前台且抬不起来 | 自己把目标切前台（或先 `focus`），或关掉 `keyInput` |
| `takeover_aborted` | runtime | HUD 按钮／中断键／宿主取消 | 读 `injectedChars` 知道做到哪；要接着做就重发 |

细节与三方对齐规则见 [refusals.md](refusals.md)。

## 测试与门禁

| 命令 | 覆盖 |
|---|---|
| `node scripts/check.mjs` | 11 道闸，含「光标/注入白名单」与「接管路径 G1–G5（带注入自测）」 |
| `powershell -STA -File test/hud-test.ps1` | 窗口属性、**不抢焦点**、三段相位、按钮/热键写同一标志、实际 chord |
| `powershell -STA -File test/takeover-test.ps1` | I1/I3/I4/I5 不变式、正常与中断路径的光标回位、决策臂 |
| `powershell -STA -File test/keyinject-test.ps1` | K1（非前台零注入）、K3（长文本可中断）、K4（Unicode 落字）、K5/K6（双闸与 effect） |

**这三个桌面测试不在 `check.mjs` 里**：它们会移动真实光标、注入真实按键，而门禁是给「随时可以跑」用的。
它们是手动臂，结果记录在计划的 checklist 里。