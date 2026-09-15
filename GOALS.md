# GOALS.md — citrine-native 设计与计划

> Citrine 组件的 CRuby 原生运行时。本文档是本仓库的主文档：定位、技术选型、
> 架构设计、决策与 Roadmap 全部记录于此（沿用 citrine 主仓的 GOALS.md 惯例）。

## 一、定位与愿景

**一句话**：用纯 Ruby 写的 Citrine 信号式组件，不经 Opal、不编译成 JS，
`ruby app.rb` 直接在 CRuby 里启动为一个原生控件桌面应用——Shoes 的 2026 年版。

```ruby
# examples/counter.rb（目标形态，N1 验收）
require "citrine-native"

class Counter < Citrine::Component
  state :count, 0

  def view
    stack(gap: 8) do
      label { "计数：#{count}" }
      button("点我 +1", on_click: -> { self.count += 1 })
    end
  end
end

Citrine::Native.run(Counter, title: "计数器", width: 400, height: 300)
```

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

| 钩子 | libui 实现要点 |
|---|---|
| `setup_root(root, element)` | element 语义重定义为窗口描述（title/尺寸），创建 `uiWindow` + 根容器 |
| `create_dom(node)` | 按 node.type 创建控件（`node.dom` 从"DOM 元素"重解释为"原生控件句柄"） |
| `attach(node, parent)` | `uiBoxAppend`（box 模型天然顺序追加，与基类"attach 一律追加到末尾"的约定一致） |
| `attach_before(node, parent, anchor)` | 子组件信号重跑的落位（S1-2）：libui 无 insert-at，需按索引重建父容器子序列或隐藏式重排——**N1 的关键技术验证点** |
| `detach(node)` | 从父 box 删除 + `uiControlDestroy` |
| `apply_props(node)` | 幂等重设属性（受控 value/checked、样式子集、禁用态） |
| `bind_events(node)` | `uiButtonOnClicked` / `uiEntryOnChanged` 等 → `Component#handle_event` 分发 |
| `set_text(node, text)` | `uiLabelSetText` / 控件文本写入 |
| `setup_widget(node)` | 受控控件初值（text_input 的 value Signal 双向绑定、check_box 的 checked） |
| `reactive?` | `true`（信号驱动更新正是本运行时的存在意义） |

### 4.3 元素词表 → 控件映射（v0）

| DSL | 控件 | 备注 |
|---|---|---|
| `stack { }` | `uiNewVerticalBox` | |
| `row { }` | `uiNewHorizontalBox` | |
| `box` | box（按 direction） | 无方向时默认 row，沿用主仓 G-8 提醒 |
| `label { "..." }` | `uiNewLabel` | 文本经 set_text |
| `button("...", on_click:)` | `uiNewButton` | |
| `text_input(value:, placeholder:)` | `uiNewEntry` / `uiNewPasswordEntry` | type: "password" 已有语义，直接映射 |
| `check_box(checked:, on_change:)` | `uiNewCheckbox` | 文本标签走 block/内容 |

S2-1 扩充的 HTML 词表（a/img/ul/li/table/form/select/textarea/video…）与
`element(:任意标签)` 逃生舱**在 v0 不支持**：原生侧没有对应概念，
开发模式（`Citrine.dev_mode?`）下遇到未支持元素直接报错并给出替代建议，
不静默降级。后续按需逐个评估（textarea→`uiNewMultilineEntry` 之类）。

### 4.4 主循环与线程模型

- libui 的 `uiMain` 占主线程跑事件循环；所有控件回调、Signal 写入、Effect
  重跑都发生在主线程——**没有跨线程问题**，`Citrine.batch`（S1-1）直接可用
- GVL 注意事项：长任务（网络/文件）必须放后台线程 + 回主线程写信号
  （libui 提供 `uiQueueMain`）；这一点写进 README 的使用约束
- 定时器：v0 不提供框架级 timer API；`effect` 宏里的 `Thread` + `uiQueueMain`
  是临时方案，正式方案留待 N4 评估

### 4.5 样式子集（v0）

Citrine 的样式是受限 IR（snake_case 键，决策 #10）。原生控件没有 CSS，
v0 只映射可落地的键：

- 容器：`gap`（→ `uiBoxSetPadded` 粗粒度映射，先只有 0/非 0 两档）
- 尺寸：libui 布局是拉伸式的，width/height 大多不适用——**不映射**，
  dev_mode 提醒
- 颜色/字体：libui 属性文本（attributed string）能力有限，v0 不映射，
  评估后决定是否引入 `uiAttributedString`

原则：**不支持的样式键在 dev_mode 下提醒，绝不静默丢弃**（主仓 F11 的教训）。

## 五、组件代码的可移植约束

组件想同时跑浏览器与本运行时，必须只依赖平台无关 API：

- 组件定义文件**不得** `require "citrine/browser"` / `citrine/canvas`
  （平台入口由启动文件选择，与主仓 examples/components.rb 的共享模式相同）
- 不碰 `Native`/backtick JS（本就只存在于 Opal 侧）
- 数值语义用 `Citrine::Num`（两端一致性的既有保障）
- 已知两端语义差异（v0）：`window_key` / `on_key` 不支持（libui 键盘事件需
  area 控件，N4 评估）；`ref:` 句柄在原生侧是控件对象而非 DOM 元素；
  portal/suspense/fragment 的透明容器语义由基类保证，理论上免费获得，
  需在 N3 用测试实证

## 六、Roadmap（计划）

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **N0** | 仓库骨架 + 设计文档（本文档） | gemspec/Gemfile/入口占位可 `bundle install`；本文档评审通过 |
| **N1** | 最小闭环：NativeRenderer + App 入口，支持 stack/row/label/button | Counter 示例在 CRuby 起真窗口，点击精确 +1（对齐主仓 M0 Spike A 的验收口径）；`attach_before` 落位问题有结论 |
| **N2** | 输入控件：text_input 受控双向绑定（IME 在原生控件天然可用）、check_box | Todo 示例完整可玩（增删、勾选、回车提交） |
| **N3** | 响应式语义回归：keyed 复用、块级重建、错误边界、透明容器在本后端的实证 | CRuby 单测覆盖 Renderer 语义（复用主仓 test/ 的测试思路，widget 适配层可打桩，CI 无需真窗口） |
| **N4** | 事件面与生命周期完整性：on_change/on_enter/on_focus/on_blur、禁用态、定时器方案 | 对照主仓元素/事件词表出支持矩阵，未支持项全部有 dev_mode 提醒 |
| **N5** | dogfooding + 发布准备：移植一个真实应用（候选：beryl 的某个面板或 market-terminal 的简化版） | gem 0.1.0 发布（Trusted Publishing 沿用主仓 OIDC 模式） |

远期（不在本 Roadmap 承诺）：GTK 第二后端、富文本/表格控件、打包壳
（与主仓 M4b 汇合）、菜单栏/系统托盘等桌面能力。

## 七、风险与开放问题

1. ~~**libui gem 的动态库分发**~~（N1 前置验证，**已于 N0 提前验证通过**）：
   libui 0.2.4 提供 arm64-darwin 预编译平台包，`bundle install` 直接装上、
   `LibUI.init/uninit` 冒烟通过——动态库随 gem 分发，"脚本即应用"体验成立。
   注意 Ruby 绑定顶层模块是 `LibUI`（不是 C API 的 `ui*` 前缀风格）
2. **`attach_before` 落位**（4.2）：libui box 只有 append/delete-by-index，
   子组件信号重跑后的原位恢复需要验证方案（按索引操作可行则无损，
   不行则需容器级重建——会动摇"细粒度更新"的卖点，N1 必须出结论）
3. **无窗口环境测试**：CI 不能开真窗口——渲染语义测试依赖 widget 适配层打桩
   （对齐主仓"Node 桩验收"的思路：同一组件、桩控件树、断言结构等价）；
   真实控件的冒烟用示例脚本手工验收
4. **citrine 依赖版本**：开发期 `path: "../citrine"`；发布依赖 citrine ≥ 0.2
   （RubyGems 已上架）。若 N1~N4 发现需要核心新增钩子，版本约束相应抬升
5. **命名**：citrine-native 沿用 citrine-stream 的生态命名惯例；
   rubygems.org 占用情况在 N5 发布前确认
6. **上游缺口（N0 实踩）**：citrine 0.2.0 的 `sourcemap.rb` 用了 `base64`，
   Ruby ≥ 3.4 起它不再是默认 gem，而 citrine gemspec 未声明——作为依赖被
   消费时在 Ruby 4.x 下直接 LoadError。本仓 gemspec 已加 `base64` 过渡依赖，
   上游修复（citrine 主仓 gemspec 补声明，走 PR 流程）发布后移除

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
