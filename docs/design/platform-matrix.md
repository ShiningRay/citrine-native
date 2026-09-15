# 平台能力矩阵（原生后端的两种原生实现）

> 2026-09-15 首次入库（Windows 首测之后）。**唯一出处**：此前这些降级项散在 GOALS 风险清单、
> 两个 demo 的 README 与代码注释里，换平台排查时要拼三份文档。新增/修改降级行为时改这里。

图例：

- ✅ **一致**：两个平台都有实现，语义相同
- ⚠️ **如实降级**：平台没有对应能力，**返回值如实说"没做到"**（不假装成功）——调用方可以
  按返回值分支，或按文档走替代路径
- ❌ **未实现**：两个平台都没有，属能力缺口（见"缺口清单"）
- — **不适用**：该平台不需要这个能力

## 一、窗口与焦点

| 能力 | macOS | Windows | 依据 / 替代路径 |
|---|---|---|---|
| 挂载后键盘可达（激活应用） | ✅ `[NSApp activateIgnoringOtherApps:YES]`（ObjcBridge） | — 不需要：`uiControlShow` 之后系统即把焦点给窗口 | macOS 上不激活则**一个键也收不到**（设计 2.3）；Windows 无此问题所以 `window_activate` 是 no-op |
| `window_is_key?`（窗口是否为 key） | ✅ | ⚠️ 恒 `false`（ObjcBridge 不可用） | 只用于自检/冒烟断言，不参与业务 |
| `AreaHandle#focus`（把键盘焦点给面板） | ✅ 真实现：`makeFirstResponder:` 的 BOOL **∧** 窗口的 firstResponder 真的是目标或其后代 | ⚠️ 恒 `false` | Windows 上**点击面板即入焦点**（libui 的 `WM_LBUTTONDOWN` 自己 `SetFocus`），所以"挂载即自动聚焦"在 Windows 不可用——market 的快捷键提示因此写"必要时先点一下面板" |
| 窗口内容区最小尺寸 | ✅ `[NSWindow setContentMinSize:]`（app 侧，`WindowSize`） | ❌ 不可用 | macOS 只约束**交互式缩放**（程序化 setContentSize 不经过它）；Windows 只剩 libui 的内容自然尺寸兜底 |

## 二、布局与几何

| 能力 | macOS | Windows | 依据 |
|---|---|---|---|
| box 的 stretchy 链 | **宽容**：窗口直系子元素不给 `flex_grow` 也能拿到剩余空间 | **严格**：从根容器到面板**逐层**都要 stretchy，断链处 area 塌成 0×0 且 **Draw 一次都不触发** | 2026-09-15 四象限探针（根±stretchy × area±stretchy，只有"全 stretchy"拿到高度）；判定规则见 `native-area.md` §5.7.2 与 backlog F11/F24/F25 |
| 原生控件天然高度 | label ≈16 / button ≈24 | label 17 / button 25 | 同样的树在 Windows 上要多吃几十像素（market 的走势图因此从 71px 起步，重构后才回到 217px） |
| 滚动面板的 `clip_rect` | ✅ 精确可见区（`areaView.visibleRect`，不含滚动条；首帧有瞬态） | ⚠️ 回退 `Clip*`（**脏区**：非滚动面板是整窗、滚动帧只是新露出的条带），夹进声明的内容尺寸 | `area_clip` 的回退分支；Windows 上"只画可见区"的省算退化为"按脏区画" |
| `uiAreaSetSize` 对非滚动面板 | 终止进程（exit 134） | 同（libui 的 `uiprivUserBug`） | 适配层已拦住并提醒（F8） |

## 三、运行时与生命周期

| 能力 | macOS | Windows | 依据 |
|---|---|---|---|
| 可捕获的终止信号 | INT / TERM / HUP / QUIT / ALRM | INT / TERM（HUP/QUIT/ALRM 不存在，`trap` 直接 `ArgumentError`） | 框架侧的注册入口是 `App#trap_quit!`（按 `Signal.list` 过滤，返回装上的名字；`Citrine::Native.run(…, signals: :default)` 一步到位，**默认不接管**）。退出路径见 `citrine-market-terminal/native/README.md`。**验证边界**：Windows 上无法定向投递 Ctrl+C 给别的进程（Ruby 的 `Process.kill("INT", pid)` 是控制台级事件、连发送方一起终止），所以"真信号到达"只在**进程内**验证（`test/app_test.rb` 发送 INT 到自身），跨进程路径靠 macOS 侧的人工实测 |
| 二次 `uiInit` | 静默 no-op | 报错（`registering utility window class; code 1410 类已存在`，打到 stderr） | 适配层 `init` 已加幂等守卫 + `shutdown` 复位（GUI 冒烟里多个 App 顺序复用同一 backend） |
| `uiMainStep`（自己泵循环） | 本机 libui 0.2.4 **段错误**（最小复现：起窗口 + `main_step(0)`） | 未测 | 因此定时器一律走"后台线程 + `uiQueueMain`"，不自己泵循环 |
| libui 撞到内部错误 | 进程 abort（exit 133/134） | 同 | 真控件行为**只能**放在子进程冒烟里跑（`test/support/libui_scenario.rb`） |
| 队列回调 / 定时器 | ✅ `uiQueueMain` | ✅ 实测可用（心跳、自排队动画、GUI 冒烟全过） | Windows 首测结论：这两条与 macOS 无差异 |

## 四、缺口清单（两平台都没有）

| 缺口 | 说明 | 去向 |
|---|---|---|
| 原生控件本身着色（字体 / 颜色 / 背景） | libui 无公开 API；只能走平台直通桥（macOS `setFont:`/`setTextColor:`、Windows `WM_SETFONT`/`WM_CTLCOLORSTATIC`） | backlog F27（L3） |
| 窗口最小尺寸（Windows） | 见上表 | backlog E4 |
| `AreaHandle#focus`（Windows） | 见上表；user32 `SetFocus` 可实现 | backlog E4 |
| 平台能力矩阵的自动化守卫 | 这张表本身没有测试锁——新增降级项时容易忘记补两列 | 建议随 E1 的 CI 一起补一条"降级项清单"断言（待办） |

## 五、约定（写平台代码时）

1. **降级必须如实**：拿不到就返回 `false` / 回退到有文档的路径，**不要假装成功**——
   NA-1d 的教训：`AreaHandle#focus` 早期"只要窗口是 key 就返回 true"，调用方按返回值判断
   也察觉不到 AppKit 拒绝。
2. **平台分支收敛在适配层**（`widgets/libui.rb` 的 `ObjcBridge` 模式）：渲染器与组件代码
   不写 `if windows?`；`ObjcBridge#available?` 为 false 时如实上报。
3. **本表与代码同步**：改降级行为时同时改本表；`docs/INDEX.md` 与本表互相引用。
