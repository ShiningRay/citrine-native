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

### 4.5 样式子集（v0）

Citrine 的样式是受限 IR（snake_case 键，决策 #10）。原生控件没有 CSS，
v0 只映射可落地的键：

- 容器：`gap`（→ `uiBoxSetPadded` 粗粒度映射，先只有 0/非 0 两档）
- 尺寸：libui 布局是拉伸式的，width/height 大多不适用——**不映射**，
  dev_mode 提醒
- 弹性：`flex_grow`（数值 > 0 → 该子控件在父 box 里 stretchy，即"吃掉剩余空间"；
  与 CSS flex-grow 语义同构）。这是 N1 新增的映射，见变更日志
- 颜色/字体：libui 属性文本（attributed string）能力有限，v0 不映射，
  评估后决定是否引入 `uiAttributedString`

映射到控件自身的既有语义（不算样式）：`disabled` 透传属性 → 控件禁用态。

原则：**不支持的样式键/属性在 dev_mode 下提醒，绝不静默丢弃**（主仓 F11 的教训）；
元素级的不支持（如 textarea）则**始终报错**——那不是"样式降级"，是页面结构缺一块。
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
| **N3** | 响应式语义回归：keyed 复用、块级重建、错误边界、透明容器在本后端的实证 | CRuby 单测覆盖 Renderer 语义（复用主仓 test/ 的测试思路，widget 适配层可打桩，CI 无需真窗口） | ⏳ 部分提前完成（N1 起已建桩后端 + 29 项语义断言），剩余：把主仓 test/ 的断言清单逐条对齐 |
| **N4** | 事件面与生命周期完整性：on_change/on_enter/on_focus/on_blur、禁用态、定时器方案 | 对照主仓元素/事件词表出支持矩阵，未支持项全部有 dev_mode 提醒 | ⏳ 部分完成：`disabled` 已映射、定时器已随 NA-1 落地；**按键事件缺口由 NA-1 的自绘面板关闭**（`on_key`/`window_key` 经聚焦面板转发）；entry 上的 on_enter 仍不可用（libui 限制） |
| **NA-1** | 自绘面板（area）：绘制图元 + 鼠标/键盘事件 + 重绘调度 + 面板句柄 + 定时器（冻结接口见 [docs/design/native-area.md](docs/design/native-area.md)） | 桩后端语义测试全覆盖；真控件冒烟含"画矩形与中文文本 + 尺寸/外接矩形合理 + 拆解无泄漏"；键/鼠标事件注册成功（合成结构体走真闭包） | ✅ 完成（2026-09-15，实测结论与限制见设计文档第 5 节；两个 demo 的移植障碍由此清除） |
| **N5** | dogfooding + 发布准备：移植一个真实应用（候选：beryl 的某个面板或 market-terminal 的简化版） | gem 0.1.0 发布（Trusted Publishing 沿用主仓 OIDC 模式） | ⏳ 未开始 |

远期（不在本 Roadmap 承诺）：GTK 第二后端、富文本/表格控件、打包壳
（与主仓 M4b 汇合）、菜单栏/系统托盘等桌面能力。

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
5. **命名**：citrine-native 沿用 citrine-stream 的生态命名惯例；
   rubygems.org 占用情况在 N5 发布前确认
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
   `bundle install`；无 GUI 的 runner 只会跑桩后端测试，真控件冒烟自动跳过

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
