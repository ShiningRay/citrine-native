# 原生自绘面板（area）：设计

状态：**Finalized**（接口冻结，可据此实现；实现进度见 `docs/plan/analysis/demos-native.md`）
日期：2026-09-15 · 归属：citrine-native

## 1. 目标与背景

citrine-native 现有的"原生控件后端"能跑 stack/row/label/button/text_input/check_box，
但两个 dogfooding demo（citrine-sheets、citrine-market-terminal）需要它没有的三类能力：

1. **数据密集区的视觉**：表格线、深色面板、涨跌红绿、加粗数字、图表（蜡烛/分时/成交量）。
   libui 的 box 没有背景/边框，label 没有颜色——控件集给不了。
2. **任意元素的点击**：两个 demo 的单元格/行/面板都要点选；libui 只有 button/entry/checkbox 可点。
3. **键盘**：sheets 的整个交互模型（方向键、直接打字、Enter/Esc、⌘Z）走 `window_key`
   + `on_key`；libui 的 entry 不暴露按键事件，只有 `uiArea` 能拿到键盘。

结论：需要一层**自绘面板**（libui `uiArea`）能力——把需要视觉与键盘/鼠标自由度的区域
交给应用自己画、自己命中测试；输入类控件仍用原生控件（保留 IME 与原生观感）。

**非目标**（本次不做）：CSS 全集、像素级还原、动画、图片、表格控件、富文本编辑、
area 内嵌原生控件（libui 不支持，所以输入框必须放在 area 之外）。

## 2. 方案

新增一个渲染器可识别的元素类型 **`area`**（经 citrine 核心的逃生舱调用：
`element(:area, …)`——不改 citrine 核心，Draft→Finalized 时已确认核心无需改动）。

```
应用组件（平台无关逻辑 + 原生视图）
  └─ element(:area, on_draw:, on_click:, on_key:, …)   ← 自绘面板
        │  Native::Renderer#create_dom(:area) → Widgets#create_area
        │  事件：uiAreaHandler(KeyEvent/MouseEvent) → Citrine 事件视图 → Component#handle_event/handle_key
        └─ 绘制：应用回调拿到 Native::Painter（跨平台友好的薄图元层）→ libui draw 调用
```

### 2.1 元素契约（冻结）

```ruby
element(:area,
        ref: :grid,                       # 可选：refs[:grid] → 面板句柄（可用 #repaint 手动重绘）
        size: [w, h],                     # 可选：scroll: true 时是**内容尺寸**（必需）；
                                          # scroll: false 时忽略（尺寸由容器布局给）
        scroll: false,                    # true → uiNewScrollingArea（原生滚动条 + 滚轮）
        on_draw: ->(p) { ... },           # 必填：绘制回调，参数是 Painter
        watch: -> { ... },                # 可选：响应式依赖（见 2.4）
        on_click: handler,                # 可选：单击（本地坐标）
        on_mouse_down: handler,           # 可选
        on_mouse_up: handler,             # 可选
        on_mouse_move: handler,           # 可选
        on_key: handler_or_hash,          # 可选：area 有焦点时的按键（Citrine::KeyEvent）
```

未实现的 prop（例如 `style:`/`css_class:`）按既有口径处理：dev_mode 提醒并忽略。

**尺寸与拉伸是两件事**（NA-1c 澄清，SHEETS-2 的 D2 就卡在这条）：面板**不会**因为省略
`size:` 就自动撑满父容器——撑不撑满取决于它**在父容器（逐层往上）的 stretchy 情况**
（`scroll: true` 给内容尺寸、容器布局给视口、`style: { flex_grow: 1 }` 让它吃掉剩余空间）。
⚠️ "没有尺寸来源就 0×0"是过度概括（NA-1e 改）：**单个**非 stretchy 面板在 stack 里照样能
拿到剩余空间（实测 `stack { label; area }` → **760×544**，给不给 `flex_grow` 都一样）；
拿不到空间时才被 libui 的 box 布局解成 **0×0**（静默），而外层的嵌套 box 还会被内容钉死
（形状与数字见 §5.7.2）。

### 2.2 绘制接口 `Citrine::Native::Painter`（冻结）

只覆盖两个 demo 需要的图元；坐标是面板本地像素，左上角原点。

```ruby
p.rect(x, y, w, h, fill: "#14203a", stroke: "#1e2c48", line_width: 1, radius: 0)
p.line(x1, y1, x2, y2, color: "#1e2c48", width: 1)
p.polyline(points, color:, width:)                    # [[x, y], …]
p.polygon(points, fill:, stroke:, line_width:)        # 面积图（权益曲线）
p.text(string, x:, y:, color: "#e6ecf8", size: 13, weight: :normal, family: nil,
       align: :left, width: nil)                       # 富文本：颜色/字号/粗细/字体
p.measure_text(string, size: 13, weight: :normal, family: nil) → [w, h]
p.clip(x, y, w, h) { ... }                             # 块内裁剪
p.clip_rect                                            # 当前可见区 [x, y, w, h]（内容坐标）
p.content_size                                         # 面板内容尺寸 [w, h]
```

- **滚动面板的坑（已核对 libui-ng darwin/area.m：`if (!a->scrolling)` 才填 AreaWidth/Height）**：
  滚动面板的 `AreaWidth/AreaHeight` 是 **0**，尺寸只能由应用自己声明（`size:`）；
  `clip_rect` 是"当前可见区"，绘制用内容坐标、按 `clip_rect` 裁剪可见部分。
- **没有滚轮事件**（libui 的 uiAreaHandler 只有 Draw/Mouse/Crossed/DragBroken/Key）：
  需要滚轮就用 `scroll: true` 的滚动面板（NSScrollView 原生处理滚轮），
  再配 `AreaHandle#scroll_to` 控制滚动位置；普通面板拿不到滚轮。

- 颜色接受 `"#rgb"` / `"#rrggbb"` / `"#rrggbbaa"` / `[r, g, b]`（0..1 浮点）/ `:none`。
- `weight:` 接受 `:normal` / `:bold` 或 libui 的数值（100..900）。
- `text` 的 `(x, y)` 是整段文本**外接矩形的左上角**（libui 的语义，**不是基线**）；
  `align:` 只在同时给了 `width:` 时生效（libui 的对齐是"在给定宽度内对齐"），
  没给 `width:` 时按左对齐绘制并在 dev_mode 提醒。
- 一个面板一次 `on_draw` 调用只用一个 Painter 实例；Painter 不跨帧复用。
- 文本布局对象**跨帧**复用：缓存由**适配层按面板持有**（随面板销毁 `clear!`），不是
  "每 Painter 一份"——Painter 每帧新建，只有面板级缓存才可能跨帧命中。键除
  (string, size, weight, family) 还含 color / wrap 宽度 / align，见 §5.2。
- `Painter::Recording#measure_text`（桩后端）是**按字符数估算**的（CJK 按两字符宽），
  只够"量出来是正数 / 随字号变大 / 中文比 ASCII 宽"这类弱断言：实测 `"+2.60%"` @14
  估算 46.2 vs 真 50.46（**偏窄 8%**），CJK 偏宽 ~11%。所以**桩测里别断言"这个宽度刚好
  放得下"**——那会长在真机折行；文本贴合类断言放真控件冒烟（那里有真度量）。

### 2.3 事件视图（冻结）

- 鼠标：`Citrine::Native::PointerEvent < Citrine::Event`，字段 `x`、`y`（本地坐标）、
  `type`（`"click"` / `"mouse_down"` / `"mouse_up"` / `"mouse_move"`）、
  `modifiers`（`{shift:, ctrl:, alt:, meta:}`）、`raw`。
  命中测试由应用负责（面板是矩形的，应用知道自己的布局——与 canvas 后端同思路）。
  （**没有 `"wheel"`**：libui 的 area 不带滚轮事件，见 2.2 的说明。）
  NA-1 的实现加法（契约外但稳定，应用可以用）：`button`（libui 的按钮编号 1 左 / 2 中 /
  3 右）、`left?`、`shift?`/`ctrl?`/`alt?`/`meta?`、`command?`（⌘ 或 Ctrl，与
  `KeyEvent#command?` 同口径）、`position`。
- 键盘：`Citrine::KeyEvent`（核心既有视图）。`key` 归一为 DOM 风格名字：
  `"ArrowUp"/"ArrowDown"/"ArrowLeft"/"ArrowRight"/"Enter"/"Escape"/"Tab"/"Backspace"/
  "Delete"/"Home"/"End"/"PageUp"/"PageDown"/"F1"…`，可打印字符给字符本身（`"a"`/`"1"`/`" "`），
  修饰键走 `shift?`/`ctrl?`/`alt?`/`meta?`。`on_key` 支持 Hash 键表（`{"Enter" => :commit, else: …}`）。
  **`raw` 的形态是约定的一部分**（backlog F5）：它是原生侧的原始载荷 Hash
  （`{kind: :key, key:, ext_key:, modifiers:, up:}`，转发窗口级按键时还有 `target:`），
  **不是 nil、也不是对象**——`window_key` 应用会读 `raw[:target][:tagName]` 这类路径
  （DOM 侧同一入口），换成对象会让它们当场崩。要加字段请往后加，别改已有键的含义。
- 焦点（**已实测**，探针 /tmp/area_focus_probe4.rb）：窗口 `uiControlShow` 之后
  **不是 key window**（`[NSApp keyWindow]` 为 nil、`firstResponder` 为 nil）→ 一个键也收不到；
  调用 `[NSApp activateIgnoringOtherApps:YES]` 之后窗口变 key，且 **area 自动成为 first responder**，
  键盘事件实测可达（探针收到 `Key=97`（"a"）/`32`（空格）的按下与抬起）。
  **这条只在 macOS 上成立**：Windows 上系统在 `uiControlShow` 之后自己把焦点给窗口，且
  **点击面板即入焦点**（libui 的 `WM_LBUTTONDOWN` 自己 `SetFocus`）——"挂载即自动聚焦"
  在 Windows 不可用（要用户先点一下面板）。两种实现的对照见
  [platform-matrix.md](platform-matrix.md) 第一节。
  由此得到对实现的三条硬要求：
  1. `App` 在 `window_show` 之后必须**激活应用**（macOS；提供 `activate:` 选项可关），
     否则"窗口看得见、键盘用不了"；
  2. `AreaHandle#focus` 用 `makeFirstResponder:` 实现（macOS 专用；其他平台返回 false 并说明）；
  3. 点击面板同样能拿到焦点（NSView 惯例），应用侧仍建议给一句提示。
  `window_key` 声明的全局快捷键**由聚焦中的 area 转发**——即：v0 的"window 级键盘"
  语义是"焦点在某个原生面板上时可用"。
  两条补充口径（NA-2 实测，写在这里免得把环境时序当回归）：`AreaHandle#focus` 返回 false
  有**三种**含义——① 平台没有这条能力（非 macOS）；② **调用瞬间没有 key window**
  （`[NSApp keyWindow]` 为 nil：窗口刚显示、或焦点正被别的应用抢着）；③ **key window 在、
  但 AppKit 没把焦点给目标**（NA-1e 补：游离的 areaView、纯 `NSView`、`uiControlDisable`
  过的面板实测都是"BOOL 返回 YES 却没生效"——判据见下一条）；`activate: true`
  是**尽力而为**（macOS 协作式激活）：采样里常见 `false@0.4s → true@0.8s`，也被别的应用
  抢走过。所以"启动后立刻打字"可能丢键，应用值得给一句"点一下面板"；测试断言要给几次机会。
  第三条（NA-1d）：`AreaHandle#focus` 的返回值 = **两层判据的合取**——①
  `[keyWindow makeFirstResponder:]` 的 BOOL 受理了请求；② 窗口此刻的 `firstResponder`
  **真的是这个视图（或它的后代）**。旧实现只要"窗口是 key window"就返回 true，应用侧按
  契约检查返回值也察觉不到 AppKit 拒绝。为什么必须加 ②（NA-1d 探针 5 实测，macOS 26 /
  arm64）：只要窗口是 key window，`makeFirstResponder:` 对**接受与不接受** first responder
  的目标**都返回 YES**（不接受时 AppKit 把**窗口自己**设成 first responder，实测目标：
  游离 areaView、不可编辑的 NSTextField、普通 boxView/NSView、`uiControlDisable` 过的面板
  全是 YES）——只转达 ① 等于
  转达一个不诚实的答复。所以现在的语义是"**返回 true ⇔ 焦点真的落到这个面板上**"，
  应用可以放心检查返回值；② 用 `isDescendantOf:` 判（滚动面板的 first responder 是
  document view，不是 NSScrollView 本身）。
- **回车提交**：area 拿得到 Enter；原生 entry 仍然拿不到（libui 限制），
  所以"输入框里按回车"要么改成显式按钮，要么由 area 侧处理。

### 2.4 重绘时机（冻结）

两条一起用，保证"不错帧"优先：

1. `watch:`（可选）——应用在该回调里读它绘制所依赖的信号；渲染器把它跑在
   **该节点的 Effect** 里，依赖变化 → 标脏 + `uiAreaQueueRedrawAll`。
2. 粗粒度兜底——每次响应式收敛（`finalize`/`run_block`/`rerun_component_view` 收尾且
   `@parents.empty?`）与面板尺寸变化时，把所有活着的面板标脏重绘（与 canvas 后端同思路）。

绘制回调在 libui 的 Draw 回调里执行（不在 Effect 内），其中的信号读取不建立订阅。

### 2.5 面板句柄（冻结）

`ref:` 拿到的是 `Citrine::Native::AreaHandle`（不是 libui 裸指针），提供：

```ruby
handle.repaint                      # 立即标脏（等价于"我知道内容变了"）
handle.scroll_to(x, y, w, h)        # 仅滚动面板：把 (x,y,w,h) 滚进视口（uiAreaScrollTo）
handle.focus                        # 把键盘焦点给面板：macOS 走 [keyWindow makeFirstResponder:]，
                                    # 其他平台返回 false 并说明（见 2.3 的实测结论）
```

- `repaint` 在 `on_draw` **内部**调用也安全：适配层会把这次请求排到当前绘制收尾的下一轮
  主循环（AppKit 在绘制中忽略 `setNeedsDisplay`，"自排队动画"因此不会冻在第一帧，见 §5.7）。
- `focus` 返回 false 的**三种**含义见 2.3 的两条补充口径。
- **`ref:` 登记在"产出该元素的组件"上**（NA-2 记录项）：`element(:area, ref: :grid)` 写在
  哪个组件的 `view` 里，`refs[:grid]` 就挂在哪个组件实例上——**根组件看不到子组件内部的 ref**。
  要让上层拿到句柄，由子组件自己暴露读取器：

  ```ruby
  class GridPanel < Citrine::Component
    def view = element(:area, ref: :grid, …)
    def area_handle = refs[:grid]        # 上层：panel.area_handle.repaint
  end
  ```

### 2.6 定时器（冻结；原编号 2.5，内容未变）

```ruby
Citrine::Native.every(200) { tick }   # → Timer 句柄，可 #stop；主线程执行
Citrine::Native.after(500) { once }
```

实现：后台 `Thread` + `sleep`，到点用 `Widgets#queue_main` 排到主线程（与文档里给应用
的跨线程规则一致，不引入 libui `uiTimer` 的主线程约束）。句柄在 `on_unmount` 里 `#stop`。

活动后端取自 `Citrine::Native.active_widgets`，而它是**全局单值**（"活动渲染器 = 最后建立的
那个"，与核心同口径）——也就是**假设"一个进程一个 App"**：同进程起两个 Renderer/窗口时，
先建的那一边的定时器会排到后建那个后端上。要么一进程一 App，要么等 `every(ms, backend:)`
这类显式绑定（尚未提供，见 backlog F10）。

## 3. 与既有部分的边界

- `Widgets` 适配层新增：`create_area(on_…, size:, scroll:)`、`area_queue_redraw(area)`、
  `area_set_focus?`（若 libui 无 API 则不做）。
- 适配层的**多路事件分发**与"单回调位"约束同样适用于 area（Draw 只有一个回调，事件各自一个）。
- Painter 只依赖 libui 的 draw/attributed-string 接口，放在 `widgets/libui.rb` 之外的
  `native/painter.rb`，以便 Memory 后端给出 `Painter::Recording`（测试断言"画了什么"）。
- 平台无关核心（citrine 主仓）**不改**：`element(:area)` 走既有逃生舱。

## 4. 验收场景

1. **框架（桩后端）**：area 元素创建/事件分发/重绘调度/定时器在 Memory 后端有单元测试；
   `Painter::Recording` 能断言图元序列（两个 demo 的绘制测试都用它）。
2. **框架（真控件）**：真 libui 冒烟：建 area → 画矩形与中文文本 → 尺寸/文本外接矩形合理 →
   有序拆解无泄漏；键/鼠标事件**注册**成功（投递需人手一次，见任务验收记录）。
3. **sheets**：`bin/native` 起真窗口 → 方向键移动选区、直接打字编辑、Enter 提交、
   Esc 取消、⌘Z 撤销；改 B2 数字后 1 秒内毛利/毛利率与检查器更新。
4. **market-terminal**：`bin/native` 起真窗口 → 行情每档跳动（暂停/1x/2x/4x 生效）、
   蜡烛/分时图重绘、点自选行切换标的、下单面板市价/限价下单与撤单成功、持仓/成交/统计更新。

## 5. 实现说明（NA-1，2026-09-15）

2.1–2.6 的接口与语义**已全部落地**（含 2.5 的 `AreaHandle` 与 2.2 的 `clip_rect/content_size`）；
以下是实现期实测到的平台约束与对设计的补充。代码位置：`lib/citrine/native/painter.rb`
（Painter / TextCache / Recording）、`pointer_event.rb`、`area_handle.rb`、`timer.rb`、
适配层 `create_area / on_area_* / area_queue_redraw / area_scroll_to / area_focus /
area_scrollable? / window_activate`（`widgets.rb` 协议 + libui/Memory 两个后端）、
渲染器 `create_area / bind_area_events / dispatch_area_key / repaint_areas / register_ref`。

### 5.1 尺寸（2.1）

- **`scroll: true` 必须给 `size:`**：它是 `uiNewScrollingArea` 的内容尺寸（创建时定死），
  缺了渲染器直接报错。原因是滚动面板下 `uiAreaDrawParams.AreaWidth/AreaHeight` **恒为 0**
  （`ui.h`："only defined for nonscrolling areas"；darwin 实测 0×0），
  Painter 的 `width/height` 与 `content_size` 只能来自声明值。
  `size:` 是**内容尺寸**，**不是视口尺寸**——视口（能看见多大）由容器布局给，两者互不干扰
  （§5.7 有实测）。
- **`scroll: false` 的 `size:` 无法生效**：libui 的 `uiAreaSetSize` 只对滚动面板有效，
  对非滚动面板调用会走 `uiprivUserBug` **直接终止进程**（实测 exit 134）。
  面板尺寸由外层容器布局决定；渲染器在 dev_mode 下提醒并忽略（提示改用 `scroll: true`）。
- 尺寸变化不需要额外重绘钩子：libui 的 `areaView` 在 `setFrameSize:` 里自己
  `setNeedsDisplay:YES`（darwin/area.m）；每帧 Painter 的尺寸都取自当次 Draw 参数。
- **面板拿不到空间是静默的**（P2.1 / SHEETS D2）：libui 的 box 布局里在容器链上逐层拿不到
  stretchy 空间的控件会被 Auto Layout 解成 **0×0**，还会把兄弟挤扁，但**没有任何报错**——
  应用只看到"面板不见了"。⚠️ 别把它简化成"没有尺寸来源就 0×0"（NA-1e 修正）：**单个**
  非 stretchy 面板在 stack 里照样拿到剩余空间（实测 `stack { label; area }` → **760×544**，
  给不给 `flex_grow` 都一样）；0×0 / 细条出现在"同一 box 里两个非 stretchy 面板互相抢"或
  "被 label 钉住的嵌套链"这些形状里（§5.7.2 有整棵树与数字）。
  渲染器在绘制回调里按节点去重给 dev_mode 提醒，**三条判据分开报**
  （NA-1d 扩的，因为可操作建议不同）：
  1. Painter 拿到的尺寸是 0/负（就是 0×0 那种）；
  2. **非滚动**面板的 Painter 尺寸非 0 但**小到画不出东西**（阈值 24pt ≈ 一行 14pt 文本：
     非滚动面板下 Painter 尺寸就是控件的真实 frame，实测被兄弟挤成 **753×16** 的面板旧口径
     一言不发）。⚠️ 判据 ② **不适用于滚动面板**（NA-1e）：滚动面板下 Painter 拿到的是声明的
     **内容**尺寸，"内容矮、视口正常"是健康形状（反例 `scroll: true, size: [2000, 20]` 的横向
     缩略图条在真 GUI 里实到 760×544、视口 743×527，旧口径却打印"控件被挤成一条：2000.0×20.0"
     并给出无关的容器链建议）；滚动面板的"小"只由判据 ③ 说话；
  3. 滚动面板的**真实可见视口**小到画不出东西（后端读 clip view 的真实边界：滚动面板下
     Painter 拿到的是声明的**内容**尺寸 2000×2000，视口塌成 **736×16** 时旧口径同样
     一言不发，而这是 SHEETS-2 现场最像的形状）。
  提示文本指向**容器链**（"面板所在的每一层容器在各自父容器里要有 stretchy 尺寸"），
  而不是"给面板自己 `flex_grow`"——后者在"已经有 `flex_grow` 仍被压"的形状里是空转
  （判据与反例见 §5.7.2）。
  **已知盲区**（如实记录）：① 阈值 24pt 是启发式，真要做细条（如 20pt 高的迷你图）也会
  被提醒，dev_mode: false 可关；② 后端拿不到真实几何时（非 macOS、或后端不实现
  `area_visible_size`）判据 ③ 报不出来，那种环境只能应用自己看 `painter.width/height`；
  ③ 判据 ②③ 只看"面板自己多大"，**不看它的容器多大**，所以"面板占容器极小比例"这种
  形状只能靠应用自己量（框架没有容器几何的读取路径）；
  ④ **滚动面板的任何尺寸异常都只剩判据 ③ 兜**（② 已对它关闭，NA-1e）：后端给不出视口几何时
  （同 ②）连"控件本身被挤扁"都不会提醒——这是有意选的方向（宁可漏报也不误报）；
  ⑤ 判据 ③ 的数字取自**当帧原始读数**：滚动面板**首帧**可能还没布局完，`visibleRect` 报的是
  NSScrollView 自己的尺寸（含滚动条位，本机实测偏大 17pt：瞬态 743.5×16 vs 稳态 726.5×16）。
  触发与去重不受影响（每帧都查、按节点去重），**只有消息里的数字可能偏大**，提示文本里已如实
  标注（与 §5.7.6-6 记录的首帧 `clip_rect` 瞬态是同一件事）。

**挂载期的"严格后端上会塌"提醒**（backlog F24，2026-09-15 落地）——上面三条判据都挂在
**绘制回调**里，而 Windows 的 libui 对 stretchy 链断开的 area 是**完全**的 0×0、`WM_PAINT`
不会来 → Draw 不跑 → 一条都不会亮（macOS 上 0×0 面板仍有 Draw，所以这个盲区只在 Windows 上
看得见）。因此另开一条**挂载期**的静态判据（`Renderer#warn_strict_stretch_chain`，判据同
§5.7.2）：面板自己能 stretchy，且从组件根往下的**每一层 box** 在各自父容器里都 stretchy；
不满足就按节点去重提醒，并指出**断在第几层的哪个 box**（或"面板自己"）。它不看几何，所以
措辞是"在严格后端（Windows）上会塌成 0×0 且一次都不绘制"，不假装量到了尺寸；
只在 dev_mode 下出现。桩测锁了五条：面板自己不 stretchy / 祖先断在第 2 层 / 完整链不报 /
dev_mode 关时静默 / 无 area 的树不报。

### 5.2 绘制（2.2）

- 文本布局缓存的键，除设计里写的 (string, size, weight, family) 还包含 **color /
  wrap 宽度 / align**：颜色是烘进 attributed string 的属性（涨跌红绿靠它），宽度与对齐
  决定换行与外接矩形——少任何一项，命中就会拿到"另一段文本"的布局。
- 缓存的**生命周期是"每面板一份"**（适配层按面板持有，随面板销毁 `clear!`），
  而不是"每 Painter 一份"：Painter 每帧新建（2.2 的要求），跨帧复用只能靠面板级缓存。
- 必须显式释放的 libui 对象：`uiDrawFreePath`（每个图元画完立刻放）、
  `uiDrawFreeTextLayout`、`uiFreeAttributedString`、`uiFreeFontDescriptor`。
  两条反直觉的实测：**属性（uiAttribute）的所有权归 attributed string**
  （`uiAttributedStringSetAttribute` 之后再 `uiFreeAttribute` 是 double free）；
  **自建 `family:` 的字体描述符不能交给 `uiFreeFontDescriptor`**（它的 Family 指向我们
  自己的 buffer，交给它 free 会 abort 进程——实测 exit 134）。字号与字重写在字体描述符上
  （libui 用 `params.DefaultFont` 铺满整段），颜色作为属性烘进字符串。
- `(x, y)` 是整段文本外接矩形的左上角（libui 的语义，不是基线）；`Width < 0` = 不换行。
- **`clip_rect` 的来源**（2.2，NA-1c 修正，NA-1d 改理由）：
  - 非滚动面板取 `[0, 0, 面板宽高]`——darwin 下 `Clip*` 报的是"需要重画的范围"（脏区），
    非滚动面板那一帧的脏区是**整窗**（NA-2 实测 `[-20,-68,800,632]` vs 面板 760×528），
    不能直接用；
  - 滚动面板取 **`areaView` 的 `visibleRect`**（= NSScrollView 的 clip view 在内容坐标里的
    范围：origin 是滚动偏移、size 是**不含滚动条**的真实视口），再夹进声明的内容尺寸。
    不走 libui 的 `Clip*`——它只是 drawRect 的**脏区**（`dp.ClipX = r.origin.x`），
    局部重绘的帧里只是"新露出来的那条"条带（实测 `[0,900,743,100]`），拿它当可见区
    会漏画或画到滚动条下面（见 §5.7 的 D7；NA-1c 曾写"它比视口大、含滚动条占位"，
    NA-2 逐帧核对**否证**了这条）；读不到时（非 macOS、视图还没布局）退回 `Clip*` 并夹进内容尺寸。
  GUI 冒烟里与 AppKit 的 `visibleRect` 对拍过：尺寸与滚动后的 origin 都一致。
- **非滚动面板的绘制不会裁剪到面板矩形**：AppKit 的 `NSView` 默认 `clipsToBounds = NO`，
  实测一个 376×16 的面板把 2000×2000 的矩形画满了整窗（截图里绿像素覆盖 x 20..800）。
  也就是说 `clip_rect` 是"你该画在哪"的**提示**，不是限制——想限制就自己 `clip`（§5.7）。
- 无效颜色/字重/对齐（如 `align` 没给 `width`）在 Painter 内**收集**为提醒，
  由渲染器按 dev_mode 去重输出——Painter 每帧新建，自己 warn 会刷屏。

### 5.3 事件与焦点（2.3）

- **焦点/激活按要求落地**：`App#setup` 在 `window_show` 之后调 `window_activate`
  （`[NSApp activateIgnoringOtherApps:YES]`；`activate: false` 可关），
  `AreaHandle#focus` 走 `[keyWindow makeFirstResponder: uiControlHandle(area)]`。
  两条都靠 Fiddle 直通 libobjc（libui 没有暴露），非 macOS 上 `available?` 为 false、
  `focus`/`activate` 如实返回 false。GUI 冒烟里的机器可验证断言：
  `window_is_key?(window) == true`（实测：`uiControlShow` 之后为 false，这正是
  `activate: true` 默认值存在的理由）。`focus` 的返回值语义（两层判据：AppKit 受理 +
  `firstResponder` 真的是目标或其后代）见 2.3 的第三条补充口径。
- **没有滚轮**（v2 已从接口移除）：libui-ng 的 `uiArea` 不投递滚轮
  （`uiAreaMouseEvent` 没有滚轮字段；GTK 版把滚动按钮 4-7 显式忽略，注释写着
  "if we got here, that's a mistake"）。`on_wheel` 因此走既有"未支持的事件 prop"提醒口径，
  PointerEvent 也没有 `"wheel"` 类型。要滚动就用 `scroll: true` + `AreaHandle#scroll_to`。
- 键名归一是**适配层的职责**（libui 的词汇不外泄到渲染器）：ExtKey → DOM 风格名字
  （方向键/F1–F12/Home/End/PageUp/PageDown/Escape/Delete/Insert、小键盘数字与运算符），
  字符键走 Key 字段（`'\n'`→Enter、`'\t'`→Tab、`'\b'`→Backspace、空格与可打印字符原样）。
  **macOS 下 libui 给的是与 Shift 无关的等位字符**（小写字母/数字），Shift 走 `shift?`
  ——与 DOM 的 `ev.key`（大写）不同，应用判断大写请用 `shift?`。
- 面板的 `KeyEvent` 回调返回**整数**：应用认领了就返回 1（抑制系统提示音），
  **带 ⌘ 的按键一律返回 0**——libui 的 `sendEvent:` 在走菜单快捷键**之前**调用 area 回调，
  吞掉有绑定的菜单项（⌘H Hide、⌘⌥H Hide Others，以及应用自己用 `uiNewMenu` 建的菜单）
  会让用户按不动它。**回调本身照常触发**，所以应用自己处理的 ⌘Z/⌘B 不受影响——
  只是不再抑制系统默认处理。（NA-2 发现早期实现漏了这条：声明 `on_key` 的面板把 ⌘H 吃掉了；
  NA-1c 修好，见 §5.7 的真 OS 对照实验。注意 ⌘Q/⌘W 在 libui 默认菜单里**没有** key
  equivalent，别拿它们当反例。）
  ⚠️ 实现踩过：Fiddle 闭包声明的返回类型是 `int`，块里返回 `true/false/nil` 会在
  Fiddle 边界抛 `TypeError`，而且是在**穿过 libui 的 C 栈**时抛——必须 `? 1 : 0`。
- `MouseCrossed`（鼠标进出）与 `DragBroken`（拖拽打断）在适配层也做了多路分发：
  libui 调用它们前**不做 NULL 检查**，五个槽必须在创建时装满（这两个目前没有应用级 prop，
  装 no-op）。
- down/up → click 的配对（"在本面板按下又抬起"）放在**渲染器**里，与 DOM 顺序一致
  （mousedown → mouseup → click）；libui 只在 Down 时给 `Count`。

### 5.4 重绘（2.4）

- `uiAreaQueueRedrawAll` 本身就是"标脏 + 合并进下一帧"（darwin 下 `setNeedsDisplay:YES`），
  同一轮里重复排不会多画一帧，所以粗粒度兜底**不需要额外的脏标记**：收敛点
  （`finalize` / `run_block` / `rerun_component_view` 收尾且 `@parents.empty?`）
  把活着的面板各排一次即可。
  **例外：绘制过程中**（也就是在 `on_draw` 里调 `handle.repaint`）AppKit 会忽略这次
  `setNeedsDisplay`——适配层把绘制期收到的请求记下来，等这次绘制收尾再经 `queue_main`
  排到下一轮（同一面板一轮只排一次），见 §5.7。
- 挂载期可能排队多次（`watch:` 首次求值 + 块收敛 + `finalize`），对 libui 无成本；
  桩后端能据此数出"排了几次"，测试按 delta 断言。
- GUI 冒烟验证过三条通路都真能重画：`watch:` 依赖变化、手动 `AreaHandle#repaint`、
  滚动（`uiAreaScrollTo` 引起）。

### 5.5 定时器（2.6）

- 按设计用后台 `Thread` + `sleep`，到点经 `Widgets#queue_main` 排回主线程；
  `#stop` 幂等，且"排队到执行"之间会再查一次停止位——组件卸载后不该再被定时器叫醒。
- 活动后端取自 `Citrine::Native.active_widgets`（由 `Renderer` 建立时登记，与核心
  "活动渲染器"同一套路）；没有活动后端时定时器只提醒不假装工作。
- 观测到但未采用：本机 libui 0.2.4 的 `uiMainStep` 直接段错误（最小复现：起窗口 +
  `main_step(0)`），所以定时器不能走"自己泵循环"那条路，只能 `queue_main`。

### 5.6 验证

- 桩后端：`test/area_test.rb` 覆盖 2.1–2.6 的语义、句柄行为、提醒口径与卸载清理
  （NA-1c 追加：⌘ 键的五条返回口径、绘制期 repaint 的延后与合并、0 尺寸提醒；NA-1d 追加：定时器只用一次性队列槽、面板被压扁的三条判据与阈值边界、提示文本判据、focus 返回值转达）；
  `test/app_test.rb` 补 `activate:` 两条。
- 真控件：`test/support/libui_scenario.rb` 的面板段——五个回调槽、未激活时
  key window 为假、合成 `uiAreaMouseEvent`/`uiAreaKeyEvent` 走**真闭包**、真文本度量/
  换行/缓存复用与释放、传错句柄 fail fast、拆解后适配层面板记账清零；
  NA-1c 追加：⌘/无修饰/无处理器三种真闭包返回值、`clip_rect` 与 AppKit `visibleRect` 对拍。
  `--gui` 模式追加：激活后窗口是 key window、`AreaHandle#focus`、
  真窗口下真绘制（矩形/折线/面积图/中文富文本/裁剪块）、`watch:` 与 `repaint` 驱动重画、
  滚动后 `clip_rect` 跟着走、滚动面板撑满容器、自排队动画真的出下一帧。
- OS 级投递：脚本侧覆盖"libui 结构体 → 事件视图"这段；**⌘H 的真 OS 对照实验**
  （`osascript -e 'tell application "System Events" to keystroke "h" using command down'`，
  读 `[NSApp isHidden]`）在 NA-1c 复跑过：修复前 `WITH_ON_KEY=1` → `hidden=false`
  且按键被面板吃掉；修复后 → `hidden=true`、`keys=[["h", true]]`（回调照常收到）。
- 真鼠标点击仍需人手（本环境 `CGEventPost` 被 TCC 拦掉，旁证见 NA-2 记录）。
- 泄漏/性能探针（不入库）：真窗口每帧 ~60 图元 + 40 段文本，30 秒 1484 帧，
  RSS 平坦（102→102.6MB，无线性增长）、帧间隔中位 ~20ms。
- GUI 模式下 stderr 可能出现 macOS 输入法子系统的
  `error messaging the mach port for IMKCFRunLoopWakeUpReliable`（非 bundle 进程激活时的
  系统噪音，与框架无关）；**默认（不开窗）路径 stderr 为空**，冒烟的泄漏断言盯的是后者。
- ⚠️ GUI 冒烟里的"窗口是 key window / `AreaHandle#focus`"依赖**协作式激活**：同机有别的
  应用（含其它 agent 的 GUI 进程、崩溃报告弹窗）抢焦点时会失败。判别方法：起一个**不含
  area** 的最小窗口观察 `window_is_key?`——它也为假就是环境，不是框架回归。

### 5.7 NA-1c 修复轮（2026-09-15，来自独立验收 NA-2 / SHEETS-2）

#### 5.7.1 ⌘ 键不再吞菜单快捷键（NA-2 P1）

- 规则：**`modifiers[:meta]` 为真一律回报"未处理"（返回 0），但回调照常触发**。
  策略**单点在渲染器 `dispatch_area_key`**（"on_key 的已处理语义"）：桩后端与真后端同口径，
  也才有测试锁得住；适配层 `key_area` 只如实转达订阅者的答复，不再自己判一次
  （消融实验：适配层那层判断与渲染器完全等价、删掉后真控件冒烟照样绿，所以按"最小改动"
  去掉，避免两处策略漂移）。只有**无 ⌘ 且确有处理器被调用**时才返回 1。
- 真 OS 对照实验（`⌘H`，读 `[NSApp isHidden]`，NA-1c 用同一条命令 A/B 复跑）：

  | 条件 | 修复前（当前代码去掉那道闸门） | 修复后 |
  |---|---|---|
  | `WITH_ON_KEY=0`（面板不声明 on_key） | `hidden=true`，`keys=[]` | `hidden=true`，`keys=[]` |
  | `WITH_ON_KEY=1`（声明 on_key） | `hidden=false`，`keys=[["h", true]]` ← 菜单被吞 | `hidden=true`，`keys=[["h", true]]` ← 回调照样收到 |

  命令：`WITH_ON_KEY=1 ruby -I <citrine-native>/lib -I <citrine>/lib <probe>.rb`，
  投递用 `osascript -e 'tell application "System Events" to keystroke "h" using command down'`。
  ⚠️ 投递偶尔落空（本机有别的应用抢焦点时 `keys=[]`），实验要跑几次取"面板确实收到按键"
  的那些轮次；判别环境问题的最小窗口见 5.6 的说明。

- 覆盖：桩后端 5 条（⌘ 不认领但投递、无修饰认领、Shift/Alt 只影响 ⌘、无处理器不认领、
  window_key 收了 ⌘ 也不认领）+ 真控件 4 条（⌘→0、无修饰→1、⌘ 仍投递、无 on_key→0）。

#### 5.7.2 滚动面板**吃** `flex_grow`（SHEETS-2 D2 的结论修正；NA-1d 重写判据）

SHEETS-2 的结论是"`flex_grow` 对滚动面板不生效（换成 `scroll: false` 就撑满）"。
**这条不成立**——探针复现后发现两件事：

1. **滚动面板与普通面板的 stretchy 行为一致**。下表是 NA-1d 复跑的**自己的数据**
   （窗口统一 800×600、margined → 内容 760×560；"结构"列就是组件的 `view` 整棵树，
   根容器是 libui 的竖排 box；数字是真 `NSView.frame`）：

   | 结构（`view` = …；样式一律写成 `style: { flex_grow: n }`，`gap` 照抄探针） | scroll: true | scroll: false |
   |---|---|---|
   | `stack { label; area(style: { flex_grow: 1 }); label }` | 控件 760×528、视口 743×511 | 控件 760×528 |
   | `stack { label; row(gap: 4, style: { flex_grow: 1 }) { stack(style: { flex_grow: 3 }) { area }; stack(style: { flex_grow: 2 }) { label } }; label }` | 控件 **376×16**、视口 359×16 | **376×16** |
   | `stack { label; row(gap: 4) { stack(style: { flex_grow: 3 }) { area }; stack { label } }; label }`（row **没有** flex_grow） | **712.5×16** | **712.5×16** |
   | `row(gap: 4, style: { flex_grow: 1 }) { stack { area(style: { flex_grow: 1 }) }; stack { label } }`（裸 row，没有外层 stack） | **712.5×560** ✓ | 712.5×560 ✓ |

   第二/三行说明"塌成 16pt"与滚动无关（`scroll: false` 逐位相同），且**把 area 全换成
   label 也一样塌**（第三行右侧只装 label，高度同样由 label 钉住）。
   `size:`（内容尺寸 2000×2000）也不参与视口计算：视口由容器给（743×511 / 359×16）。
   ⚠️ 数字与**整棵树**绑定：同一个 `row(...)` 放进"上下都夹着 label 的 stack"里是 16pt 高，
   单独当整棵 view 用就是 560pt 高（第四行）——早期版本的表把整棵树省略了，于是
   "树 ↔ 数字"对不上（NA-2 因此判它复现不出来）。
2. SHEETS-2 的"换成 `scroll: false` 立刻撑到 ~800×563"是**测量假象**：那是"画满整窗的绿色
   像素范围"，而**绘制不会裁剪到面板矩形**（AppKit `NSView` 默认 `clipsToBounds=NO`，
   实测 376×16 的面板把绿矩形画到 x 20..800 / y 0..564）。以 NSView 的 frame 为准才准。

**真因是 libui 的 box 布局**（libui-ng `darwin/box.m` 的 Auto Layout 约束 + 实测）：
box 的**主轴**约束链是 Required（`first.top == box.top`、`prev.bottom == next.top`、
`last.bottom == box.bottom`），一个**在父容器里没有 stretchy 尺寸**的 box 会被内容钉死
成固定尺寸，并把外层一起钉住。**正确判据**（NA-2 用两个反例否证了 NA-1c 写的
"每个嵌套 box 里至少有一个 stretchy 子控件"）：

> **参与拉伸的 box 自己要在父容器里有 stretchy 尺寸**（`flex_grow`），逐层往上都要成立。

| 结构（`view` = …，窗口 800×600） | 面板真实 frame | 对旧规则的检验 |
|---|---|---|
| `row(style: { flex_grow: 1 }) { stack(style: { flex_grow: 1 }) { area }; stack(style: { flex_grow: 1 }) { label } }` | 380×560 | 内层 box 里**没有** stretchy 子控件，照样撑开 → 旧规则**不必要** |
| `row(style: { flex_grow: 1 }) { stack { area(style: { flex_grow: 1 }) }; stack { area } }` | 第一个面板 **0×560**（宽被压成 0） | 内层 box **有** stretchy 子控件，仍被压死 → 旧规则**不充分** |
| `stack { label; row(gap: 4, style: { flex_grow: 1 }) { stack(style: { flex_grow: 3 }) { area }; stack(style: { flex_grow: 2 }) { label } }; label }` | 376×16 | row 自己够、链上的 stack 高度被 label 钉住 → 逐层都要成立 |
| `stack { label; area; area; label }`（滚动面板） | 第一个 760×528、第二个 **760×0**（NA-1e 复跑 4 次里 3 次；1 次是第一个 760×**17**、第二个 760×528） | 同一个 box 里两个非 stretchy 面板会互相抢；**谁被压不稳定、数字也抖，别依赖**（同一棵树换普通面板 2 次跑都是 760×528 / 760×0）——机制未定位 |

> ⚠️ 旧版第 4 行还有一句表下注（"`stack { label; area; area }` 在滚动面板上是第一个 **0×544**、
> 换成普通面板则相反（第一个 760×544 / 第二个 760×0）"）——**NA-1e 删**：NA-2c 复现不出来，
> NA-1e 复跑（探针 `STRUCT=two_areas_bare`，滚动/普通各 3 次）也不符，两次都是**逐个数字相同**：
> 视图里第一个面板 `frame=[0,544,760,0]`（= **760×0**、贴在 label 那一行上）、第二个
> `frame=[0,0,760,544]`（= 760×544）。旧注的 `0×544` 疑似把 AppKit `frame=[x,y,w,h]` 的
> `0,544` 读成了"宽×高"（轴向读错），"普通面板反过来"那半句从未出现在探针输出里。

**可操作写法**（都实测过）：

- 让**面板所在的每一层容器**在各自父容器里 stretchy（含最外层那层 stack）：
  `row(gap: 4, style: { flex_grow: 1 }) { stack(style: { flex_grow: 3 }) { area }; stack(style: { flex_grow: 2 }) { area } }`
  → 两列各 376×560 ✓；
- 或者**别嵌套**：把 area 直接放进需要拉伸的那一层（`row(gap: 4, style: { flex_grow: 1 }) { area; label }`
  当整棵 view 用时是 712.5×560 ✓；但同一棵树放进"上下夹 label 的 stack"里仍会塌成 16pt
  ——所以"别嵌套"不是充分条件，仍然是"每一层都要有 stretchy 尺寸"）；
- `flex_grow` 在 libui 里只是 **stretchy 布尔**，**不是权重**：同一 box 里两个 stretchy 子控件
  **等分**剩余空间（实测 `flex_grow: 3` 与 `flex_grow: 2` 各得 376pt 宽）。要按比例分配，
  得自己用多层嵌套或固定尺寸拼。

框架侧因此**不改布局语义**（默认 stretchy 会静默改变现有应用的布局），改为：
面板被压扁时给 dev_mode 提醒（§5.1 最后一条）+ 本节记录 + backlog。
数据来源：NA-1d 探针 `/tmp/na1d/layout_probe.rb`（`STRUCT=<名字> [SCROLL=0]`，逐个结构跑）；
NA-1e 用它复跑第 4 行与 `two_areas_bare`（见上表注）。

#### 5.7.3 `clip_rect` 改成精确可见区（SHEETS-2 D7）

- 旧口径（取 `Clip*`）的问题是它是一个**不稳定的脏区**（libui 的 `dp.ClipX` 就是
  `drawRect` 的 `r.origin`）：非滚动面板那一帧的脏区是**整窗**（NA-2 实测
  `[-20,-68,800,632]`，而面板只有 760×528）；滚动面板在局部重绘的帧里只是"新露出来的
  那条条带"（实测 `[0,900,743,100]`、`[0,1000,743,300]`）。拿它当可见区会漏画或画到
  滚动条下面。
  ⚠️ NA-1c 曾把理由写成"`Clip*` 会比视口**大**（含滚动条占位：760×544 vs 743×527）"——
  **NA-2 逐帧核对否证了这条**：`Clip*` 从不大于视口，`760×544` 其实是那台机器上
  **NSScrollView 自己的 frame**（窗口 800×600）。理由改成本段这两条，结论（精确可见区）
  不变。
- 新口径：取 `areaView` 的 `visibleRect`（= clip view 在内容坐标的范围，origin = 滚动偏移、
  size = 不含滚动条的视口），夹进声明的内容尺寸。取法：Fiddle 拿不到 32 字节的结构体返回值，
  所以走 KVC（把 struct 属性包成 `NSValue`）+ `getValue:size:`（参数全是指针）；
  读不到就退回 `Clip*`。键字符串创建时 retain 一份（`stringWithUTF8String:` 是 autorelease 对象）。
- 冒烟对拍：`clip_rect` 的尺寸 == AppKit `visibleRect`（夹进内容尺寸后），滚动后 origin == 滚动偏移。

#### 5.7.4 `on_draw` 里 `repaint` 能出下一帧（NA-2 P2.2）

- 现象：AppKit 在绘制中忽略 `setNeedsDisplay`，所以"在 `on_draw` 末尾再排一帧"的自排队动画
  静默冻在第一帧（NA-2 实测 `frames=1`）。
- 修法：适配层记"正在绘制"的面板，绘制期收到的 `area_queue_redraw` 先记账，绘制收尾时经
  `queue_main_once` 排到下一轮（同一面板一轮只排一次，不会递归重绘）；排队用的闭包**不常驻**
  （自排队动画每帧排一个，常驻会漏闭包）——同一个槽 NA-1d 也用在定时器上（§5.7.6-1）。
- 冒烟：`SmokeSelfDrivenPanel` 在 `on_draw` 里 `refs[:panel].repaint`，0.4 秒内帧数持续增长
  （修复前恒为 1）。

#### 5.7.5 记录：绘制不裁剪到面板矩形

`areaView` 没开 `clipsToBounds`，`Painter` 画到面板外的内容**会显示**（实测见 5.7.2 的证据 2）。
`clip_rect` 因此只是提示；要限制就自己 `clip(x, y, w, h) { … }`。

#### 5.7.6 NA-1d 修复轮（2026-09-15，来自独立验收 NA-2b）

1. **定时器每个 tick 漏一个常驻闭包**（N1，P2）：`Timer` 到点走的是 `Widgets#queue_main`，
   而 libui 适配层把闭包 `<<` 进 `@closures` 后**从不清理**（Fiddle 闭包不能被 GC 回收）——
   NA-2 实测 50ms 定时器 5 秒内 `closures/ticks` = 54/52（慢漏但无界），两个移植 demo 都在用
   `every`。修法：定时器改走 `queue_main_once`（执行完释放引用；NA-1c 已为绘制期延后重绘加了
   这个槽，见 5.7.4），语义等价（闭包本来就只需执行一次）。**事件订阅那类必须常驻的闭包
   仍走 `queue_main`**，`Base#queue_main_once` 缺省实现退化为 `queue_main`（桩后端不受影响）。
   锁：桩后端断言"tick 只排一次性闭包（`queue_log`）"；真控件 GUI 冒烟断言 ~12 个 tick 后
   `@closures` 新增 ≤ 2（探针自己那两次 `queue_main`）。
2. **`AreaHandle#focus` 的返回值不诚实**（P3→修）：`ObjcBridge#focus` 旧写法只要窗口是
   key window 就 `return true`，不校验 `makeFirstResponder:` 的 BOOL。改为**两层判据的
   合取**：① 用 `char` 返回类型的 `objc_msgSend` 读 `makeFirstResponder:` 的 BOOL（受理）；
   ② 窗口的 `firstResponder` 真的是目标视图或它的后代（`isDescendantOf:`，滚动面板的
   first responder 是 document view；先 `isKindOfClass:NSView` 再问——窗口自己也会成为
   first responder，而它不是 NSView，直接发 `isDescendantOf:` 就是不可捕获的 ObjC 异常）。
   ⚠️ 为什么必须加 ②：NA-1d 探针 5 实测（macOS 26）只要窗口是 key window，那个 BOOL 对
   **接受与不接受** first responder 的目标**都返回 YES**，所以只转达 BOOL 依然是"不诚实
   的答复"。边界与语义见 2.3 第三条 / §5.3。冒烟断言：成功（true + 焦点真在面板上，
  独立读 AppKit）、目标为空（false + 无副作用）、**游离视图（AppKit 原值 YES，框架仍
   返回 false）**——最后这条是"转达 BOOL 不够"的判别用例（消融验证见 §5.7.6 的验收记录）。
3. **"面板被压扁"的提醒扩成三条判据 + 提示文本改成可操作**（P3）：见 §5.1 最后一条
   （旧口径只看"是不是 0"，于是 753×16 的面板与视口塌成 736×16 的滚动面板都不提醒；
   旧提示让"已经有 `flex_grow` 仍被压"的应用去给面板加 `flex_grow`，是空转）。
   新提示指向**容器链**（判据见 §5.7.2）。
4. **`Clip*` 的理由改写**（P3）：见 §5.7.3 开头（结论不变、原因改成"脏区条带化/整窗"）。
5. **KVC 键字符串 retain 的因果**（P3）：`"visibleRect"`（11 字符）拿到的是 immortal 常量串，
   去掉 retain 行为一样；**长度 ≥ 12 的键才是真 `__NSCFString`**，池排干后不 retain 再读会
   `exit 133` 崩溃（NA-2 用 15 字符键复现）。注释改成这条边界，retain 作为通用防御保留。
6. **首帧 `clip_rect` 瞬态**（P3，写明不修）：滚动面板**第一次**绘制时 `visibleRect` 可能
   报成 NSScrollView 自己的尺寸（NA-1d 复跑：首帧 `[0,0,760,528]` vs 稳态 `[0,0,743,511]`；
   NA-2 4 次跑里 2 次命中）——libui 在同一次 Draw 里才设 document view 的 frame，而这次读
   在它之前。只影响"首帧就按 `clip_rect` 裁剪并缓存"的应用；稳态逐帧 0 误差。
   同一读数还喂给 §5.1 判据 ③ 的提示文本，所以**提醒里的视口数字也可能偏大**
   （NA-1e 在提示文本里标注了这条，并写进 §5.1 盲区 ⑤）。
7. **两条不修的脆弱面**（写明限制，写进 `ObjcBridge#rect_of` 的注释）：
   ① **ObjC 异常不可捕获**——KVC 键不存在、或对非滚动视图发 `documentView` 会抛
   `NSInvalidArgumentException`，`rescue StandardError` 抓不住，**整个进程终止**；框架当前
   路径不可达（只对 `record[:scroll]` 的面板读 `visibleRect`，句柄确实是 NSScrollView），
   靠这条不变量兜住；② **销毁后野读不崩、给陈旧值**（实测 `[0,0,543,343]`），靠"销毁后
   不读"的不变量兜住（`draw_area` 查 `@areas`、`flush_deferred_redraws` 查记账、
   `forget` 清 `cache`），不是靠这里报错。
8. **文档修正**（P3）：D2 的判据与表格（§5.7.2，含"树 ↔ 数字"的完整树与自己的复现数据）、
   `Clip*` 理由（§5.7.3）、`GOALS.md` 里"⌘ 策略两处同策略"（实为**单点**在渲染器，
   适配层只转达）、`docs/plan/backlog.md` 的 F1/F11、`README.md` 的"嵌套 box 的坑"。
   两处**不在本仓**的过期记录（`citrine-sheets/native/README.md:45,63` 当时仍写"`clip_rect`
   偏大 ~18px"）已上报；**NA-1e 只读复核（2026-09-15）确认 sheets 侧已改到位**，现在写的是
   "曾偏大、现已精确 + 首帧例外"（见 §5.7.7-6）。

#### 5.7.7 NA-1e 清理轮（2026-09-15，来自独立验收 NA-2c 的 5 条 P3）

NA-2c 结论 **pass**（记录 `/tmp/citrine-reviews/NA-2c.md`），留下 5 条"文档/提示不实"类的
P3，本轮逐条收口：

1. **判据 ② 对滚动面板误报**（行为）：滚动面板下 Painter 的宽高是**声明的内容尺寸**，于是
   健康的 `scroll: true, size: [2000, 20]`（真 GUI 实到 760×544、视口 743×527）会被打印
   "控件被挤成一条：2000.0×20.0"，还给出与形状无关的容器链建议。改法：判据 ② **跳过滚动
   面板**（`@widgets.area_scrollable?`），滚动面板只由判据 ③（真实视口）说话——宁可漏报也不
   误报（新盲区 ④ 写进 §5.1）。锁：桩测
   `test_short_declared_content_size_is_not_a_squeeze_on_scroll_panels`（同尺寸的健康滚动
   面板不报警）+
   `test_a_narrow_non_scroll_panel_still_warns_for_the_same_numbers`（同样数字换成非滚动
   面板仍要报——判别用例：去掉 `!scrolling &&` 这条断言就红）。
2. **判据 ③ 提示里的视口数字取自当帧**（可能是首帧瞬态）：**选"如实标注"而不是"取稳态值"**
   ——瞬态只在首帧出现，而"取稳态值"要么得延迟一帧再报（"只画一帧"的形状会漏报，桩测与真
   冒烟都是单帧断言），要么得靠"读数是否等于 NSScrollView 的 frame"猜瞬态（overlay 滚动条下
   这个判据会把正常视口也判成瞬态，风险更大）。所以：提示文本加一句"视口是当帧原始读数，
   滚动面板首帧可能报成 NSScrollView 的尺寸（偏大）"，并写进 §5.1 盲区 ⑤ 与 §5.7.6-6。
3. **§5.7.2 表 2 第 4 行与表下注**：第 4 行补上抖动数字（NA-1e 复跑 4 次里 1 次是
   `760×17 / 760×528`）；表下那句"`stack { label; area; area }` 滚动第一个 0×544 / 普通面板
   反过来"**删掉**——NA-2c 复现不出来，NA-1e 复跑（滚动/普通各 3 次）两次都是**逐个数字
   相同**：第一个面板 `frame=[0,544,760,0]`（760×0）、第二个 `[0,0,760,544]`（760×544）；
   旧注疑似把 `frame=[x,y,w,h]` 的 `0,544` 读成了"宽×高"。
4. **`focus` 返回 false 的含义数**：2.3 与 2.5 从"两种"改成**三种**（补上"key window 在、
   但 AppKit 没把焦点给目标"），并把 `uiControlDisable` 过的面板加进"不接受 first responder
   的目标"清单。
5. **"没有尺寸来源 → 0×0"只改了一半**：§2.1、§5.1 与 `docs/plan/backlog.md` 的 F1 标题三处
   旧措辞改成"取决于它在父容器（逐层）的 stretchy 情况，拿不到就 0×0"，并给出反例
   `stack { label; area }` → 760×544。
6. **只读复核（不改别的仓）**：`citrine-sheets/native/README.md` 的 `clip_rect` 口径——sheets
   侧的清理轮已改到位（第 45 行"现在报的是精确可见区…唯一的例外是首帧瞬态"、第 63 行表格
   "曾偏大、现已精确"），本仓记录同步更新（§5.7.6-8、backlog 的 D2 行），**不需要再派发**。
