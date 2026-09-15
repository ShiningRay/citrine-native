# 原生自绘能力（area）交付分析

日期：2026-09-15 · 目标分支：各仓库当前工作区（citrine-native / citrine-sheets / citrine-market-terminal）
设计依据：[docs/design/native-area.md](../design/native-area.md)（接口已冻结）

## 目标

补齐 citrine-native 缺少的三类能力（视觉、点击、键盘），让两个 dogfooding demo
（citrine-sheets、citrine-market-terminal）能在 CRuby 原生窗口里跑起来并完成核心交互。

## 交付基线说明

- 框架改动只在 `citrine-native`（一个 writer：NA-1）
- 两个 demo 的移植分别在各自仓库（SHEETS-1 / MARKET-1，互不重叠，可并行）
- 独立验收由未参与该任务开发的执行者承担（NA-2 / SHEETS-2 / MARKET-2）
- 本机运行前提：`export PATH="$HOME/.asdf/shims:$PATH"`（libui 装在 asdf 的 Ruby 3.4.8）

## 交付状态（收口：2026-09-15 提交发布）

| 任务 | 状态 | 说明 |
|---|---|---|
| NA-1 框架能力 | ✅ 开发 → 验收（pass）→ 修复 NA-1c → 复审 NA-2b（pass）→ 收尾 NA-1d → 增量复审 NA-2c（**pass**） | 套件 120 runs / 340 assertions（GUI 0 skip）；NA-2c 独立复现：定时器闭包零增长（真 GUI 41 tick + 354 帧 `@closures` 增量 0）、focus 新语义对 disabled/游离视图/非 key window 都如实 false、提醒三判据的阈值边界（23.9 报 / 24 不报）逐点核对；遗留 5 条 P3（判据②对滚动面板误报、判据③瞬态数字、§5.7.2 表注不可复现、focus false 三种含义、F1 标题旧措辞）→ 已入 backlog F13–F17，随下一轮处理 |
| SHEETS-1 sheets 移植 | ✅ 开发 → 验收（pass）→ 修复 SHEETS-1c → 复审 SHEETS-2b（pass）→ 清理 SHEETS-1d | D1/D2/D3 全部修复并被复审独立复现（真 OS 按键 A/B：oneshot 版仍停在 `NSTextView`，工作区 `areaView` 且方向键/打字/Enter/⌘Z 生效；根 stack `flex_grow` A/B：596×684/27 行 ↔ 596×232/8 行；D3 录制器+OCR 无叠字）。SHEETS-1d：提示不再被重试 tick 点亮（终态）、焦点在公式栏时不抢（`editor_input_seen?`）、文档口径统一、`clip_rect` 说法更新。native 58/177，浏览器 48/203 + stubs 116 + parity 95 行 |
| MARKET-1 terminal 移植 | ✅ 开发 → 验收（pass + P1/P2）→ 修复 MARKET-1c → 复审 MARKET-2b（blocked：新 P1）→ 修复 MARKET-1d（开发完成，报告因额度中断） | MARKET-1d 已落地：**持仓分页**（`PAGE_SIZE` 行/页 + 翻页）让中列不再被吃光——真窗口 6 只持仓时 chart = 461×164（≥150），四面板全在画；冒烟加"买 6 只"场景；`native:smoke` 逐面板 draws/图元/尺寸断言。协调者复跑：native:test 85 runs / 875 assertions 全绿、`native:smoke` ✅（档位 5、chart 461×164）、浏览器 29/238 不回归 |
| 独立验收记录 | NA-2 / SHEETS-2 / MARKET-2 / NA-2b / SHEETS-2b / MARKET-2b / NA-2c 已完成 | `/tmp/citrine-reviews/*.md`（含证据与反驳） |

### 本轮遗留（全部已入 backlog，不阻塞"能跑"）

- 框架 P3 ×5（`native-area.md` §2.1/§5.1 旧措辞、判据②对滚动面板误报、判据③瞬态数字、§5.7.2 表注不可复现、focus false 三种含义）→ backlog F13–F17。
- `citrine-sheets/native/README.md` 的 `clip_rect` 说法待同步 NA-1d 后的口径 → backlog D2。
- 终端小窗口可读性（数值列零间距、「持」徽标与截断文字重叠 5.3px、量能截断到丢单位）与 SIGALRM 强杀段错误 → backlog F18/F19。
- 真人键鼠投递（TCC 拦自动注入；键盘已由验收者用 `CGEventPost` 验证过一轮，鼠标需人手）。

### 交付基线快照

所有改动**未提交**；各仓 `git status` 即交付范围（见下"提交"）。文件 sha1 清单随提交生成（`git rev-parse HEAD` + `git diff --stat`），验收者可用它锁定被审版本。

### 验收者独立做出的修正（对开发者结论的反驳，值得留痕）

- **⌘ 规则**：NA-1 报告说"带 ⌘ 一律返回 0"，NA-2 用真 OS 投递证明**没实现**（⌘H 被面板吞掉）；且报告的"⌘Q/⌘W 会被吞"例子不成立（libui 默认菜单 Quit 项没有 keyEquivalent，真反例是 ⌘H）。→ NA-1c 修，NA-2b 复验通过。
- **D2 根因（两次反转）**：SHEETS-2 判"框架限制（滚动面板不能 stretchy）"→ NA-1c 用量测反驳（与滚动无关，是 libui 嵌套 box 的 Auto Layout + `clipsToBounds=NO` 造成的"绿色像素溢出"假象）→ SHEETS-1c 再定位到**应用侧根元素没声明 `flex_grow`**（框架按根元素自己的样式追加 stretchy）。NA-2b 又否证了 NA-1c 写进文档的"每个嵌套 box 至少一个 stretchy 子控件"规则（既不必要也不充分），正确判据是"**参与拉伸的 box 自己要在父容器里有 stretchy 尺寸**"→ **NA-1d 已改文档（§5.7.2 重写表格与判据，标注整棵树）与提示文本**。
- **`Clip*` 理由**：NA-1c 说 `Clip*` 含滚动条占位；NA-2b 逐帧核对证明 `Clip*` **从不大于视口**（`760×544` 是 NSScrollView 的 frame），真实旧缺陷是"脏区条带化"。→ **NA-1d 已纠正文档（§5.2/§5.7.3）**。
- **KVC retain 因果**：`"visibleRect"` 是 immortal 常量串，retain 对它无意义；但 ≥12 字符的键是真字符串，不 retain 会 exit 133。→ **NA-1d 已改成边界描述（含代码注释）**。
- **新发现（必修）**：定时器每 tick 漏一个常驻闭包（`timer.rb` → `queue_main` → `@closures` 只增不减；50ms 定时器 5 秒 130 个）→ **NA-1d 修好**：定时器改走 `queue_main_once`（执行后释放引用），桩测锁"只用一次性槽"、真控件冒烟锁"~12 tick 后常驻闭包新增 ≤ 2"。
- **`focus` 返回值（NA-1d 加强）**：NA-2b 判"只转达 `makeFirstResponder:` 的 BOOL 就诚实了"；NA-1d 实测（macOS 26 / 探针 5）**只要窗口是 key window，那个 BOOL 对不接受 first responder 的目标也返回 YES**（并把窗口自己设成 first responder）→ 只转达 BOOL 依然不诚实。最终语义：**返回 true ⇔ 窗口的 `firstResponder` 真的是这个面板（或它的后代）**；冒烟里有判别用例（游离视图：AppKit 原值 YES、框架返回 false）。
- **文本缓存消融**：NA-2 独立复现（141fps → 7.8fps；不释放时 libui 报泄漏 + SIGTRAP）→ 保留理由成立。

### 交付基线快照

所有改动**未提交**；各仓 `git status` 为交付范围（citrine-native：框架新增/修改；citrine-sheets：`native/**` + `bin/native` + 少量既有文件适配；citrine-market-terminal：`native/**` + `bin/native` + `Rakefile`）。复核者指出"框架文件在验证期间被并发修改导致一次半成品状态"——所有修复轮跑完后我会在本文档附一份文件 sha1 清单作为可锁定的基线。

### 待用户决定

| 事项 | 说明 |
|---|---|
| ⌘B 只能加粗不能取消 | `citrine-sheets/app/application.rb:312` 的既有共享缺陷（读不存在的 `@active_row/@active_col`，恒 `bold: true`）。修它会改变浏览器行为，两个验收者都标为"需单独决策"，**未动** |



已记录、待统一处理的框架侧小问题：

1. `watch:` prop 会触发核心的「Proc 不是响应式属性」提醒（噪声）——SHEETS-1 已绕开（组件级
   `watch` + `AreaHandle#repaint`）；框架侧可考虑对自身消费的 prop 静音。
2. `window_key` 转发走 `Component#handle_key`，若组件自己定义了同名方法（demo 的
   `Application#handle_key(ev)`）会签名冲突——浏览器侧同理（DOM 渲染器同一入口），
   属于"组件别覆盖核心方法名"的既有约定，已在 sheets 原生 README 记明。
3. `uiAreaSetSize` 对非滚动面板会让 libui abort（exit 134）——适配层已改成"只在滚动面板落地
   + dev_mode 提醒"，属实测结论，已进 GOALS 风险清单。


## Windows 平台验证（2026-09-15 追加）

上述交付全部在 macOS 上完成；同日在 **Windows**（Ruby 4.0.6 x64-mingw-ucrt + libui 0.2.4
预编译包）复验并跑通两个 demo：

| 项 | 结果 |
|---|---|
| 框架 `bundle exec rake`（含 `CITRINE_NATIVE_GUI=1` 真窗口） | **120 runs / 345 assertions / 0 failures / 0 skips** |
| sheets `bin/native` | 起窗、网格绘制、点击选格、方向键、打字 `123`+Enter 提交重算全部实测通过（PowerShell 像素采样验证：方向键后 188 个采样点变化、编辑后 172 个） |
| market `bin/native` | 起窗、行情每秒跳动（间隔采样 diff 1394/1192）、四面板绘制正常；`native:smoke` ✅（持 6 只走势图 **217px** ≥150） |
| sheets `native:test` | 58 runs / 184 assertions / 0 failures |
| market `native:test` / `rake test` | 85 runs / 1136 assertions / 0 failures；29 / 238 / 0 |

**为此落地的改动**（此前全部只验证过 macOS）：

- citrine-native：`libui_scenario.rb` 的 AppKitProbe 加 macOS 守卫（非 macOS 记 skip）；
  `Widgets::Libui#init` 幂等 + `shutdown` 复位（Windows 二次 init 报"类已存在"；多 App
  顺序复用 backend 时第一次 teardown 后必须允许重新 init）；冒烟场景两处布局补 flex_grow
  （Windows 的 stretchy 链严格，断链处 area 塌成 0×0 且 Draw 不触发——细节见 GOALS 变更日志）。
- citrine-market-terminal：`bin/native` 信号注册按 `Signal.list` 过滤（Windows 无
  HUP/QUIT/ALRM）；根 box 与三列所在 row 补 `flex_grow: 1`；**chart.rb 把三段行情文字
  （quote_head/quote_stats/tech_stats）从原生 label 改画进自绘面板**（Windows 上它们
  合计 ~119px 把走势图压到 71px 画不出蜡烛；画进面板后 217px，macOS 同步受益）。
  实测记录见其 `native/README.md` 新增的"Windows 平台"一节。
- citrine-sheets：无需改动（stretchy 链本来就完整）。

**遗留（macOS 侧待复跑）**：chart 文字并入绘制改变了 macOS 的布局（走势图应更高），
下次在 macOS 上复跑 `native:smoke` 与 `rake test` 确认；Windows 的 `WindowSize` 最小尺寸
下限不可用（macOS 专属 API），已有如实降级。

## 任务明细

### NA-1 原生自绘面板能力（框架）

```yaml
id: NA-1
package: citrine-native
module: native/area
status: in-progress
depends-on: []
```

- objective：`area` 元素（自绘面板）在真 libui 后端上可用——绘制图元、鼠标/键盘事件、
  重绘调度、定时器 API，且不破坏既有语义与测试。
- context：[docs/design/native-area.md](../../design/native-area.md)（冻结接口）；
  `lib/citrine/native/{widgets,widgets/libui.rb,widgets/memory.rb,renderer.rb,native.rb}`；
  GOALS.md 风险 7（libui 绑定的三条硬约束）。
- path：`citrine-native/lib/**`、`citrine-native/test/**`、`citrine-native/docs/**`
- verification：`bundle exec rake` 全绿；真控件冒烟脚本扩展到 area（绘制 + 中文文本 + 拆解无泄漏）；
  键/鼠标事件为"注册成功"，真实投递由人手验收一次。

### SHEETS-1 citrine-sheets 原生移植

```yaml
id: SHEETS-1
package: citrine-sheets
module: native
status: pending
depends-on: [NA-1]
```

- objective：`bin/native` 起真窗口；方向键移动、直接打字编辑、Enter 提交、Esc 取消、⌘Z 撤销、
  改一格后依赖重算与检查器同步更新。
- context：NA-1 的冻结接口；`citrine-sheets/app/**`（逻辑全部复用，只换视图）；
  `docs/design/native-area.md`。
- path：`citrine-sheets/app/panels/grid.rb`（去 `require "native"` 依赖）、
  `citrine-sheets/native/**`、`citrine-sheets/bin/native`
- verification：桩后端驱动的移植测试 + 真窗口手工/脚本验收；浏览器路径（rake check）不回归。

### MARKET-1 citrine-market-terminal 原生移植

```yaml
id: MARKET-1
package: citrine-market-terminal
module: native
status: pending
depends-on: [NA-1]
```

- objective：`bin/native` 起真窗口；行情按档跳动（暂停/1x/2x/4x）、蜡烛/分时重绘、
  点自选行切换标的、下单/撤单、持仓与统计更新。
- context：NA-1 的冻结接口；`citrine-market-terminal/app/**`（引擎与面板逻辑复用）；
  心跳由浏览器 `setInterval` 换成原生定时器。
- path：`citrine-market-terminal/native/**`、`citrine-market-terminal/bin/native`
- verification：桩后端驱动的移植测试 + 真窗口手工/脚本验收；`rake check` 不回归。

### NA-2 / SHEETS-2 / MARKET-2 独立验收

各由未参与对应开发的执行者承担，按设计文档第 4 节的验收场景与任务 verification 逐条核对，
产出记录（结论 pass/blocked、问题位置、证据）。
