# GOALS.md — citrine-native 设计与计划

> Citrine 组件的 CRuby 原生运行时。本文档是本仓库的主文档：定位、技术选型、
> 架构设计、决策与 Roadmap 全部记录于此（沿用 citrine 主仓的 GOALS.md 惯例）。

## 一、定位与愿景

**一句话**：用纯 Ruby 写的 Citrine 信号式组件，不经 Opal、不编译成 JS，
`ruby app.rb` 直接在 CRuby 里启动为一个原生控件桌面应用——Shoes 的 2026 年版。

```ruby
# examples/counter.rb（N1 验收通过：真窗口 + 点击精确 +1）
require "citrine-native"

class Counter < Citrine::Component
  state :count, default: 0        # 三宏收关键字参数（不是 state :count, 0）

  def view
    stack(gap: 8) do
      label { "计数：#{count}" }
      button(on_click: -> { self.count += 1 }) { "点我 +1" }  # 按钮文本走 block
    end
  end
end

Citrine::Native.run(Counter, title: "计数器", width: 400, height: 300)
```

> 立项时本节写的 `state :count, 0` 与 `button("点我 +1", on_click: …)` 都不是 citrine DSL
> 的真实形态（`state` 只收关键字 `default:`；`button` 的文本走 block），N1 实现时已修正
> （见变更日志）。

**与 citrine 主仓的关系**：本 gem 是 Citrine 的一个**外部 Port**（插件）。
citrine 的平台无关核心（signal / node / component / renderer 基类）本身就在
CRuby 下可直接运行（主仓红线的副产品：280 项单测不需要 Opal），`Citrine::Renderer`
基类就是 Port 的扩展协议。本 gem 只需：

1. 依赖 citrine gem 的核心；
2. 实现一个 `NativeRenderer < Citrine::Renderer`（`lib/citrine/renderer.rb`
   的平台钩子：`setup_root / create_dom / attach / detach / apply_props /
   bind_events / set_text / setup_widget / attach_before`，加 `reactive?`）；
3. 提供应用入口与主循环（`Citrine::Native.run`）。

同一份组件代码因此有四个去处：浏览器 DOM（Opal）、Canvas（Opal）、
SSR 字符串（CRuby）、**原生控件（本 gem，CRuby）**。

**为什么这是 Shoes 精神**：Shoes 的核心不是某个 API，而是"脚本即应用"——
解释器直接跑 GUI、没有构建管线。本 gem 还原这一点（甚至比 citrine 主仓的
WKWebView 壳更纯粹：连 JS 编译都没有了），打包壳按用户要求**暂不做**，
留作远期与主仓 M4b 汇合的选项。

## 二、非目标（明确不做）

- **打包壳 / 应用分发**：本期不做 `.app` / `.exe` 打包（主仓 M4a 的 WKWebView 路线
  已覆盖 Web 渲染的打包；原生打包是另一个课题，待运行时成熟后单独立项）
- 移动端（Hermes/RN 桥接属主仓 M4b，与本路线无关）
- CSS 全集、动画、富文本、自绘控件（v0 只用原生控件的固有能力）
- 修改 citrine 核心：若实现过程中发现核心缺口，回主仓提 PR 走完整流程
  （main 受保护），不在本仓打补丁
- 多后端并行：v0 只做 libui 一个后端，GTK 备选只停留在接口设计上

## 三、UI 库选型（决策 N-1）

| 候选 | 维护活性 | 原生控件 | 依赖重量 | 控件集 | 与 stack/row 布局契合 | 结论 |
|---|---|---|---|---|---|---|
| **libui**（kojix2/libui gem，底层 libui-ng） | 活跃 | ✅（Win/Cocoa/GTK） | 极轻（一个动态库） | 小但够用 | ✅ box 模型同构 | **v0 采用** |
| GTK3/4（ruby-gnome） | 活跃、最成熟 | ❌（自绘外观） | 重（brew 装一堆） | 最全 | 一般（box 有但概念多） | 备选第二后端 |
| Tk（tk gem） | 存活 | ❌ | 中 | 中 | 一般 | 否决（外观与体验过时） |
| Qt（qtbindings） | 停滞 | ❌ | 极重 | 全 | 一般 | 否决 |
| wxWidgets（wxruby） | 停滞 | ✅ | 重 | 全 | 一般 | 否决 |
| Glimmer DSL for LibUI | 活跃 | ✅ | 轻 | 同 libui | — | 否决（它是 DSL 层，与 Citrine DSL 职责重叠；但其存在证明 libui 绑定可用） |

**定案：v0 后端 = libui**。理由：

- 唯一"原生控件 + 轻量 + 活跃维护"三者同时成立的选项；Glimmer DSL for LibUI
  已在生产验证过这条绑定链路的可行性
- 布局模型只有 box（横/竖）——与 Citrine 的 `stack`/`row` 语法糖**天然同构**，
  不需要自己实现 CSS 布局引擎
- Shoes 当年的 Cairo 自绘路线换来了跨平台一致性、丢了原生观感；libui 反过来
  用各平台原生控件，观感正确，且控件集小的短板正好被 Citrine 的词表本就很小
  （box/label/button/text_input/check_box 为核心）所掩盖

**已知代价**（挂号，不是阻挠项）：

- libui 控件集小：没有表格（有 table 但能力有限）、没有富文本、菜单/对话框能力基础
- 动态库分发：libui gem 依赖 libui-ng 共享库，macOS 上需确认 gem 自带或 brew 安装
  （N1 的验收前置动作）
- 无 CSS：样式只能做极小子集（见第五节）

**接口预留**：控件创建收敛在一个薄适配层（`Native::Widgets`），
渲染器不直接调 libui API——未来加 GTK 后端时只替换适配层。

## 四、架构设计

### 4.1 分层

```
应用组件代码（平台无关：Citrine::Component + 三宏 + 元素 DSL）
        │
citrine 核心（gem 依赖）：Signal / Effect / Node / Renderer 基类 / Style 归一化
        │
citrine-native（本 gem）：
  ├── NativeRenderer < Citrine::Renderer   # 节点树 → 控件树，Effect 装配复用基类
  ├── Native::Widgets                       # 薄适配层：create/append/remove/set_*
  └── Native::App                           # 窗口 + 主循环（Citrine::Native.run）
        │
libui gem → libui-ng 动态库 → 平台原生控件（Cocoa / Win32 / GTK）
```

### 4.2 Renderer 钩子 → libui 映射

基类（`citrine/lib/citrine/renderer.rb`）负责节点树管理、Effect 装配、
块级重建、keyed 复用——**全部复用**，本 gem 只实现平台钩子：

| 钩子 | libui 实现要点（N1 已实现，实测结论见变更日志） |
|---|---|
| `setup_root(root, element)` | element 语义重定义为窗口描述（title/尺寸/margined），创建 `uiWindow` + 根容器（竖排 box，窗口的唯一直系子控件） |
| `create_dom(node)` | 按 node.type 创建控件（`node.dom` 从"DOM 元素"重解释为**控件句柄** `Fiddle::Pointer`）；未支持元素直接报错并给替代建议 |
| `attach(node, parent)` | `uiBoxAppend`（box 天然顺序追加）；**搬运语义**：已在容器里的控件先摘再追加（libui 撞到"控件已有父容器"会 abort） |
| `attach_before(node, parent, anchor)` | `uiBoxDelete` 只摘除不销毁 → 适配层可无损重排：摘掉锚点及其后的兄弟、追加本控件、再按原序回挂。**不需要容器级重建**（风险 2 关闭） |
| `detach(node)` | 先摘后 `uiControlDestroy`（带父容器销毁会 abort；容器销毁会连坐子控件，所以顺序必须是子先父后） |
| `apply_props(node)` | 幂等重设：禁用态、容器 padding（gap）、未支持样式/属性的 dev_mode 提醒 |
| `bind_events(node)` | 按钮 `uiButtonOnClicked` / 输入 `uiEntryOnChanged` / 勾选 `uiCheckboxOnToggled` → 平台无关事件视图 → `Component#handle_event`；闭包在派发时从 `node.props` 现取处理器（复用后新处理器自然生效） |
| `set_text(node, text)` | `uiLabelSetText` / `uiButtonSetText` / `uiCheckboxSetText`，并镜像进 `node.text`（基类的"清空旧文本"逻辑依赖它） |
| `setup_widget(node)` | 受控控件初值 + `value:`/`checked:` 传 Signal 时的"信号 → 控件"Effect（控件 → 信号在 bind_events） |
| `reactive?` | `true`（信号驱动更新正是本运行时的存在意义） |

**主循环与拆解顺序**（N1 定案，`App` 实现）：`uiInit` → 建窗口挂组件 → `uiControlShow`
→ `uiMain`；关窗回调一律返回 0（**不让 libui 自行销毁窗口**），由适配层 `quit`，
`uiMain` 返回后按"卸载组件（dispose 全部节点、销毁控件、跑 on_unmount）→ 销毁窗口
→ `uiUninit`"的顺序拆解。顺序颠倒两头都会踩：窗口先走，卸载就动到已释放的控件；
组件不卸载就先销毁窗口，钩子与 Effect 释放全被跳过。

### 4.3 元素词表 → 控件映射（v0）

| DSL | 控件 | 备注 |
|---|---|---|
| `stack { }` | `uiNewVerticalBox` | |
| `row { }` | `uiNewHorizontalBox` | |
| `box` | box（按 direction） | 无方向时默认 row，沿用主仓 G-8 提醒；`direction` 必须是静态值（控件创建后不能换方向） |
| `label { "..." }` | `uiNewLabel` | 文本经 set_text |
| `button(on_click:) { "..." }` | `uiNewButton` | 文本走 block（DSL 不收位置实参） |
| `text_input(value:, type:)` | `uiNewEntry` / `uiNewPasswordEntry` | `type: "password"` 直接映射；`placeholder` **不支持**（libui 的 entry 没有占位文本），dev_mode 提醒 |
| `check_box(checked:, on_change:)` | `uiNewCheckbox` | **无内容位**（与 DOM 的 `<input type=checkbox>` 一致）：标签是相邻 `label { }`；传块会被 DSL 静默丢弃 |
| `element(:area, on_draw:, …)` | `uiNewArea` / `uiNewScrollingArea` | **NA-1 新增**：自绘面板（绘制图元 + 鼠标/键盘 + 重绘调度 + 面板句柄），冻结接口与实测约束见 [docs/design/native-area.md](docs/design/native-area.md) |

S2-1 扩充的 HTML 词表（a/img/ul/li/table/form/select/textarea/video…）与
`element(:任意标签)` 逃生舱**在 v0 不支持**：原生侧没有对应概念，
遇到未支持元素直接报错并给出替代建议（`UnsupportedElementError`，
含"该用什么替代/留待哪个里程碑"的提示），不静默降级。
后续按需逐个评估（textarea→`uiNewMultilineEntry` 之类）。

### 4.4 主循环与线程模型

- libui 的 `uiMain` 占主线程跑事件循环；所有控件回调、Signal 写入、Effect
  重跑都发生在主线程——**没有跨线程问题**，`Citrine.batch`（S1-1）直接可用
- GVL 注意事项：长任务（网络/文件）必须放后台线程 + 回主线程写信号
  （libui 提供 `uiQueueMain`）；这一点写进 README 的使用约束
- 定时器：v0 不提供框架级 timer API；`effect` 宏里的 `Thread` + `uiQueueMain`
  是临时方案，正式方案留待 N4 评估

### 4.5 样式：能力矩阵（L1 + L2，2026-09-15）

Citrine 的样式是一份 snake_case 的 IR（决策 #10）。原生控件没有 CSS，**每个键的落点都
登记在 [docs/design/style-matrix.md](docs/design/style-matrix.md)**（代码侧唯一事实来源
是 `lib/citrine/native/style_matrix.rb`，72 个键），三档：

- **`:mapped`（自动映射）**：`gap` / `padding*`（→ `uiBoxSetPadded`，只有 0 / 非 0 两档）、
  `flex_grow` / `flex`（数值 > 0 → 追加时 stretchy）、`display` / `flex_direction`
  （由 stack / row 合成）
- **`:painted`（只能自绘）**：视觉底板 `background` / `border` / `border_color` /
  `border_width` / `border_radius` —— **`element(:area)` 自动消费**（框架在 `on_draw`
  之前画一次底板，应用只管内容；样式每帧现读，`style: -> { … }` 照样响应式）；
  文字类 `color` / `font_size` / `font_weight` / `font_family` / `text_align` /
  `letter_spacing` / `line_height` / `font_variant_numeric` 要在 `on_draw` 里用
  `Painter` 表达（原生 label / button 的字体与颜色没有公开 API）
- **`:ignored`（无对应概念）**：尺寸（`width` / `height` / `min_*` / `max_*`）、
  `margin*`、对齐（`align_items` / `justify_content`）、定位与层叠、`box_shadow` /
  `opacity` / `transform` / `transition`、溢出与省略号（要自绘）等

映射到控件自身的既有语义（不算样式）：`disabled` 透传属性 → 控件禁用态。

**结构性天花板**：libui 没有"既能容纳原生子控件、又能自绘背景/边框"的容器——想要
自定义视觉的区域必须是 area（里面不能嵌原生控件）；要让原生控件本身着色，只能走
平台直通桥（macOS `setFont:`/`setTextColor:`、Windows `WM_SETFONT` 一类），当前未实现
（backlog F27）。因此"CSS 正确渲染"不是本后端的目标，目标是**原生控件观感 + 明确的
能力边界**（对照：Shoes 的 Cairo 路线用一致性换掉了观感）。

**`css_class` 的现状**：整块丢弃（一条去重提醒，一个声明都不生效），体量是 167 个类名
+ 231 条 CSS 规则；但它只出现在浏览器侧视图里，原生侧的绕行方案是"另写视图 + `Theme`
令牌 + area 自绘"。要不要做"类名 → 原生样式"的桥（F28）取决于**是否要单视图双渲染**，
见 [style-matrix.md 第九节](docs/design/style-matrix.md) 与风险 10 的开放问题。

原则：**未映射的样式键/属性在 dev_mode 下提醒，绝不静默丢弃**（主仓 F11 的教训）；
提醒按三档说清"为什么 / 怎么办 / 去哪看"，都指向样式能力矩阵。元素级的不支持
（如 textarea）则**始终报错**——那不是"样式降级"，是页面结构缺一块。
`Citrine::Native.run` / `.start` 默认打开 dev_mode（脚本即应用，没有构建管线），
可用 `dev_mode: false` 关闭。

## 五、组件代码的可移植约束

组件想同时跑浏览器与本运行时，必须只依赖平台无关 API：

- 组件定义文件**不得** `require "citrine/browser"` / `citrine/canvas`
  （平台入口由启动文件选择，与主仓 examples/components.rb 的共享模式相同）
- 不碰 `Native`/backtick JS（本就只存在于 Opal 侧）
- 数值语义用 `Citrine::Num`（两端一致性的既有保障）
- 已知两端语义差异（v0，N1/N2 实测清单）：
  - `window_key` / `on_key` / `on_enter` **不支持**（libui 的 entry 不暴露按键事件，
    键盘事件需 area 控件或自定义控件，N4 评估）→ **回车提交在 v0 不可用**，
    Todo 示例改用「添加」按钮
  - `placeholder`、`autofocus`、CSS 类与 `id`/`aria_*`/`data_*` 等 HTML 专属属性
    保留但无效（dev_mode 提醒）
  - `ref:` 句柄是**控件对象**（`Fiddle::Pointer`）而非 DOM 元素
  - `on_change` 的载荷：check_box 收布尔勾选态（与 DOM 同口径），
    text_input 收新文本（原生侧专属；DOM 侧该组合行为未定义）
  - portal 的宿主只有"根容器"一个（原生没有 DOM body）：`target:` 只接受
    `:root`/nil，其余报错
  - 控件回调里的异常**只报不抛**（打到 stderr 并继续跑主循环）——不让异常穿过
    Fiddle/Objective-C 栈，避免把整个 GUI 带走
  - portal/suspense/fragment 的透明容器语义由基类保证：N1 起有测试实证
    （多根组件、占位切换、portal 落根容器）

## 六、Roadmap（计划）

| 里程碑 | 内容 | 验收 | 状态 |
|---|---|---|---|
| **N0** | 仓库骨架 + 设计文档（本文档） | gemspec/Gemfile/入口占位可 `bundle install`；本文档评审通过 | ✅ 完成 |
| **N1** | 最小闭环：NativeRenderer + App 入口，支持 stack/row/label/button | Counter 示例在 CRuby 起真窗口，点击精确 +1（对齐主仓 M0 Spike A 的验收口径）；`attach_before` 落位问题有结论 | ✅ 完成（`attach_before` = 无损重排，见变更日志） |
| **N2** | 输入控件：text_input 受控双向绑定（IME 在原生控件天然可用）、check_box | Todo 示例完整可玩（增删、勾选、回车提交） | ✅ 基本完成：增删/勾选可用；**回车提交不成立**——libui 的 entry 不暴露按键事件，已改为按钮提交并挂到 N4 |
| **N3** | 响应式语义回归：keyed 复用、块级重建、错误边界、透明容器在本后端的实证 | CRuby 单测覆盖 Renderer 语义（复用主仓 test/ 的测试思路，widget 适配层可打桩，CI 无需真窗口） | ✅ 完成（2026-09-15）：对齐清单入库（[docs/design/semantics-coverage.md](docs/design/semantics-coverage.md)：主仓 `renderer_test` 16 条逐条给出**承担方**，其余相关文件的分类见文档），本轮补 7 条断言（错误边界三变体、kebab 样式键、符号处理器、Signal 透传提醒两态），套件 157 runs / 654 assertions。**未复刻的 4 条**（无 key 复用的实例保持等）按分工归核心 Effect 测试，清单与判定写在文档第五节 |
| **N4** | 事件面与生命周期完整性：on_change/on_enter/on_focus/on_blur、禁用态、定时器方案 | 对照主仓元素/事件词表出支持矩阵，未支持项全部有 dev_mode 提醒 | ✅ 完成（2026-09-15）：支持矩阵入库（[docs/design/element-event-matrix.md](docs/design/element-event-matrix.md)：元素面 18 个核心标签逐个给出处置，事件面 23 个词条逐个给出 ✅/⚠️/— 与原因），补齐 7 条缺失的元素替代建议（`ol` / `option` / `thead` / `tbody` / `tr` / `td` / `th`），新增 `test/element_event_matrix_test.rb` 8 项把"未支持项必须在文档里有记录、未支持事件必须在 dev_mode 下提醒"变成机器校验。**仍不可用**：entry 上的 `on_enter`（libui 不暴露按键，已在矩阵文档记为候选实现） |
| **NA-1** | 自绘面板（area）：绘制图元 + 鼠标/键盘事件 + 重绘调度 + 面板句柄 + 定时器（冻结接口见 [docs/design/native-area.md](docs/design/native-area.md)） | 桩后端语义测试全覆盖；真控件冒烟含"画矩形与中文文本 + 尺寸/外接矩形合理 + 拆解无泄漏"；键/鼠标事件注册成功（合成结构体走真闭包） | ✅ 完成（2026-09-15，实测结论与限制见设计文档第 5 节；两个 demo 的移植障碍由此清除） |
| **N5** | dogfooding + 发布准备：移植一个真实应用（候选：beryl 的某个面板或 market-terminal 的简化版） | gem 0.1.0 发布（Trusted Publishing 沿用主仓 OIDC 模式） | ✅ **完成（2026-09-15 发布）**：dogfooding 已由两个真实应用满足（citrine-sheets / citrine-market-terminal 的原生版，都在 macOS 与 Windows 上跑通）；发布链路全部落地——版本 **0.1.0**（`version.rb`）、`CHANGELOG.md`、`.github/workflows/release.yml`（gate 矩阵 + gem 两 job：门禁 → 标签一致性校验 → 构建 → 附产物 → OIDC `gem push`）、gemspec 元数据、**发布手册 [RELEASING.md](RELEASING.md)**、**发布元数据对拍 `test/release_metadata_test.rb`**（两轮发布红灯各补 3 条断言：needs: gate / 两 job 的 Ruby 版本 / 校验先于构建）、**消费端冒烟 `rake consumer_smoke`（10 项）**。**发布本身已完成**：`v0.1.0` 标签触发的 Release 工作流全绿（红了两轮的复盘：ubuntu 上 libui GTK C 层 abort、`release-gem` 要求仓库在 workspace 根——详见变更日志），**rubygems.org 已上架 0.1.0**（API 元数据：依赖 base64 ≥ 0.2 / citrine ≥ 0.2 / libui ≥ 0.1），GitHub Release 附 `citrine-native-0.1.0.gem`，下载的发布产物本机装包 + 仓库外 require + 桩渲染冒烟全过；验收证据汇总见 [docs/plan/acceptance-0.1.0.md](docs/plan/acceptance-0.1.0.md)（N0–N5 逐条口径 ↔ 证据 + 未验证清单；"直连 rubygems.org 完整 `gem install`"待本机镜像同步/网络就绪补跑） |

**待你决定的事项集中在一处**：[docs/plan/backlog.md](docs/plan/backlog.md) 顶部的**决策清单 D-1…D-11**
（每条含"不决定的后果 / 选项 / 我的建议与理由 / 代价"，回一行编号 + 选项我就能接着做）。

远期（不在本 Roadmap 承诺）：GTK 第二后端、富文本/表格控件、打包壳
（与主仓 M4b 汇合）、菜单栏/系统托盘等桌面能力、**Windows 平台加固**
（CI / 平台能力矩阵 / Win32Bridge，见风险 9 与 backlog E1–E4）。

## 七、风险与开放问题

1. ~~**libui gem 的动态库分发**~~（N1 前置验证，**已于 N0 提前验证通过**）：
   libui 0.2.4 提供 arm64-darwin 预编译平台包，`bundle install` 直接装上、
   `LibUI.init/uninit` 冒烟通过——动态库随 gem 分发，"脚本即应用"体验成立。
   注意 Ruby 绑定顶层模块是 `LibUI`（不是 C API 的 `ui*` 前缀风格）
2. ~~**`attach_before` 落位**~~（**N1 关闭**）：`uiBoxDelete` 只摘除不销毁
   （实测：摘除后控件仍在分配表、`uiControlParent` 为 NULL），因此适配层可以
   无损重排——摘掉锚点及其后兄弟、追加、按原序回挂。**不需要容器级重建**，
   "细粒度更新"的卖点在本后端成立；代价是重排是 O(尾部兄弟数) 的原生调用
3. **无窗口环境测试**（**N1 起缓解**）：CI 不能开真窗口——渲染语义测试跑
   `Widgets::Memory` 桩后端（结构/文本/回调全可断言），真控件的创建/点击/重排/
   拆解跑**子进程**冒烟脚本（`test/support/libui_scenario.rb`）：默认不显示窗口，
   直接触发 libui 真正持有的回调闭包；`CITRINE_NATIVE_GUI=1` 才起真窗口跑
   `uiMain`。libui 撞到内部 bug 会 abort 进程，所以必须隔离子进程
4. **citrine 依赖版本**：开发期 `path: "../citrine"`；发布依赖 citrine ≥ 0.2
   （RubyGems 已上架）。若 N1~N4 发现需要核心新增钩子，版本约束相应抬升
   （截至 N2 未发现缺口，1 处文档级修正：`check_box` 无内容位、`state` 只收
   关键字参数——见变更日志）
5. **命名**（**已确认，2026-09-15**）：`citrine-native` 在 rubygems.org 上**未被占用**
   （查询 `/api/v1/gems/citrine-native.json` → 404）；上游 `citrine` 已上架 0.2.0，
   与本 gem 的依赖约束 `citrine >= 0.2` 一致
6. **上游缺口（N0 实踩）**：citrine 0.2.0 的 `sourcemap.rb` 用了 `base64`，
   Ruby ≥ 3.4 起它不再是默认 gem，而 citrine gemspec 未声明——作为依赖被
   消费时在 Ruby 4.x 下直接 LoadError。本仓 gemspec 已加 `base64` 过渡依赖，
   上游修复（citrine 主仓 gemspec 补声明，走 PR 流程）发布后移除
7. **libui 绑定的三条硬约束（N1 实踩，已在适配层吸收）**：
   - **回调闭包的生命周期**：libui gem 把 Fiddle 闭包挂在**句柄对象**上
     （`libui_base.rb`），句柄被 GC 回收 = 回调变野指针 → 适配层必须常驻持有
     句柄（`@handles`）
   - **销毁顺序**：`uiControlDestroy` 撞到"控件仍有父容器"直接 abort；容器
     销毁会连坐子控件（再销毁子控件 = double free）。适配层一律"先摘后销毁"，
     渲染器保证子先父后
   - **字符串与编码**：`*_text` 返回 libui 分配的 C 字符串（要 `uiFreeText`），
     且 Fiddle 不做编码推断（拿到的是 ASCII-8BIT）——适配层统一按 UTF-8 解释
8. **运行环境**：本机 asdf 的 Ruby 3.4.8 装了 libui；rbenv 的 3.3.5 没有
   （`bundle exec` 走哪个 ruby 取决于 PATH 顺序）。CI（N5）需要固定 ruby 版本 +
   `bundle install`；无 GUI 的 runner 只会跑桩后端测试，真控件冒烟自动跳过。
   **Windows 侧（2026-09-15 实测）**：Ruby 4.0.6 x64-mingw-ucrt + libui 0.2.4 预编译包，
   `bundle install` 直接可用（`Gemfile.lock` 已补 `x64-mingw-ucrt` 平台）；真控件冒烟
   不开窗也能跑，只有 GUI 模式需要真桌面。本机还**没有配置图像理解模型**（`dim image
   read` 缺 provider），窗口的视觉核对只能靠 `user32 GetWindowRect` 逐节点几何 + 截屏
   像素采样（2026-09-15 的验证就是这么做的）；配上视觉模型后截屏直读会快很多
9. **平台差异治理**：框架至今的实测证据几乎全部来自 macOS；Windows 首测暴露出
   "macOS 宽容、Windows 严格"的一类差异（box 的 stretchy 链、原生控件更高、二次
   `uiInit` 报错、信号集合不同）。已入 backlog：**F25**（根容器对应用隐藏却参与布局
   推理——"根元素必须自己声明 `flex_grow`"是替框架内部节点买单）、**F24 / F26**（把
   dev_mode 提醒从绘制期挪到挂载期，否则 Windows 的 0×0 面板永远不报）。
   **E1 / E2 已落地（2026-09-15）**：CI 覆盖 macos + windows 两种原生后端
   （`.github/workflows/ci.yml`，跑桩测与不开窗的真控件冒烟）；差异清单收进
   [docs/design/platform-matrix.md](docs/design/platform-matrix.md)（平台降级行为的唯一出处，
   还在 E5 里留了"这张表本身怎么守"的待办）。
   两处**已如实降级、可等真需要再补**的能力：`AreaHandle#focus`（Windows 可走 user32
   `SetFocus`，当前点击即入所以不紧急）、窗口最小尺寸（`setContentMinSize:` 是 macOS
   专属，Windows 要另想办法）。
   **Windows 已实际列入必测平台**（这条"待决策"由本轮工作定案，可回退）：CI 矩阵含 `windows-latest`；
   验收证据以 Windows 本机为准（[docs/plan/acceptance-0.1.0.md](docs/plan/acceptance-0.1.0.md)），
   两个 demo 的真窗口验收也都在 Windows 上做。**反悔成本**：CI 里去掉一行 + 验收口径回退到 macOS 单平台。
10. **单视图双渲染（类样式）**：`css_class` 在原生后端整块丢弃（一条提醒、一个声明不生效），
    体量是 167 个类名（sheets 60 / market 107）+ 231 条 CSS 规则。今天不影响两个 demo——
    类名只出现在**浏览器侧视图**里，原生侧是另写视图 + `Theme` 令牌 + area 自绘（见样式
    能力矩阵文档第九节）。**开放问题**：要不要让同一份视图代码同时跑浏览器与原生？
    - 要：先做 **F28 类名别名表**（框架不解析 CSS、只查表，结果并进 StyleMatrix 管道），
      `css_class` 就从"静默丢弃"变成"有映射就生效、没映射就说清为什么"；
      **F29 状态类**（`.is-on` / `.is-buy` …）是另一件事——那是"状态 → 表现"，
      原生控件没有样式位，要单独定约定（今天靠 `state_button` 的文案标记）。
    - 不要：维持 per-target 视图（现状），把这条当已知取舍写进文档即可。
    - 不推荐的第三条路：内置 CSS 子集解析器（A 路径）——成本高，且 `:hover` / `transition` /
      `box-shadow` / 媒体查询解析出来也无处落地（结构性天花板，§七）。
    判定成本很低：**只有真的出现"单视图"需求时才有必要动**（backlog F28 的触发条件同此）。

## 八、参考

- citrine 主仓（渲染器协议与全部语义定案）：`../citrine`（GOALS.md 第七节、第十一节）
- Shoes 3 维护仓库：<https://github.com/Shoes3/shoes3>
- Scarpe（Shoes API over Web，路线 B 参照物）：<https://scarpe-team.github.io/scarpe/>
- libui Ruby 绑定：<https://github.com/kojix2/ruby-libui>（Glimmer DSL for LibUI 为其上位 DSL）
- libui-ng 本体：<https://github.com/libui-ng/libui-ng>

## 变更日志

| 日期 | 变更 | 备注 |
|---|---|---|
| 2026-09-15 | **N0**：仓库骨架建立（gemspec/Gemfile/lib 入口占位/LICENSE/README）；设计主文档定稿——定位（Citrine 的 CRuby 原生 Port）、决策 N-1（v0 后端 = libui，GTK 备选）、架构分层、元素/样式映射 v0 范围、Roadmap N1–N5 | 立项动机：主仓 native port 讨论——渲染器插件化的接口已就绪，缺的是一个 CRuby 宿主的原生实现；打包壳按用户要求明确不做 |
| 2026-09-15 | **N0 环境验证（Ruby 4.0.6）**：`bundle install` 通过——libui 0.2.4 有 arm64-darwin 预编译包、`LibUI.init` 冒烟 OK（风险 1 提前关闭）；实踩上游缺口：citrine 0.2.0 的 `sourcemap.rb` 依赖 `base64` 但 gemspec 未声明，Ruby ≥ 3.4 消费端 LoadError——本仓 gemspec 加 `base64` 过渡依赖，待上游修复后移除（风险 6） | 入口占位 `require "citrine-native"` 验证通过（citrine 0.2.0 经 path 引用加载成功） |
| 2026-09-15 | **N1 落地**：最小闭环——控件适配层（`Widgets::Base` 协议 + `Widgets::Libui` 真后端 + `Widgets::Memory` 桩后端）、`Renderer`（全部平台钩子）、`App`/`Citrine::Native.run`、`examples/counter.rb`。**`attach_before` 结论：无损重排可行**——`uiBoxDelete` 只摘除不销毁（实测：摘除后控件仍在分配表、`uiControlParent` 为 NULL），适配层"摘锚点及其后兄弟 → 追加 → 按原序回挂"即可**原位恢复，不需要容器级重建**（风险 2 关闭） | 真控件冒烟（`test/support/libui_scenario.rb`）全绿：3 次真回调 → 标签精确显示"计数：3"；重排用 libui 自己的 `box_delete(0)` 反查 0 号位（独立于适配层账本）；拆解后 `uiUninit` 无泄漏警告、进程正常退出（exit 0）。GUI 模式（真窗口 + `uiMain` + 后台线程 `queue_main` 点击）另跑一次通过：`SMOKE_OK`，拆解后零残留控件 |
| 2026-09-15 | **N1 实踩（全部在适配层吸收，未改 citrine 核心）**：① libui gem 是**扁平 FFI API**（没有控件类），句柄是 `Fiddle::Pointer`；② 回调闭包挂在**句柄对象**上，句柄被 GC 回收 = 回调变野指针 → 适配层常驻持有句柄；③ `uiControlDestroy` 撞到"仍有父容器"直接 abort，而容器销毁会连坐子控件（再销毁子控件 = double free）→ 一律"先摘后销毁"、渲染器保证子先父后；④ `*_text` 返回 libui 分配的 C 字符串（须 `uiFreeText`），且 Fiddle 不做编码推断（拿到 ASCII-8BIT）→ 适配层统一按 UTF-8 解释；⑤ 程序化 `setText`/`setChecked` **不触发**回调 → 受控同步无回环；⑥ 控件回调里的异常不穿过 Fiddle/Objective-C 栈（打到 stderr 继续跑） | 这些约束写进 `widgets/libui.rb` 的类注释与风险 7；元素/词表映射见 4.2、4.3 |
| 2026-09-15 | **文档修正（N1 实踩）**：立项示例里的三处写法都不是 citrine DSL 的真实形态——`state :count, 0`（应为 `state :count, default: 0`）、`button("文本", on_click:)`（文本走 block）、`check_box { "标签" }`（**check_box 没有内容位**，标签是相邻 `label { }`，传块被 DSL 静默丢弃）。本文档与 README 已改正 | 组件代码本身不受影响，但照抄旧示例会直接报错/静默丢标签 |
| 2026-09-15 | **N2 落地**：`text_input` 受控双向绑定（信号 → 控件用 Effect；控件 → 信号在原生回调里写回后再派发处理器）、`check_box` 勾选回写（处理器收布尔，与 DOM 同口径）、`disabled` → 控件禁用态、`flex_grow` → 追加时的 stretchy、`examples/todo.rb`（增删 + 勾选 + 按钮提交） | 测试基线：`bundle exec rake` = 43 runs / 115 assertions / 0 failures（含 1 项按需跳过的 GUI 冒烟）。**回车提交不成立**：libui 的 entry 不暴露按键事件 → 改按钮提交并挂 N4；`on_enter`/`on_key`/`placeholder`/`window_key` 全部走 dev_mode 提醒 |
| 2026-09-15 | **NA-1 落地：自绘面板（area）能力**——冻结接口（`docs/design/native-area.md`）全实现：`Painter`（rect/line/polyline/polygon/text/measure_text/clip + `content_size`/`clip_rect` + 颜色解析 + 面板级文本布局缓存）、`Painter::Recording`（桩后端断言"画了什么"）、`PointerEvent`/`KeyEvent` 归一、`AreaHandle`（repaint/scroll_to/focus）、重绘调度（`watch:` 与该节点 Effect + 三个收敛点兜底）、`Citrine::Native.every/after` 定时器、`App` 的 `activate:` | 测试基线：`bundle exec rake` = **98 runs / 277 assertions / 0 failures**（含 1 项按需跳过的 GUI 冒烟；`CITRINE_NATIVE_GUI=1` 时 0 skips 也全绿）。真控件冒烟新增：五个回调槽、合成 `uiAreaMouseEvent`/`uiAreaKeyEvent` 走**真闭包**（坐标/修饰键/键名归一/Down+Up 配对 click）、真文本度量与外接矩形（中文 / 换行长度 / 缓存复用与释放）、传错句柄 fail fast、拆解后面板记账清零；`--gui` 追加：激活后窗口是 key window、`AreaHandle#focus`、真绘制（矩形/折线/面积图/中文富文本/裁剪块）、`watch:` 与手动 `repaint` 都真重画、滚动后 `clip_rect` 跟着走。视觉另用窗口截图核对过（标题条/三行右对齐数字/绿色面积图/被裁剪的文字块，位置与颜色都正常） |
| 2026-09-15 | **NA-1 实踩（平台约束，全部在适配层吸收）**：① `uiAreaSetSize` 只对**滚动**面板有效——对非滚动面板调用走 `uiprivUserBug` **直接终止进程**（实测 exit 134），所以 `size:` 只在 `scroll: true` 时落地，非滚动面板由容器布局决定；② 滚动面板下 `uiAreaDrawParams.AreaWidth/AreaHeight` **恒为 0**（ui.h："only defined for nonscrolling areas"）→ Painter 尺寸取自声明的内容尺寸；③ libui-ng 的 `uiArea` **不投递滚轮**（`uiAreaMouseEvent` 无滚轮字段；GTK 版把滚动按钮 4-7 显式忽略）→ 接口里没有 `on_wheel`，要滚动用 `scroll: true` + `scroll_to`；④ `uiAreaHandler` 的五个回调槽**必须全装**（libui 调用前不检查 NULL）→ 创建时装满 no-op，订阅者走多路分发；⑤ 键盘前提：`uiControlShow` 之后窗口**不是 key window**（`firstResponder` 为 nil）→ `App` 默认 `activate:` 激活应用，`AreaHandle#focus` 走 `[keyWindow makeFirstResponder:]`（libui 无此 API，用 Fiddle 直通 libobjc；非 macOS 返回 false）；⑥ `int` 返回类型的回调闭包**必须返回整数**（返回 `true/false/nil` 会在 Fiddle 边界抛 `TypeError` 且穿过 libui 的 C 栈）；⑦ 释放纪律：属性所有权归 attributed string（不能再 `uiFreeAttribute`）、自建 `family:` 的字体描述符**不能**交给 `uiFreeFontDescriptor`（会 abort） | ⑥⑦ 是探针阶段真踩到的坑（①③⑥ 分别以 exit 134 / 无滚轮 / Fiddle TypeError 复现）。定时器另注：本机 libui 0.2.4 的 `uiMainStep` 直接段错误（最小复现：起窗口 + `main_step(0)`），所以定时器走"后台线程 + `queue_main`"，不自己泵循环。泄漏/性能探针（不入库）：真窗口每帧 ~60 图元 + 40 段文本，30 秒 1484 帧，RSS 平坦（102→102.6MB）、帧间隔中位 ~20ms |
| 2026-09-15 | **NA-1c 修复轮**（独立验收 NA-2 的必修项 + SHEETS-2 的 D2/D7）：① **⌘ 键不再吞菜单快捷键**——`modifiers[:meta]` 为真一律回报"未处理"（返回 0）但**回调照常触发**；策略是**单点**的：在渲染器（on_key 的已处理语义），适配层 `key_area` 只如实转达订阅者的答复、不自己再判一次（NA-2b 复核代码确认单点，NA-1d 把这句与设计 §5.7.1 对齐——原文误写"两处同策略"）；真 OS `⌘H` 对照实验：修复前 `WITH_ON_KEY=1` → `hidden=false`（菜单被吞），修复后 → `hidden=true` 且 `keys=[["h", true]]`。② **滚动面板的 `clip_rect` 改成精确可见区**——取 `areaView` 的 `visibleRect`（KVC + `NSValue#getValue:size:`，Fiddle 拿不到结构体返回值）而非 drawRect 的脏区 `Clip*`（脏区：非滚动面板那一帧是整窗、滚动帧只是新露出来的条带，NA-1d 改写——原文"含滚动条占位"被 NA-2 否证），夹进声明的内容尺寸；冒烟与 AppKit 几何对拍。③ **`on_draw` 里 `repaint` 能出下一帧**——AppKit 在绘制中忽略 `setNeedsDisplay`，"自排队动画"曾静默冻在第一帧；适配层记"正在绘制"，绘制期请求延后到收尾的下一轮主循环（同一面板一轮一次、闭包不常驻）。④ **面板 0 尺寸的 dev_mode 提醒**（`Renderer#warn_starved_area`，绘制回调里按节点去重，提示 flex_grow + 嵌套 box 的坑） | 测试基线：`bundle exec rake` = **111 runs / 304 assertions / 0 failures**（1 项按需跳过的 GUI 冒烟；`CITRINE_NATIVE_GUI=1` 时 0 skips 全绿）。桩后端新增：⌘ 键五条返回口径、绘制期 repaint 的延后与合并、0 尺寸提醒三条；真控件新增：⌘/无修饰/无处理器三种真闭包返回值（4 条）、`clip_rect` 与 AppKit `visibleRect` 对拍、滚动面板撑满容器、自排队动画持续出帧 |
| 2026-09-15 | **NA-1c 结论修正（SHEETS-2 D2）**：验收说"`flex_grow` 对滚动面板不生效（换 `scroll: false` 就撑满）"——**不成立**。量真 NSView 的 frame：滚动面板与普通面板的 stretchy 行为一致（平整树里 760×528）；把 area 换成纯 label 也照样塌（`stack { label; row(style: { flex_grow: 1 }) { stack{area}; stack{label} }; label }` → 376×16），"换 scroll: false 撑满"是**绘制溢出**造成的测量假象（AppKit `NSView` 默认 `clipsToBounds=NO`，376×16 的面板把 2000×2000 的绿矩形画满整窗）。**真因是 libui 的嵌套 box 布局**：主轴约束链是 Required，"没有尺寸来源"的 box 会被内容钉死并连带钉住外层；另外 `flex_grow` 在 libui 里只是 **stretchy 布尔、不是权重**（两个 stretchy 子控件等分剩余空间）。~~可操作写法：每个嵌套 box 里至少有一个 `flex_grow` 子控件~~（**NA-1d 改写**：这条既不必要也不充分，正确判据是"**参与拉伸的 box 自己要在父容器里有 stretchy 尺寸**"，逐层成立才撑得开——反例与自己的复现数据见 `native-area.md` §5.7.2）。框架**不擅自改布局语义**（改默认 stretchy 会静默改变现有应用布局），改为 dev_mode 提醒 + 文档 §5.7.2 + backlog F11 | 探针与数据：`/tmp/na1c/tree_probe.rb`（各结构真 frame）、`/tmp/na1c/overflow_probe.rb`（绘制溢出：376×16 面板 → 绿像素 x 20..800 / y 0..564）、`/tmp/na1c/nested_probe.rb` |
| 2026-09-15 | **NA-1d 修复轮**（独立验收 NA-2b 的 1 项必修 + 文档不一致）：① **定时器不再每 tick 漏一个常驻闭包**——`Timer` 改走 `queue_main_once`（执行后释放引用）；事件订阅那类必须常驻的闭包仍走 `queue_main`，`Base#queue_main_once` 缺省退化为 `queue_main`。② **`AreaHandle#focus` 如实返回"焦点是否真的生效"**——旧写法只要窗口是 key window 就返回 true；NA-1d 实测（macOS 26）`makeFirstResponder:` 的 BOOL 对"不接受"的目标也返回 YES，所以只转达 BOOL 仍不诚实，最终按"**BOOL 受理 ∧ 窗口的 firstResponder 真的是目标或其后代**"返回（`isDescendantOf:` 判，滚动面板的 first responder 是 document view）。语义边界写进设计 2.3/§5.3 与代码注释。③ **"面板被压扁"提醒扩成三条判据**（0 尺寸 / 控件被挤成细条 <24pt / **滚动面板真实可见视口**被挤扁），提示文本改成对"已有 `flex_grow` 仍被压"可操作（指向容器链）。④ **D2 判据与表格改写**（"每个嵌套 box 至少一个 stretchy 子控件"既不必要也不充分 → "参与拉伸的 box 自己在父容器里有 stretchy 尺寸"，用自己复现的数字与完整树重写表格）；`Clip*` 理由改成"脏区条带化/整窗"（原文"含滚动条占位"被 NA-2 否证）；GOALS 的"⌘ 策略两处同策略"改成"单点在渲染器"；KVC retain 注释改成 11/12 字符边界。⑤ 写明两条不修的脆弱面（ObjC 异常不可捕获会终止进程、销毁后野读给陈旧值）与首帧 `clip_rect` 瞬态 | 测试基线：`bundle exec rake` = **119 runs / 334 assertions / 0 failures**（1 项按需跳过的 GUI 冒烟）；`CITRINE_NATIVE_GUI=1 bundle exec rake` = **119 / 339 / 0 / 0 skips**；`test/support/libui_scenario.rb`（默认与 `--gui`）SMOKE_OK、stderr 空、exit 0。新增桩测：定时器只用一次性队列槽（`queue_log`）、面板被挤成细条/视口塌陷两条新提醒与阈值边界、提示文本含容器链判据且不含被否证的旧规则、句柄 focus 转达后端答复；新增真控件断言：定时器 ~12 tick 后常驻闭包新增 ≤ 2、focus 成功（true + 焦点真在面板上，`isDescendantOf:` 判）、目标为空（false + 无副作用）、游离视图（AppKit 原值 YES，框架仍返回 false——只转达 BOOL 不够的判别用例） |
| 2026-09-15 | **NA-1e 清理轮**（独立验收 NA-2c 的 5 条 P3，都属"文档/提示不实"）：① **判据 ② 不再对滚动面板误报**——滚动面板下 Painter 的宽高是**声明的内容尺寸**，于是健康的 `scroll: true, size: [2000, 20]`（真 GUI 实到 760×544、视口 743×527）会被打印"控件被挤成一条：2000.0×20.0"，还给出与形状无关的容器链建议；现在判据 ② 用 `@widgets.area_scrollable?` **跳过滚动面板**，滚动面板只由判据 ③（真实视口）说话（宁可漏报也不误报——新盲区 ④ 写进 §5.1）。② **判据 ③ 的视口数字如实标注为当帧读数**（滚动面板首帧可能报成 NSScrollView 的尺寸、本机偏大 17pt）：选"标注"而不是"取稳态值"，理由（延迟一帧会让单帧形状漏报；"读数等于 NSScrollView frame"这种瞬态判据在 overlay 滚动条下会误判）写在 §5.7.7-2。③ §5.7.2 表 2 第 4 行补上抖动数字，**删掉不可复现的表下注**（`stack { label; area; area }` 的"滚动第一个 0×544 / 普通面板反过来"：NA-1e 滚动/普通各 3 次跑都是**逐个数字相同**——第一个 760×0、第二个 760×544，旧注疑似把 `frame=[x,y,w,h]` 的 `0,544` 读成"宽×高"）。④ `AreaHandle#focus` 返回 false 的含义从"两种"改成**三种**（补"key window 在、但 AppKit 没把焦点给目标"），并把 `uiControlDisable` 过的面板加进"不接受 first responder"的目标清单。⑤ "没有尺寸来源 → 0×0"的旧措辞（§2.1 / §5.1 / `backlog.md` 的 F1 标题）改成"取决于它在父容器逐层的 stretchy 情况，拿不到才 0×0"（反例 `stack { label; area }` → 760×544）。⑥ **只读复核** `citrine-sheets/native/README.md`：`clip_rect` 口径 sheets 侧已改到位（"曾偏大、现已精确 + 首帧例外"），本仓的 D2/§5.7.6-8 记录同步，**不需要再派发** | 测试基线：`bundle exec rake` = **121 runs / 340 assertions / 0 failures**（1 项按需跳过的 GUI 冒烟）；`CITRINE_NATIVE_GUI=1 bundle exec rake` = **121 / 345 / 0 / 0 skips**；`test/support/libui_scenario.rb`（默认与 `--gui`）SMOKE_OK、stderr 空、exit 0。新增 2 条桩测：健康滚动面板的矮**内容**尺寸不触发判据 ②、同一组数字换成非滚动面板仍触发（判别用例）+ 自己的复跑数据与理由见 `native-area.md` §5.7.7（探针 `/tmp/na1d/layout_probe.rb`，NA-1e 复跑 `STRUCT=two_areas[_bare]`） |
| 2026-09-15 | **两个 demo 的手工验收脚本化：`rake demo_acceptance`**（N1/N2 之外，把"真实应用可玩"变成可复跑的门）：本轮先手工验收了两个 demo（见下条），随即把它固定成 `test/support/demo_acceptance.rb`——**拉起真窗口 → 轮询子控件 → 读控件标题（`GetWindowTextW`）→ 真鼠标点击（`SetCursorPos` + `mouse_event`）→ 关窗并断言进程自行退出**，全程只依赖 Fiddle + stdlib，子进程独立 log。**25 项断言**（sheets 13 / market 12）：表头与位置标签、**方向性断言**（`B9 → E20`：越往右下列号行号不更小；不依赖列宽行高这类魔数，避免把 gutter 当成单元格）、表头与位置标签自洽、点击后启动提示消失、`⏸ 暂停`↔`▶ 继续` 往返、`4x ✓`、`自动交易` 文案翻转、**行情档位 3 秒后更大**、`WM_CLOSE` 后进程自行退出、log 为空。**稳定性**：连跑 3 轮 25/25、退出码 0（第一版有不稳——两个标签要轮询才读得到，子控件是逐步建的；已修）。**边界**：非 Windows 或缺同级仓库 → SKIP 且 0 退出；未知参数退 2；键盘路径不在覆盖内（合成键盘投递不到 area，见验收文档第三节）。Rakefile 加 `demo_acceptance`，README「开发」节补命令与前置条件 | `bundle exec rake demo_acceptance` = **25/25、退出码 0**（3 轮）；框架套件 167 runs / 707 assertions / 0 failures 不变 |
| 2026-09-15 | **验收器覆盖扩到 N1/N2 验收物（本仓 examples）——并抓出一条我自己早先记错的结论**：`demo_acceptance` 现在覆盖 counter/todo/sheets/market 四个目标、**44 项断言**（counter 6 / todo 13 / sheets 13 / market 12），`DEMO=<目标>` 可选跑（`examples` / `counter` / `todo` / `sheets` / `market`）。**N1**：真窗口标题 `计数器`、`计数：0` → 真点 `点我 +1` 三次 → **`计数：3`**（精确 +1，对齐主仓 M0 Spike A 口径）。**N2**：`待办：剩余 0/共 0` →（打字）→ `1/共 1` →（勾选）→ `剩余 0/共 1` →（删除）→ `共 0` + 空态提示回归。**⚠️ 更正一条旧结论**：早先写在验收文档里的"`WM_SETTEXT` 注入 → `on_change` 收到 `milk`，EN_CHANGE 链路已验"**不成立**——`SetWindowTextW` 只改 Edit 的内容（跨进程读回来的就是它，像是成功），应用侧 `draft` 仍是空、`add` 早退、计数停在 `共 0`；改成**逐字符 `WM_CHAR`**（用户打字同一条路）后链路才被完整证实。**另两个坑**（已写进脚本注释与文档）：`bundle exec` 会多一层 ruby（窗口属于孙进程，按 pid 找窗口/关窗全落空）→ 子进程内 `RUBYOPT=-rbundler/setup`；libui 的隐藏辅助窗口 `libui utility window` 会被"取第一个顶层窗口"取到 → 只认**可见且有标题**的窗口（本仓示例按标题精确等待）。稳定性：**连跑 4 轮 44/44、退出码 0** | `bundle exec rake demo_acceptance` = **44/44、退出码 0**（4 轮）；框架套件 167 runs / 707 assertions / 0 failures（GUI 模式 714 / 0 skips） |
| 2026-09-15 | **两个 demo 的当前框架回归扫 + 真点击验收（标题回读）**：用**改动后的框架**（样式矩阵 / area 底板 / F24 挂载期提醒）重跑两个真实应用。**citrine-sheets**（`run!` → dev_mode **开**）：起窗 1262×865 正常、`stderr` **0 字节**（新框架在该应用上**不误报**断链）；**真实鼠标点击网格 (348,481)** → 表头 `A1 · 60 行 × 26 列` → **`D15 · 60 行 × 26 列`**、`位置 D15`、`选区 D15 · 单元格 1 · 数值 0 …`（**坐标换算与控制标题互相印证**，应用状态真实改变）；启动提示"点一下网格即可用键盘（窗口还没拿到键盘焦点）"点击后**消失** → 应用进入键盘模式。**citrine-market-terminal**：同样 `stderr` **0 字节**；真点 `⏸ 暂停` → **`▶ 继续`**、真点 `4x` → **`4x ✓`**（并回到运行态）、真点 `自动交易 关` → **`自动交易 开 ✓`**；**走时可读验证**：`上午盘 09:43 · 第 13 档` → `11:00 · 第 90 档` → 3 秒后 `11:09 · 第 99 档`（仿真在真实推进）。**键盘合成投递再证否两条路**：① 向 area 句柄 `SendMessage(WM_KEYDOWN/WM_KEYUP)`；② `AttachThreadInput` + `SetFocus(area)`（已确认 `GetFocus() == area`）后再投——sheets 选区仍停在点击选中的 `D15` → libui 的 area 键事件不认合成消息，如实留在"需人手一次"清单。**方法论升级**：两个 demo 的状态大多落在**原生控件标题**上（sheets 的 `位置 D15`、market 的 `第 99 档` / `4x ✓`），优先用标题回读而不是像素 | 两个 demo 的真窗口冒烟全过；`stderr` 均为 0 字节；框架侧本轮只改文档与测试（167 runs / 707 assertions / 0 failures 不变） |
| 2026-09-15 | **market 的下单与校验进验收（16 → 21 项，总计 53 → 58）**：把"下单"这条真实链路固定下来——点「全部」→ `最大可买 700 股`（按可用资金算，预估金额 956,592.00）→ 点「提交买入」→ `委托结果：成交：买入 700 股 @ 1,381.01（手续费 241.68）`、`提示：` 同步、持仓出现该只；**校验路径**同样确定性：资金投完后再下单 → `委托结果：数量无效：请输入 100 的整数倍（如 100 / 500 / 1000）`（**不是静默失败**）。**两个实测教训**：① 价格带**千分位**（`@ 1,381.01`），模式写 `[\d.]+` 就永远匹配不上——这已经是同类的第三次（前两次是 `+` 号、两行标签），所以都在代码里留了注释；② **顺序有语义**：手动下单必须排在"自动交易开关"之前，否则等手动下单时资金已被自动交易花掉，「全部」填出来的数量不足 100 股，成交断言必然失败（先在失败的 run 里撞到，才改的顺序）。**一处 UX 观察**（如实记录、**未断言**，避免把可能非有意的行为钉死）：校验失败时 `提示：` 仍留着上一次的成功文案；另一个 run 里两个标签还各报了一个错（`数量无效` vs `可用资金不足`）。 | `DEMO=market` = **21/21**；`all` = **58/58、退出码 0**；框架套件 178 runs / 762 assertions 不变 |
| 2026-09-15 | **把"待决策"压成一张决策清单（backlog D-1…D-11）**：在此之前，十一件事散在 backlog 的散文里、两个 demo 的 README 里与 GOALS 的风险清单里，"你没法一眼选、我也只能反复追问"。现在 [docs/plan/backlog.md](docs/plan/backlog.md) 顶部有一张表：**决定什么 / 不决定的后果 / 选项 / 我的建议（附理由） / 代价与风险**，并在 GOALS 的 Roadmap 下方指了路。十一条覆盖：D-1 提交推送（citrine-native 34 个条目；demo 仓库另 8 个——market 7 个视图与 README、sheets 1 个 `native/app.rb`，数字当场核对过）、D-2 发 0.1.0、D-3 F25 根容器 stretchy 透明、D-4 F12 强制裁剪、D-5 F17 压扁阈值、D-6 F26 文本度量 + opt-in 提醒、D-7 F27 L3 着色桥、D-8 F28/F29 css_class 别名表与状态类、D-9 E4 Win32 桥、D-10 F10 多窗口后端绑定、D-11 sheets 的 `⌘B` 共享逻辑缺陷。**建议一律给"现在做哪个 / 什么条件下做另一个"**（例如 D-3 建议现在维持 + 靠 F24 提醒，等有独立验收窗口再做透明化），不是含糊的"待评估" | 文档表格对拍通过（4 份含表格的文档 0 问题）；套件 178 runs / 762 assertions 不变 |
| 2026-09-15 | **sheets 的应用逻辑也进验收（13 → 18 项，总计 48 → 53）**：此前 sheets 只验到"点选单元格"。这轮发现**工具栏按钮是纯鼠标可达**的，于是把应用自己的状态输出变成断言：`B 加粗` → `已设置格式 E20（撤销 1 / 重做 0）`、`↶ 撤销` → `已撤销（撤销 0 / 重做 1）`、`↷ 重做` → `已重做（撤销 1 / 重做 0）`（**撤销栈往返**）、`重算全部` → `上次重算 已重算全部公式：重算 132 格 · 显示变化 0 格 · 4 ms`（并断言格数 > 0）。**顺带查清一件事**：sheets 的单元格编辑走 **area 侧按键**（libui 的 entry 收不到键，`native/app.rb` 的注释就是这么写的），而合成键盘投递不到 area → **单元格编辑本机验不了**，如实写进验收文档。**真点击也修了两次假通过**：① 之前"点两处断言方向性"只看标签形状，点击整批丢失时仍会通过（实测就骗过了一次：位置标签还写着 A1）→ 改成断言"必须真的改变"（`A1 → B9 → E20`）；② 前台拿不到时 `SetForegroundWindow` 即使挂了 `AttachThreadInput` 也会被拒（桌面共享，用户在机器前时常见）→ 新增**消息级点击回退**（`WM_LBUTTONDOWN/UP` 投给控件），并**打印 info 标注用了哪条路径**。实测那一轮 5 次点击全部回退，但 area 的选区与按钮命令都走到了（说明 libui 的 area 认消息级鼠标——与键盘不同，这个不对称值得记一笔）。 | `DEMO=sheets` = **18/18**；`all` = **53 项**；框架套件 178 runs / 762 assertions 不变 |
| 2026-09-15 | **验收器补上"自动交易真的在交易"（market 12 → 16 项，总计 44 → 48）**：此前 market 只验到"按钮文案翻转"，交易逻辑本身没被覆盖。先手工采样 60 秒拿到事实：自动交易开启后 **持仓 `共 1 → 2 → 3 → 4 → 6 只`**、出现分页 `第 1/2 页`、`总资产` 由 1,000,000.00 漂到 952,123.67、**头部 `浮动盈亏` 与持仓面板 `浮盈` 每一帧都相等**（`+427/+427`、`+6,188/+6,188`、`-2,576/-2,576`、`-47,690/-47,690`）、**运行日志 0 字节**（无异常、无崩溃）。随后固化成 4 条断言：自动交易已开、持仓数 ≥ 1、**同一帧里两处浮盈相等**、总资产不再是初始值；关窗与 log 干净的断言也变成了"跑过自动交易之后仍然干净"。**这条断言连踩三个坑（都写进代码注释）**：① 符号——盈利时标签是 `+427.00`，只写 `-?` 会在盈利时读不到（第一版因此假失败）；② 持仓面板的汇总标签是**两行**（`市值 … · 浮盈 …` 换行接 `可用 … · 冻结 …`），写了 `\z` 之后"有持仓"就永远匹配不上——从失败时的现场转储里才看出来；③ 标签每档刷新，两处必须**同一次枚举**里读，分别读会读到不同帧。**真点击也加固了一层**：先确认窗口真在前台（`GetForegroundWindow` 校验 + `BringWindowToTop`，失败重试），否则"坐标对了"的点击会落到别的窗口上——实测遇到过一次"点暂停、控件纹丝不动"，现场清单证明点击从未送达。 | `DEMO=market bundle exec rake demo_acceptance` = **16/16**；`all` = **48/48、退出码 0**；框架套件 178 runs / 762 assertions 不变 |
| 2026-09-15 | **消费端冒烟（`rake consumer_smoke`）：把"打包出来的 gem 能不能用"变成可复跑**。背景：早先那次"`gem build` → `gem unpack` → `require` 成功"是一次性的手工验证；本仓开发态又全是 path 依赖，"在工作树里跑通"不足以说明打包产物在用户侧可用。新脚本 `test/support/consumer_smoke.rb`（10 项）：本地构建两个 gem（`gem build --output`，产物落临时目录）→ 装进**全新 GEM_HOME**（`gem install --local --ignore-dependencies`）→ 在**仓库外**的空目录 `require "citrine-native"` → **断言加载的是装好的那份**（`LOADED_FROM` 指向临时 GEM_HOME 而不是工作树，正则要同时认 `\` 与 `/`——第一版只认 `/`，Windows 上读不到路径）→ 版本号一致 → 用装好的 gem 挂载组件、点 3 次 → `计数：3`。**卫生**：不联网、不碰工作树（实测兄弟仓库 0 改动、临时目录自清理、无 `.gem` 残留）。**边界如实写在脚本头**：`citrine` 是从工作树现构建的、依赖跳过解析——"依赖闭包在干净机器上能否解析"只有装发布版那一步能证明（已写进 RELEASING §三，并说明两者区别）。另外修了两处 `IO.popen` 的坑：env 必须在命令数组首位、`chdir: nil` 会报类型错误。Rakefile 加 `consumer_smoke`，README「开发」节与 RELEASING §三同步 | `bundle exec rake consumer_smoke` = **10/10、退出码 0**（含 `CONSUMER_SMOKE_OK`）；套件 178 runs / 762 assertions 不变 |
| 2026-09-15 | **N5 发布准备收口：发布手册 + 发布元数据对拍（9 项）**。新增 **[RELEASING.md](RELEASING.md)**——一次性前置（Trusted Publisher 三个字段）、发布步骤（改版本 → 提交 → 打推 `v*`）、工作流的四步（门禁 → 标签一致性 → 构建 → 附产物 + OIDC 发布）、**发布后验证**（装发布版 → 跑 counter → `gem info` 看依赖）、出错处置（未发布 vs 已发布的撤法）、首次发布的五项人工确认、过渡依赖 `base64` 的移除条件。新增 **`test/release_metadata_test.rb`（9 项 / 50 断言，随套件跑）** 把版本号这条线的五处引用互锁：version.rb ↔ CHANGELOG 最新已发布条目（含 ISO 日期）、version.rb ↔ 当前 CHANGELOG 节点、gemspec 元数据与 `files`（漏打包 lib 文件/四份文档会红）、**提交里的** 锁文件 ↔ 提交里的 version.rb、CI 与发布工作流的 Ruby 版本 ⊆ `required_ruby_version`、发布工作流的三条硬前置（只由 `v*` 触发、`id-token: write`、门禁→构建→发布的**顺序**）与 RELEASING.md 存在性。**两个“测试自己的坑”**（都实测过）：① 一开始断言工作树的 Gemfile.lock ——`bundle exec` 会在测试读它之前就把锁文件自动改好（路径依赖版本变化触发重写），**永远修不出漂移**；改成看 `git show HEAD:` 那份（CI 检出的正是它）；② 该断言的牙齿用**临时克隆**验过：克隆里提交"只改 version.rb 不改锁文件"后，断言如期变红并指出两个版本号。 | 套件：`bundle exec rake` = **178 runs / 762 assertions / 0 failures**（1 skip）；`CITRINE_NATIVE_GUI=1` = **178 / 769 / 0 / 0 skips** |
| 2026-09-15 | **文档表格对拍入库（`test/doc_table_test.rb`）+ 数字刷新**：把今天临时用来自查的脚本变成常驻测试——**每张 Markdown 表内单元格数必须一致**（连续以管道字符开头的行算一张表，遇到空行/标题/正文即收尾，代码块里的管道字符不算），单元格里嵌管道走 GFM 转义（计数时先换成占位符，所以转义不误报）；再有覆盖面自检（≥10 份文档且必须含 GOALS.md）。为什么值得一条测试：今天**两次**踩到"单元格里写了未转义的管道把表切坏"（一次是控件转储那一行，一次是文件清单），都是脚本先抓到的。写测试时自己也踩了两个坑并修掉：① 最初遇到非表格行**忘记收尾**，于是把整个文件的所有表当成一张 → 7 个假阳性；② 一度加过"表格里不许用转义管道"这条**错规则**（GFM 里转义正是嵌入管道的正规写法），已撤掉——裸管道会让单元格数变多，第一条测试本来就抓得到。修好后全仓文档 0 问题。 | 套件：`bundle exec rake` = **169 runs / 712 assertions / 0 failures**（1 skip）；`CITRINE_NATIVE_GUI=1` = **169 / 719 / 0 / 0 skips** |
| 2026-09-15 | **E5 部分落地：平台能力矩阵的机器校验 + Release 标签逻辑本地实测**：新增 `test/platform_matrix_test.rb`（5 项）——① ObjcBridge 可用性按平台断言（macOS 可用 / 非 macOS **如实不可用**）；② 不可用时五个能力方法逐个如实降级（`activate` / `window_key?` / `focus` / `rect_of` / `scrolling_document_view`，含空句柄不崩）；③ 桥的每个能力方法都经 `available?` 守卫（按 `return false/nil unless available?` 计数——**新增桥能力却忘了守卫时会红**）；④ 矩阵文档与能力名对拍（`window_is_key` / `AreaHandle#focus` / `window_activate` / `clip_rect`）。**仍无守卫**的部分如实留在 backlog E5：依赖真控件几何或进程级行为的条目（控件天然高度、布局严格性、信号集合、滚轮/双击缺失）。另：**release.yml 的"标签 ↔ VERSION 一致性校验"逻辑本地实测通过**（`tag=0.1.0` 通过、`tag=0.2.0` 拒绝） | 套件：`bundle exec rake` = **167 runs / 707 assertions / 0 failures**（GUI 模式 714 / 0 skips） |
| 2026-09-15 | **0.1.0 验收证据入库 + N1/N2 验收物首次在本机真窗口验收**：新增 `docs/plan/acceptance-0.1.0.md`——Roadmap N0–N5 每条验收口径 ↔ 当前证据（命令 + 结果）逐条对照，附"未验证/边界"诚实清单与本机验证方法论。**N1 验收**：`examples/counter.rb` 真窗口 + **真实鼠标点击 3 次** → 子控件文本 `计数：0` → `计数：3`（精确 +1）。**N2 验收**：`examples/todo.rb` 真窗口——添加后 `待办：剩余 1 / 共 1` + 行内标签 `milk` + `删除` 按钮（提示切到"勾选表示完成"）、勾选后 `剩余 0 / 共 1`、删除后回 `共 0`；输入框用 `WM_SETTEXT` 注入 → 应用内读回 `"milk"` 且 `on_change` 处理器收到 `"milk"`（**EN_CHANGE → 写回链路在真控件上首次被验证**，此前只有桩测）。**方法论与两个坑**：① Windows 上无视觉模型时，`EnumChildWindows` + `GetWindowTextW` 能读 label/button 的标题（最硬证据），但**跨进程读不到 Edit 的内容**（那不是窗口标题）——必须在应用内读回，否则会误判成"输入被清空"（本轮先误判、后证伪）；② 从**后台线程直接改 UI 会让 libui abort**（`GetLastError() == 5`，exit 3）——探针踩了一次，正好反证文档里的线程约束 | 套件不变（本轮未改代码）：`bundle exec rake` 162/670/0、GUI 模式 0 skips；两个 demo 的真窗口冒烟与 `native:test` 全绿 |
| 2026-09-15 | **F24 修复（挂载期的"严格后端上会塌"提醒）**：绘制期的三条"面板被压扁"判据都挂在 **Draw 回调**里，而 Windows 的 libui 对 stretchy 链断开的 area 是**完全**的 0×0、`WM_PAINT` 不会来 → 一条都不会亮（macOS 上 0×0 面板仍有 Draw，所以这个盲区只在 Windows 上看得见）。新增 `Renderer#warn_strict_stretch_chain`：在**最外层收敛**（`finalize` 且 `@parents.empty?`）时从组件根向下走一遍，判据同 §5.7.2（面板自己能 stretchy **且**每一层祖先 box 都 stretchy），不满足就按节点去重提醒，并指出**断在第几层的哪个 box**（或"面板自己"）；不做几何推断，措辞明确是"在严格后端（Windows）上会塌成 0×0 且一次都不绘制"，只在 dev_mode 下出现。**F26 的可行性分析同时入库**（适配层没有文本度量入口；桩估算误差 −8%..+11% 会让挂载期提醒误报；Windows 拿不到 label 的文本宽度）→ 结论是"要做需要新开度量协议 + 提醒 opt-in"，仍待决策 | 测试：`area_test` 新增 5 项（面板自己不 stretchy / 祖先断在第 2 层并报出层号 / 完整链不报 / dev_mode 关时静默 / 无 area 的树不报）；`bundle exec rake` = **162 runs / 670 assertions / 0 failures**（GUI 模式 677 / 0 skips）；两个 demo 的真实树无假阳性（sheets 58/184、market 85/1136 + 冒烟 ✅） |
| 2026-09-15 | **N5 发布准备完成（待打标签）**：版本定 **0.1.0**（`lib/citrine/native/version.rb`，此前占位 0.0.0）；新增 `CHANGELOG.md`（Keep a Changelog，0.1.0 条目列能力与**已知限制**：原生控件无法着色 / `on_enter` 等事件缺口 / Windows 的 focus 与最小尺寸降级 / base64 过渡依赖）；新增 `.github/workflows/release.yml`（Trusted Publishing OIDC：跨仓 checkout → `bundle exec rake` 门禁 → **标签与 VERSION 一致性校验** → `gem build` → 附产物到 GitHub Release → `rubygems/release-gem`）；gemspec 补 `CHANGELOG.md` 入包与 source/changelog 元数据；README 更新状态、`gem install citrine-native` 安装路径、样式能力（含 area 视觉底板示例）、CI/发布说明与仓库结构。**本机验证**：`gem build` 产出 88KB 的 `citrine-native-0.1.0.gem`；`gem unpack` 后 `require "citrine-native"` 成功（版本、72 键样式矩阵、元素词表、libui 0.2.4 均正常）；依赖约束与已发布版本对得上（citrine 0.2.0 / libui 0.2.4 / base64 0.3.0）。**验证边界**：装进**隔离 GEM_HOME** 的消费端测试没能跑完——这台机器访问 rubygems.org 的元数据/下载不稳定（`gem search --remote` 无输出、`gem install <file>` 挂起，进程已清理），所以"真实用户 `gem install citrine-native`"这一步要等首次发布（或网络正常时）再验；另注意 `gem install --local <file>` **不解析远程依赖**，本地验证必须去掉 `--local`。**名称占用**：`citrine-native` 未被占用（API 404），上游 `citrine 0.2.0` 已上架 | 剩下的是仓库管理员动作：rubygems.org 注册 Trusted Publisher → `git tag v0.1.0 && git push origin v0.1.0` |
| 2026-09-15 | **N3 + N4 完成（Roadmap 收口两项）**：**N3 语义覆盖对齐** —— 新增 `docs/design/semantics-coverage.md`：主仓 `test/renderer_test.rb` 的 16 条断言逐条给出承担方（A 渲染器无关=核心测试 / B 平台钩子=native 必须自测 / C DOM-SSR 专属=不适用），另附 error_boundary / nesting / portal / suspense / lifecycle / attr_passthrough 六个文件的分工；本轮补 7 条 native 断言（错误边界三变体：无兜底传播 / 多根就地替换 / 首次渲染自兜底；kebab-case 样式键；符号处理器派发；透传属性收 Signal 提醒 / 受控值 Signal 不提醒）。文档第五节**如实列出未复刻的 4 条**（按分工归核心 Effect 测试）。**N4 元素/事件支持矩阵** —— 新增 `docs/design/element-event-matrix.md`：18 个核心元素标签逐个给出处置（支持 6 个 / 报错 + 替代建议 18 个），23 个事件词条逐个给出 ✅/⚠️/— 与原因（含两处与核心词表的出入：`on_mouse_move` 是原生扩展、`on_wheel` 是 libui 的能力边界）；补齐 7 条缺失的元素替代建议（`ol` / `option` / `thead` / `tbody` / `tr` / `td` / `th`——此前这些标签会拿到一个"没有出路"的报错）；新增 `test/element_event_matrix_test.rb`（8 项）把两条不变量变成机器校验：**未支持元素必须有替代建议**、**未支持事件必须在矩阵文档里出现**（新事件出现时会红） | 套件：`bundle exec rake` = **157 runs / 654 assertions / 0 failures**（+15 项）。Roadmap N3 / N4 标记完成，N5（发布准备）成为唯一未开始项 |
| 2026-09-15 | **E3 落地（launcher 逻辑收进框架）**：新增 `App#trap_quit!`——按 `Signal.list` 过滤平台实际存在的信号（Windows 没有 HUP/QUIT/ALRM，直接 `trap` 会 `ArgumentError`），返回真正装上的名字；`Citrine::Native.run(…, signals: :default)` 一步到位。**默认不接管进程级信号**（`trap` 是进程级的、会覆盖宿主处理器，库不主动接管；判别用例锁住"默认不动宿主"与"显式要求才装"两态）。market 的 `bin/native` 从四行手写循环改成一行 `app.trap_quit!`；sheets 的 `run!` 补上 `signals: :default`（此前 Ctrl+C 是硬杀、不跑有序拆解）。踩到并修掉一处命名空间撞车：`App` 里写 `Signal.list` 会解析到 `Citrine::Signal`（框架自己的信号类），必须写 `::Signal` | 测试：`test/app_test.rb` 新增 5 项（过滤不可用信号、`:default` 集合解析、**进程内真实投递 INT → quit**、默认不接管、显式接管），带处理器保存/还原的 `with_signal_guard`；`bundle exec rake` = **142 runs / 619 assertions / 0 failures**。**验证边界**：Windows 上无法定向投递 Ctrl+C 给别的进程（Ruby 的 `Process.kill("INT", pid)` 是控制台级事件、连发送方一起终止——探针实测发送方以 `STATUS_CONTROL_C_EXIT` 退出），所以"真信号到达"只在进程内验证，跨进程路径仍靠 macOS 侧人工实测（README 记的 9 次信号实验） |
| 2026-09-15 | **D1（终端窗口横向溢出）复核关闭**：成因是"三列按内容天然宽度布局"，已由列级 `flex_grow: 1` 消除（`native/app.rb` 早先的注释与 README 都记了这笔）。Windows 实测三列各 467（x=116/590/1064），最右列右缘 1531 ≤ 内容区右缘 1532，无越界；macOS 侧 README 记"没有任何截断"。**遗留**：Windows 上的视觉截断（文字被压成省略号）仍需人眼确认一次——本机无视觉模型，只能几何 + 像素间接判断（与 D1 同类的"视觉类断言"都受这条限制，建议配 `dim modality set image.read`） | 几何数据取自今天的逐节点遍历探针（`market_tree_probe.rb`） |
| 2026-09-15 | **E1 + E2 落地，F2 / F5 / F6 关闭**（按 backlog 计划推进）：**E1** 新增 `.github/workflows/ci.yml`——`macos-latest + windows-latest` 矩阵跑 `bundle exec rake`（桩测 + **不开窗**的真控件冒烟；GUI 模式留给人工），跨仓 checkout（框架取到 `../citrine`，配合 Gemfile 的开发期 path 依赖）；**E2** 新增 `docs/design/platform-matrix.md`——窗口与焦点 / 布局与几何 / 运行时与生命周期三张表（macOS × Windows）+ 缺口清单 + 写平台代码的三条约定（降级必须如实、平台分支收敛在适配层、文档与代码同步），`native-area.md` 2.3 与 GOALS 风险 9/10 引用它；**F2 复核关闭**（`CONSUMED_PROPS` 已把 area 的 `watch` 排除在透传属性外，实测不再触发核心的「Proc 不是响应式属性」提醒，对照组 `label(id: -> { … })` 仍正常提醒）；**F5** 把 `KeyEvent#raw` 的形态写进 `native-area.md` 2.3（Hash、非 nil、非对象，加字段往后加）；**F6** 把"`find/find_all` 必须传子树句柄"写进 `widgets/memory.rb` 注释；**E5** 新增待办（平台能力矩阵本身没有守卫） | 本机验证：`bundle exec rake` 137 runs / 610 assertions / 0 failures（1 项按需跳过的 GUI 冒烟），CI 的 YAML 已本地解析校验（**首次运行待 GitHub 确认**） |
| 2026-09-15 | **样式 L1 + L2 落地**（"把样式表渲染到 native"的第一、二档）：**L1 样式能力矩阵** —— 新增 `lib/citrine/native/style_matrix.rb`（机器可读，72 个键三档：`:mapped` / `:painted` / `:ignored`），dev_mode 提醒改成按矩阵分档说话（"为什么 / 怎么办 / 去哪看"，都指向 `docs/design/style-matrix.md`）；`padding*` / `flex` 补进 `:mapped`（`padding` → `uiBoxSetPadded`，`flex` 简写 → stretchy），`display` 非 flex 的值单独提醒。**L2 area 视觉底板** —— `element(:area)` 现在自动消费 `background` / `border` / `border_color` / `border_width` / `border_radius`：框架在 `on_draw` **之前**画一次底板（`Painter#rect` 的 fill/stroke/radius，圆角走 `uiDrawPath` 的 arc），样式**每帧现读**（`style: -> { … }` 照样响应式）；`border` 接受 `"1px solid #rrggbb"` / 纯颜色串 / Hash 三种写法，dashed/dotted 按实线画并提醒 | 测试：新增 `test/style_matrix_test.rb`（16 项：矩阵自洽、`:mapped` 落地、底板绘制顺序与参数、响应式重读、`border: none` / 只给颜色 / dashed 三态、提醒分档），`area_test` 与 `renderer_test` 的旧断言按新语义更新；`bundle exec rake` = **137 runs / 610 assertions / 0 failures**（1 项按需跳过的 GUI 冒烟），`CITRINE_NATIVE_GUI=1` = **137 / 617 / 0 / 0 skips**。真控件冒烟：SmokePanel 的底板改走视觉样式（真 GUI 路径因此覆盖 `uiDrawPath` 圆角），并给 GUI 用例加了"stderr 必须干净"断言（绘制期异常被 safe 吞掉后只走 stderr，这是唯一机器可验证形式） |
| 2026-09-15 | **样式 L2 的 demo 落地**（citrine-market-terminal）：面板底板从"每个面板的 draw 里手写 `painter.rect(0, 0, w, h, fill: Theme::PANEL, stroke: Theme::LINE)`"收进框架（`native/views/common.rb` 的 `paint_panel` 给 `style: { background:, border: }`，四处面板各删一行）。实测：`native:test` 85 / 1136 / 0；`native:smoke` ✅（持 6 只走势图 217px，四个面板都在画）；真窗口像素采样与迁移前一致（`#101827` 面板色 2943 个采样点）。citrine-sheets 无同类模式，未改动 | 遗留：原生控件本身着色仍是 L3（backlog F27） |
| 2026-09-15 | **css_class（类样式）的现状与两条路径入库**（纯文档）：样式能力矩阵文档新增第九节——`css_class` 整块丢弃的现状与体量（**167 个类名** / sheets 60 + market 107，对应 231 条 CSS 规则、16 个令牌），并说明**今天不影响两个 demo**（类名只出现在浏览器侧视图，原生侧靠另写视图 + `Theme` 令牌 + area 自绘绕开）；给出 B（类名别名表，框架不解析 CSS 只查表，结果并进 StyleMatrix 管道）与 A（内置 CSS 子集解析器，收益受结构性天花板限制）两条路径的边界。**GOALS 风险 10** 记下开放问题"要不要单视图双渲染"（要 → 先做 F28；不要 → 维持 per-target 视图当已知取舍）；**backlog 新增 F28**（类名别名表，触发条件=单视图需求）与 **F29**（状态类的语义映射——`.is-on` / `.is-buy` 表达的是"状态 → 表现"，即便有别名表也要单独定约定） | 判定依据：两个 demo 的类名/规则普查 + `native/**` 的 `css_class` 零使用（market 唯一一处是解释"原生控件没有样式位"的注释） |
| 2026-09-15 | **Windows 首测后的改进建议入库**（纯文档，不改代码）：backlog 新增 **F25**（根容器对 stretchy 链不透明——应用替框架内部节点买单；建议透明化，改默认语义需一轮独立验收）、**F26**（label 天然宽度顶高窗口最小宽度且无提醒，与 F24 一并把提醒挪到挂载期）与"工程化与流程"一节 **E1**（Windows CI：无 GUI 也能跑桩测与真控件冒烟）、**E2**（单出一节"平台能力矩阵"）、**E3**（两个 demo 的 launcher 引导逻辑同构重复）、**E4**（Windows 上 `focus` / 窗口最小尺寸可真实现，等真实需求）；GOALS 风险 8 补 Windows 侧运行环境与"本机无图像理解模型时怎么验证"、**风险 9** 记平台差异治理与"是否把 Windows 列入 N5 必测平台"的待决策；Roadmap 远期加"Windows 平台加固" | 判定依据全部来自 2026-09-15 的 Windows 实测（四象限 stretchy 探针、`GetWindowRect` 逐节点几何遍历、截屏像素采样） |
| 2026-09-15 | **Windows 平台首次实测通过**（Ruby 4.0.6 x64-mingw-ucrt，本机无 GUI 以外的 macOS 依赖）：libui 0.2.4 有 `x64-mingw-ucrt` 预编译包，`bundle install` 直接可用；套件 **120 runs / 345 assertions / 0 failures / 0 skips**（`CITRINE_NATIVE_GUI=1`，真窗口路径全跑）；`libui_scenario.rb` 默认与 `--gui` 均 SMOKE_OK。**Windows 与 macOS 的实测差异**：① **box 布局的 stretchy 链在 Windows 是严格的**——框架 `setup_root` 的根容器（非 stretchy box）与每层"参与拉伸的 box"都必须 stretchy，链在任一层断开，里面的 stretchy area 就塌成 0×0 且 **Draw 一次都不触发**（macOS 对窗口直系子元素宽容，同一棵树看不出问题）；四象限实测（根±stretchy × area±stretchy）只有"全 stretchy"拿到高度。**后果**：dev_mode 的"面板被压扁"提醒挂在 Draw 回调里，Windows 的 0×0 情形 Draw 不跑 → **提醒永远不会亮**（盲区，记 backlog F24）。② **Windows 的 libui 二次 `uiInit` 报错**（"registering utility window class; code 1410 类已存在"，打到 stderr 且返回错误串）——macOS 上第二次 init 是静默 no-op；适配层 `init` 加幂等守卫 + `shutdown` 复位（GUI 冒烟里多个 App 顺序复用同一 backend，第一次 teardown 后必须允许重新 init，否则第二次 `uiNewWindow` 直接 abort）。③ **裸 area 直接当组件根**会落进非 stretchy 根容器 → Windows 下一帧都不画；冒烟场景包了一层 stretchy stack（遵循 F11 判据）。④ ObjcBridge 不可用路径全部如实降级：`focus`/`window_is_key?` 返回 false、`clip_rect` 回退 Clip*——键盘焦点 Windows 上**点击即入**（libui 的 WM_LBUTTONDOWN 自己 SetFocus），无需 macOS 的 activate/makeFirstResponder。⑤ 探针方法：user32 `GetWindowRect` + 逐节点几何遍历 | 框架改动仅两处：`Widgets::Libui#init` 幂等 + `shutdown` 复位；测试改动：`libui_scenario.rb` 的 AppKitProbe 加 macOS 守卫（非 macOS 平台对应断言记 skip，不算失败）+ SmokePanel/SelfDrivenPanel 布局补 flex_grow |
| 2026-09-15 | **提交推送（D-1①）+ v0.1.0 首发与一次失败复盘**：四个提交落库（框架 / 文档 / 测试 / 发布，34 个条目清零）；CI 首跑 **macos-latest + windows-latest 矩阵全绿**（E1 的"待首次运行确认"关闭）；打 `v0.1.0` 标签触发 Release 工作流——**首跑红在门禁**：release.yml 原来整个 job 跑在 ubuntu-latest，libui 的 GTK 后端在无显示服务器上是 C 层 g_error 直接 abort（"Cannot open display" → Gtk-ERROR，子进程 exitstatus 变 nil），冒烟脚本里 `rescue StandardError` 拦不住，`LIBUI_UNAVAILABLE` 兜底走不到。**首发红了两轮、各自教了一条**：① 第一推红在门禁——release.yml 原来整个 job 跑在 ubuntu-latest，libui 的 GTK 后端在无显示服务器上是 C 层 g_error 直接 abort（"Cannot open display" → Gtk-ERROR，子进程 exitstatus 变 nil），冒烟脚本里 `rescue StandardError` 拦不住，`LIBUI_UNAVAILABLE` 兜底走不到 → 门禁挪到 macOS（真原生后端，顺带覆盖 ObjcBridge/AppKit 对照断言），`libui_scenario.rb` 在 init **之前**按"Linux ∧ DISPLAY/WAYLAND_DISPLAY 均空"预判输出 LIBUI_UNAVAILABLE（CI 注释里"Linux 真控件路径整体跳过"从此为真）；② 第二推门禁过了、产物也附了，红在最后一步——`rubygems/release-gem` 的 git 步骤固定在 workspace **根**跑（`git config --local`：fatal not a git repository），而本仓门禁要给 Gemfile 的 path 依赖摆同级 citrine，检出只能在子目录；release-gem 还要 `bundle exec rake release`，根检出下 Gemfile 解析不了、重解析又会弄脏锁文件（guard_clean 拦）→ 最终结构 **gate（macos+windows 矩阵，与 CI 同，子目录检出）+ gem（needs: gate，根检出：校验标签 → gem build → 附产物 → configure-rubygems-credentials（release-gem 内部同款动作）→ gem push）**，不需要 bundler、没有锁文件问题 | 按 RELEASING §四处置：门禁失败没有任何产物发布（`gh release list` 确认为空）→ 删标签、修复、重打；本机预发布检查 `consumer_smoke` 10/10 通过后才推标签。**第三推全绿并真实发布**：rubygems.org API 返回 0.1.0（依赖/元数据齐全）、GitHub Release 附产物、下载的发布产物 `gem install --local` → 解析器自动补 citrine 0.2.0 → 仓库外 require + 桩渲染 `计数：3`；CI 连跑两轮矩阵全绿 |
