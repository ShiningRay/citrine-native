# citrine-native

Citrine 组件的 CRuby 原生运行时：不经 Opal/JS，`ruby app.rb` 直接把信号式
组件跑成原生控件桌面应用（Shoes 精神）。

**定位**：citrine 主仓（平台无关核心 + 渲染器协议）的一个外部 Port。
同一份组件代码可跑在浏览器 DOM（Opal）/ Canvas / SSR / **原生控件（本 gem）**。

**状态**：N1/N2 完成（最小闭环 + 输入控件），**NA-1 完成：原生自绘面板（area）**
——绘制图元、鼠标/键盘事件、重绘调度、面板句柄、定时器，Counter/Todo 两个示例
可起真窗口。设计、UI 库选型（决策 N-1：v0 后端 = libui）与 Roadmap 见 [GOALS.md](GOALS.md)，
自绘面板的冻结接口见 [docs/design/native-area.md](docs/design/native-area.md)。

## 安装与运行

```bash
bundle install                          # citrine 依赖开发期指向 ../citrine（path）
bundle exec ruby examples/counter.rb    # 起真窗口；点按钮，计数精确 +1
bundle exec ruby examples/todo.rb       # 输入 + 添加 + 勾选 + 删除
```

在自己的应用里：

```ruby
require "citrine-native"

class Counter < Citrine::Component
  state :count, default: 0        # 三宏收关键字参数

  def view
    stack(gap: 8) do
      label { "计数：#{count}" }
      button(on_click: -> { self.count += 1 }) { "点我 +1" }   # 文本走 block
    end
  end
end

Citrine::Native.run(Counter, title: "计数器", width: 400, height: 300)
```

`Citrine::Native.run(组件类或实例, title:, width:, height:, dev_mode:, activate:)`
建窗口、挂载组件、进主循环（阻塞到窗口关闭），关窗后按序拆解（卸载组件 → 销毁窗口 →
反初始化）。要自己管事件循环就用 `Citrine::Native.start`（只建窗口挂组件）。

`activate:`（默认 `true`）在显示窗口后**激活应用**——macOS 下不激活时窗口不是 key window，
键盘事件一个也收不到（见设计 2.3 的实测）；不想抢用户焦点时传 `activate: false`，
代价是要先点一下面板才能用键盘。

## 自绘面板（area）与定时器（NA-1）

libui 的 box 没有背景/边框、label 没有颜色、只有 button/entry/checkbox 可点——
数据密集区（表格线、涨跌红绿、图表）和"任意位置可点 + 键盘操作"要靠**自绘面板**：

```ruby
class Quote < Citrine::Component
  state :rows, default: [["贵州茅台", 1288.50], ["宁德时代", 198.20]]

  def view
    stack(gap: 6) do
      element(:area, ref: :panel,          # refs[:panel] → AreaHandle
                     size: [320, 600],     # 仅 scroll: true 时生效（滚动内容尺寸）
                     scroll: true,
                     watch: -> { rows.size },            # 响应式：依赖变化即重绘
                     on_draw: ->(p) { draw(p) },
                     on_click: ->(ev) { pick(ev.x, ev.y) },
                     on_key: { "ArrowDown" => :move_down, "Enter" => :commit, else: :type })
    end
  end

  def draw(p)
    p.rect(0, 0, p.width, p.height, fill: "#14203a", stroke: "#1e2c48")
    rows.each_with_index do |(name, price), i|
      y = 8 + i * 22
      p.text(name, x: 8, y: y, color: "#e6ecf8", size: 13)
      p.text(price.to_s, x: 200, y: y, color: "#4ecb71", size: 13, weight: :bold,
                         align: :right, width: 100)   # 对齐要同时给 width
    end
    p.line(0, 0, p.width, p.height, color: "#1e2c48", width: 1)
    p.clip(0, 0, p.width, 40) { p.rect(0, 0, p.width, 40, fill: "#0b1424") }
  end
end

handle = refs[:panel]              # Citrine::Native::AreaHandle（不是 libui 裸指针）
handle.repaint                     # 手动标脏重画
handle.scroll_to(0, 200, 320, 120) # 仅滚动面板：把内容坐标里这块滚进视口
handle.focus                       # 把键盘焦点给面板（macOS；做不到时返回 false）

@ticker = Citrine::Native.every(200) { self.tick }   # 周期定时器（主线程执行）
@once   = Citrine::Native.after(500)  { self.refresh }
on_unmount { @ticker.stop; @once.stop }              # #stop 幂等，卸载时记得停
```

图元：`rect`（可圆角）/`line`/`polyline`/`polygon`（面积图）/`text`（颜色+字号+字重+字体）/
`measure_text`/`clip`；另有两个只读属性 `width`/`height`（面板内容尺寸）与
`clip_rect`（当前可见区，内容坐标——滚动面板下随滚动位置变化、**不含滚动条**，
可用它只画看得见的部分）。
颜色接受 `"#rgb"` / `"#rrggbb"` / `"#rrggbbaa"` / `[r,g,b(,a)]`（0..1 浮点）/ `:none`；
字号字重从字体描述符来，颜色作为属性烘进文本布局。**每帧新建 Painter，文本布局按
(文本, 字号, 字重, 字体, 颜色, 宽度, 对齐) 在面板级缓存里复用**（否则每帧每格新建会掉帧）。
`text` 的 `(x, y)` 是外接矩形**左上角**（不是基线）；`align:` 只在同时给 `width:` 时生效。
在 `on_draw` 里调 `handle.repaint` 是安全的（适配层把请求排到下一帧，自排队动画可跑）。

`Widgets::Memory` 桩后端把 `on_draw` 交给 `Painter::Recording`（记录图元调用序列），
测试可以直接断言"画了什么"：

```ruby
rec = backend.fire_draw(area)                 # 桩后端跑一次绘制
rec.types                                     # => [:rect, :text, :text]
rec.calls_of(:text).first[:color]             # => [0.9, 0.3, 0.3, 1.0]
backend.fire_click(area, 12, 34)              # 合成点击/按键/移动
backend.fire_key(area, "ArrowDown", modifiers: { shift: true })
```

## 支持的元素与样式（v0）

| DSL | 原生控件 | 说明 |
|---|---|---|
| `stack { }` / `row { }` / `box(direction:)` | 竖排 / 横排 box | 方向必须静态（控件创建后不能换方向） |
| `label { "…" }` | `uiNewLabel` | |
| `button(on_click:) { "…" }` | `uiNewButton` | 文本走 block |
| `text_input(value:, type: "password")` | `uiNewEntry` / `uiNewPasswordEntry` | `value:` 传 Signal 即受控双向绑定 |
| `check_box(checked:, on_change:)` | `uiNewCheckbox` | **没有内容位**：标签用相邻 `label { }` |
| `element(:area, on_draw:, …)` | `uiNewArea` / `uiNewScrollingArea` | 自绘面板：见上一节；`ref:` 拿到 `AreaHandle` |

样式只映射两个键：`gap`（→ 容器 padding 的有/无）与 `flex_grow`（→ 该子控件在父 box
里 stretchy，即吃掉剩余空间）。`disabled` 属性 → 控件禁用态。
`flex_grow` 在 libui 里只是**"stretchy"开关、不是权重**：同一 box 里两个 stretchy
子控件**等分**剩余空间。
**其余样式键与 HTML 专属属性在 dev_mode 下提醒，绝不静默丢弃**；未支持的元素
（`textarea`/`select`/`table`/`img`…）直接抛 `UnsupportedElementError` 并给出替代建议。

## 使用约束

- **单线程**：控件回调、Signal 写入、Effect 重跑全在主线程，`Citrine.batch` 可直接用。
  长任务（网络/文件）放后台线程，再用适配层的 `queue_main` 把更新排回主线程
  （`uiQueueMain`）。
- **回调里的异常不会中断应用**：打到 stderr 后继续跑主循环（异常穿过
  Fiddle/Objective-C 栈可能把整个 GUI 带走）；组件内的错误请用 `error_fallback`。
- **键盘在自绘面板上可用，原生输入控件上不行**：`on_key`/`window_key` 都由聚焦中的
  `element(:area)` 转发（`App` 的 `activate:` 负责让窗口成为 key window）。
  libui 的 entry 仍然不暴露按键事件，所以**"输入框里按回车"还是不可用**——
  要么放一个按钮，要么由面板侧处理回车。原生 entry 上也会因此收不到 `window_key`。
- **没有滚轮事件**：libui 的 `uiArea` 不投递滚轮（设计 2.2 的实测）；要滚动就用
  `scroll: true` 的原生滚动条 + `AreaHandle#scroll_to`。
- **面板尺寸**：`size:` 只在 `scroll: true`（滚动内容尺寸，**不是视口尺寸**）时生效；
  非滚动面板的尺寸由外层容器布局决定（libui 的 `uiAreaSetSize` 只对滚动面板可用，
  dev_mode 下会提醒）。**面板拿不到空间是静默的**（0×0、还会挤扁兄弟）——撑不撑得开
  取决于它在**容器链逐层**有没有 stretchy 尺寸：**单个**面板在 stack 里不给 `flex_grow`
  也能拿到剩余空间，"没有尺寸来源就 0×0"是过度概括（见下一条与设计 §5.7.2）。渲染器在
  面板被压扁时给 dev_mode 提醒（0 尺寸、**非滚动**面板被挤成一条、以及滚动面板**真实
  可见视口**被挤扁——最后这条靠读 clip view；滚动面板的**内容**尺寸矮不算"被挤扁"）。
- **嵌套 box 的坑**（实测，两个 demo 都踩过）：libui 的 box 布局里，一个 box 能不能撑开
  取决于**它自己在父容器里有没有 stretchy 尺寸**（`flex_grow`），逐层往上都要成立；
  "每个嵌套 box 里都塞一个 stretchy 子控件"**既不必要也不充分**（反例：内层 box 自己
  `flex_grow` 就够了；反过来内层 box 里有 stretchy 子控件、自己却没有，照样被压成 0 宽）。
  例：`stack { label; row(style: { flex_grow: 1 }) { stack { area }; stack { label } }; label }`
  整行只有 376×16 高——row 自己 stretchy 了，但它所在的 stack 高度被两个 label 钉死。
  细节、反例与探针数据见 `docs/design/native-area.md` §5.7.2。与滚动无关，纯 label 同样复现。
- **⌘ 组合键不会被面板吞掉**：面板声明了 `on_key` 时，⌘H 这类菜单快捷键照常生效
  （回调仍然收到按键，所以应用自己处理的 ⌘Z/⌘B 不受影响）。
- **绘制不裁剪到面板矩形**：画到面板外的内容会显示（AppKit `NSView` 默认
  `clipsToBounds = NO`），`clip_rect` 是提示不是限制——想限制请自己 `clip`。
- **`ref:` 拿到的是控件句柄**（`Fiddle::Pointer`），`element(:area)` 的 `ref:` 拿到的是
  `Citrine::Native::AreaHandle`（不是 DOM 元素）。`ref:` 挂在**产出该元素的组件**上：
  子组件里的 `refs[:grid]` 根组件看不到，要由子组件自己暴露读取器（见设计 2.5）。
- 组件代码要可移植：只用平台无关 API，别 `require "citrine/browser"` / `citrine/canvas`，
  别碰 `Native`/反引号 JS。

## 开发

```bash
bundle exec rake                        # CRuby 单测（桩后端，111 项，不需要窗口）
bundle exec rake gui_smoke              # 真窗口 + 真主循环（窗口会闪现一下）
CITRINE_NATIVE_GUI=1 bundle exec rake   # 连 GUI 模式的真控件冒烟一起跑
```

测试分两层（对齐 GOALS 风险 3）：

- **渲染语义**：`Widgets::Memory` 桩后端（控件树只有结构/文本/回调）——块级更新、
  keyed 复用与重排、组件根落位、透明容器、错误边界、受控输入、自绘面板（事件/重绘/
  句柄/提醒/定时器）、卸载不留活口
- **真控件**：`test/support/libui_scenario.rb` 在**子进程**里跑（libui 撞到内部 bug 会
  abort 进程）：默认不显示窗口，直接触发 libui 真正持有的回调闭包（含合成
  `uiAreaMouseEvent`/`uiAreaKeyEvent`），验证点击精确 +1、容器重排的物理顺序、
  真文本度量/换行/布局缓存释放、面板五个回调槽、⌘ 键的真闭包返回值（不吞菜单快捷键）、
  拆解后 `uiUninit` 无泄漏；
  `--gui` 模式追加真窗口路径：激活后窗口是 key window、`AreaHandle#focus`、
  真绘制（矩形/折线/面积图/中文富文本/裁剪块）、`watch:` 与 `repaint` 驱动重画、
  滚动后 `clip_rect` 跟着走、`clip_rect` 与 AppKit `visibleRect` 对拍、
  滚动面板撑满容器、自排队动画真的持续出帧。

⚠️ GUI 路径里"窗口是 key window / `#focus`"两条依赖 macOS 的**协作式激活**：同机有别的
应用抢焦点（含其它 agent 的 GUI 进程）时会失败。判别是不是环境：起一个**不含 area** 的
最小窗口看 `window_is_key?`——它也为假就是环境问题。

## 仓库结构

```
lib/citrine-native.rb                 # gem 入口
lib/citrine/native.rb                 # Citrine::Native 命名空间 + run/start/every/after + 异常
lib/citrine/native/renderer.rb        # NativeRenderer：节点树 → 控件树（平台钩子）
lib/citrine/native/app.rb             # 窗口 + 主循环 + 激活 + 有序拆解
lib/citrine/native/painter.rb         # 自绘面板的绘制层（Painter / 文本布局缓存 / Recording）
lib/citrine/native/pointer_event.rb   # 面板指针事件视图（平台无关）
lib/citrine/native/area_handle.rb     # 面板句柄（repaint / scroll_to / focus）
lib/citrine/native/timer.rb           # 定时器（后台线程 + queue_main）
lib/citrine/native/widgets.rb         # 控件适配层协议（换 GTK 后端只换这一层）
lib/citrine/native/widgets/libui.rb   # libui 后端（真控件 + macOS 直通桥）
lib/citrine/native/widgets/memory.rb  # 内存桩后端（单测用）
examples/counter.rb                   # N1 验收示例
examples/todo.rb                      # N2 验收示例
test/                                 # CRuby 单测 + 真控件冒烟脚本
docs/design/native-area.md            # 自绘面板的冻结接口 + 实现说明
GOALS.md                              # 设计与计划主文档
```

## 约束（贡献者向）

- 只依赖 citrine 的平台无关核心，**禁止引入 Opal/JS**
- 渲染器不直接调 libui API——一律经 `Widgets` 适配层（Painter 例外：它按设计只依赖
  libui 的 draw/attributed-string 接口，放在 `native/painter.rb`）
- 打包壳本期不做（非目标，见 GOALS 第二节）
