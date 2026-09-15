# 样式能力矩阵（原生后端）

> 冻结状态：L1 + L2 已实现（2026-09-15）；本文档是 `Citrine::Native::StyleMatrix` 的散文版，
> 两者必须同步改动——代码里 `lib/citrine/native/style_matrix.rb` 的 `TABLE` 是唯一事实来源，
> dev_mode 的提醒文案、测试与本文档都从它读。

## 一、为什么有这份文档

citrine 的样式是"一份组件代码、多个渲染目标"：DOM（CSS 全能力）、Canvas（自绘）、SSR
（字符串）、**原生控件（本 gem：libui，没有 CSS）**。前三个目标都能表达完整样式，原生
后端不行——libui 的控件集**没有**颜色、字体、边框、背景、阴影、动画这些概念。

没有单一出处时，"这条样式到底生效了没有"只能靠人肉记忆：两个 demo 的移植期反复踩
（`css_class` 静默无效、`flex_grow` 链断掉、Windows/macOS 行为不一致）。所以：

- **每个样式键都有登记**（`StyleMatrix::TABLE`，72 个键）与一个状态；
- **dev_mode 下逐个提醒**（绝不静默丢弃，GOALS 4.5 的原则）；
- **提醒文案按状态分档**，说清"为什么 / 怎么办 / 去哪看"。

## 二、三档状态

| 状态 | 含义 | 应用该做什么 |
|---|---|---|
| `:mapped` | 自动落到 libui 的既有语义（容器内边距、拉伸） | 照写即可 |
| `:painted` | 原生控件无法表达，**只能自绘** | 视觉底板（背景/描边/圆角）直接写在 `element(:area)` 上；文字样式在 `on_draw` 里用 `painter.text(…, size:/weight:/color:)` |
| `:ignored` | 原生控件没有对应概念 | 要么改设计，要么自绘重表达（例如省略号、等宽数字排版） |

渲染器对 `:painted` / `:ignored` 的键打一条去重提醒；`:mapped` 的键静音（它真的落地了）。

## 三、`:mapped`（10 个键）

| 键 | 落到哪里 | 限制 |
|---|---|---|
| `display` | box 的方向（`stack` / `row` 已表达） | 只有 flex；`grid` 等值提醒后忽略 |
| `flex_direction` | `uiNewVerticalBox` / `uiNewHorizontalBox`（由 stack/row 合成） | 换方向要换控件，运行期改无效 |
| `gap` | `uiBoxSetPadded` | **只有 0 / 非 0 两档**：像素级间距给不了 |
| `padding` / `padding_top` … `padding_left` | 同上（容器内边距） | 同上；单边不细分 |
| `flex_grow` | 追加子控件时的 stretchy | libui 是**布尔不是权重**：多个 stretchy 子控件等分剩余空间 |
| `flex` | 同 `flex_grow`（CSS 简写，首段数值 > 0 才算） | `flex-basis` / `flex-shrink` 无对应 |

## 四、`:painted`（自绘）

### 4.1 area 自动消费的视觉底板（L2，5 个键）

写在 `element(:area, style: { … })` 上，框架在 `on_draw` **之前**画一次，应用只管内容
（两个 demo 里手写的 `painter.rect(0, 0, w, h, fill:, stroke:)` 由此收进框架）：

```ruby
element(:area, scroll: true, size: [400, 300],
               style: { background: "#101827", border: "1px solid #1e2b45", border_radius: 8 },
               on_draw: ->(panel) { panel.text("内容", x: 12, y: 12, color: "#e7edf7") })
```

| 键 | 落到哪里 | 限制 |
|---|---|---|
| `background` | 底板填充（`uiDrawPath` 填充） | 放 area 上；放 box / label 上不生效（原生控件无法着色，提醒） |
| `border` | 描边，接受 `"1px solid #rrggbb"` 或纯颜色串 | **只画实线**：`dashed` / `dotted` 按实线画并提醒 |
| `border_color` / `border_width` | 描边颜色 / 宽度（`border` 简写的展开形式） | 分边（`border_top`…）无对应 |
| `border_radius` | 圆角（`uiDrawPath` 的 arc） | 超过短边一半会被夹取并提醒；四角不同半径无对应 |

样式每帧现读（`resolve_style`），所以 `style: -> { … }` 的响应式写法下一帧就生效。

### 4.2 只能在 `on_draw` 里表达的文字样式（8 个键）

| 键 | 落到哪里 |
|---|---|
| `color` / `font_size` / `font_weight` / `font_family` / `letter_spacing` | `painter.text(…, color: / size: / weight: / family:)` |
| `text_align` | `painter.text(…, align: :right, width: N)`——**必须同时给 `width:`**，否则按左对齐并提醒 |
| `line_height` | 自己按行距排（多次 `painter.text`） |
| `font_variant_numeric` | 等宽数字要自己保证（自绘没有 font-feature） |

原生 `label` / `button` 的字体与颜色**没有公开 API**——这是 libui 的能力边界，不是实现遗漏。

## 五、`:ignored`（无对应概念）

按大类列（完整键表见代码）：

| 类别 | 键 | 为什么 |
|---|---|---|
| 尺寸 | `width` `height` `min_*` `max_*` | libui 是拉伸式布局，没有尺寸来源；area 用 `size:` prop（**仅滚动面板**） |
| 盒模型 | `margin*` | 靠容器 `gap` 近似 |
| 对齐 | `align_items` `justify_content` `align_self` `order` | libui 的 box 没有对齐 / 分布能力 |
| 定位 | `position` `inset` `top/left/right/bottom` `z_index` | 原生控件没有定位与层叠（box 顺序即层序） |
| 效果 | `box_shadow` `opacity` `outline*` `transform` `filter` | 原生控件无法绘制 |
| 动画 | `transition` `animation` | 原生控件自己管绘制时机 |
| 溢出 | `overflow*` `white_space` `text_overflow` `word_break` | 要自绘（Painter 里手工截断——两个 demo 都已这么做） |
| 指针 | `cursor` `user_select` `pointer_events` | 原生控件自己管 |
| 边框细节 | `border_style` `border_top`… | 只支持整体描边 |
| 可见性 | `visibility` `float` `clear` | 隐藏元素请条件渲染（透明容器语义） |

## 六、两个 demo 的实际 CSS 落在哪（普查，2026-09-15）

浏览器侧样式有两条腿：组件里的 `css_class:`（两个 demo 共 **224 处**）与 HTML `<style>`
（sheets 90 条规则 / 约 70 个属性，market 141 条 / 约 85 个属性，16 个设计令牌）。
按属性归类后的落点（占比为**属性个数**的粗算，不是规则数）：

| 类别 | 占 | 落点 |
|---|---|---|
| 布局类（`display` `flex*` `gap` `align-*` `justify-*`） | ~15% | `:mapped` 的一部分（`display`/`flex`/`gap`）；`align-*` / `justify-*` 落 `:ignored` |
| 视觉底板（`background` `border*` `box-shadow` `border-radius`） | ~20% | 前三个落 area 的视觉底板（L2）；`box-shadow` 落 `:ignored` |
| 排版（`font-*` `line-height` `letter-spacing` `text-align` `text-overflow` …） | ~25% | 自绘（`Painter`）；`text-overflow` / `font-variant-numeric` 要手工重表达 |
| 尺寸与溢出（`width/height/min-*` `overflow*` `padding` `margin`） | ~20% | `padding` 映射；其余 `:ignored` |
| 交互与动画（`:hover` `transition` `cursor` `-webkit-*`） | ~20% | 全部 `:ignored`（原生控件有自己的系统态） |

**结论**：直接映射能覆盖的不到一成；把视觉底板与文字交给自绘后能覆盖到**六成左右**；
剩下的四成是前端的交互/排版细节，原生侧要么没有概念、要么得重写。**"CSS 正确渲染"不是
本后端的目标**——它换来的是原生控件观感（Shoes 的 Cairo 路线相反：一致性换观感）。

## 七、结构性天花板（决定了上限）

libui **没有**"既能容纳原生子控件、又能自绘背景/边框"的容器。因此：

- 想让一块区域有背景 / 圆角 / 自定义字体 → 它必须是 `element(:area)`，**里面不能嵌原生控件**；
- 想让按钮 / 输入框上色 → 只能走平台直通桥（macOS `setTextColor:`/`setFont:`、Windows
  `WM_SETFONT`/`WM_CTLCOLORSTATIC`），**当前未实现**（见 backlog E4）；
- 数据密集区（表格 / 图表）本就是自绘的——两个 demo 的深色面板都是这个模式。

## 八、给新应用的建议

1. **结构性样式留给 DSL**：`stack` / `row` / `gap` / `flex_grow`（别写 `width` / `align-items`）。
2. **视觉样式只写在 area 上**（背景 / 描边 / 圆角），文字用 `Painter`——把设计令牌收成一个
   `Theme` 模块（两个 demo 的做法：与 CSS 变量同名同值）。
3. **开 dev_mode 跑一遍**（`Citrine::Native.run` 默认开）：每条不落地的样式都会说清原因与出路。
4. 需要"原生控件也上色"时，先看第七节——那是平台直通桥的工作量，不是写个样式键的事。

## 九、`css_class`（类样式）：现状与两条路径

**现状：整块丢弃。** `css_class` 是"给 CSS 用的名字"（渲染器注释原话），原生后端只打一条
去重提醒（"没有对应概念（没有 CSS），已忽略"），一个声明都不生效。体量并不小——两个 demo
的浏览器侧视图共 **167 个类名**（sheets 60 / market 107），对应 HTML 里的 90 / 141 条 CSS
规则与 16 个设计令牌。

**但今天不影响两个 demo**：类名只出现在**浏览器侧的视图代码**里
（`sheets/native/**` 零处、`market/native/**` 唯一一处是解释"原生控件没有样式位"的注释）。
原生侧风格是另写视图 + `Theme` 令牌 + area 自绘实现的——这本身就是"类样式不可用"的绕行方案。

**所以真正的问题不是"缺陷"，而是产品选择：要不要同一份视图代码跑两边？**
只有单视图双渲染时，`css_class` 才会成为第一道断点。两条路径：

| 路径 | 做法 | 成本 / 边界 |
|---|---|---|
| **B 类名别名表**（起步选项） | `Citrine::Native.map_css_class(".panel" => { background: …, border: … }, ".is-on" => …)`：框架**不解析 CSS**，只查表，结果并进本文档的同一套管道（`:mapped` → 控件，`:painted` → area） | 低。能让单视图的"可映射键 + area 视觉"两块落地，并把提醒精确到"`.panel` 的 background 落在 box 上无法着色"（backlog F28） |
| **A 内置 CSS 子集解析器** | 读 `<style>` / `.css`，支持 `:root` 变量、类/标签选择器、状态类与基本级联，产出喂进 StyleMatrix | 高，且收益受第七节的天花板限制：解析出来的伪类与媒体查询（两个 demo 共 28 处 `:hover` / `:focus` / `@media` / `@keyframes`）、`transition`、`box-shadow` 本来就无处落地。真正价值是"省掉手工登记 + 提醒更准"——等 B 的表维护不动了再说 |

**状态类（`.is-on` / `.is-edit` / `.is-buy` / `.is-sell` / `.badge-hold`）是独立课题**：
它们表达的不是样式而是"**状态 → 表现**"的映射；原生控件没有样式位，今天只能用文案
（`state_button` 的 `✓` 标记）表达。即便做了 A 也要单独定一套约定（backlog F29）。

细分的类名落点（两个 demo 的普查）：可映射（`.shell` / `.shell-main` / `.col-*` 的
gap 与 flex）· 只能自绘（`.num` / `.dim` / `.small` / 价格列 / 坐标轴标签）· 只在 area 上
有效（`.panel` / `.tk-field` / `.hd-*` 的背景与描边）· 状态类（上一段）。
