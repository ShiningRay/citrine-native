# 元素/事件支持矩阵（原生后端）

> N4 的交付物之一："对照主仓元素/事件词表出支持矩阵，未支持项全部有 dev_mode 提醒"。
> **机器可校验的部分在 `test/element_event_matrix_test.rb`**：元素提示表的完备性、
> 未支持事件必须在本文件里有记录、area 的事件面冻结、未支持事件确有提醒。改代码就同步改这里。

## 一、元素面（对照 `Citrine::Component::ELEMENT_TAGS`）

| 处置 | 元素 | 行为 |
|---|---|---|
| **支持** | `box`（`stack` / `row`）、`label`、`button`、`text_input`、`check_box`、`element(:area)` | 映射到 libui 控件（GOALS 4.3 / `native-area.md`） |
| **报错 + 替代建议**（`UnsupportedElementError`） | `textarea`、`select`、`option`、`table`、`thead`、`tbody`、`tr`、`td`、`th`、`img`、`a`、`ul`、`ol`、`li`、`form`、`span`、`video`、`audio` | 元素级缺失**始终报错**（不是样式降级，是页面结构缺一块），报错文案带上替代路径（`Renderer::ELEMENT_HINTS`） |

报错与提示的完整性由 `test_every_unsupported_core_element_has_a_replacement_hint` 锁住：
核心词表里每个不在 `ELEMENTS` 的标签都必须有 hint，否则"用户拿到一个没有出路的报错"。

**为什么这些不实现**（对照 libui 的能力）：

- `textarea` → `uiNewMultilineEntry`（Roadmap N4 候选，未接）
- `select` / `option` → `uiNewCombobox`（条目创建时定死，与响应式选项列表不契合）
- `table` / `thead` / `tbody` / `tr` / `td` / `th` → `uiNewTable` 能力有限；**实际做法是自绘**
  （`element(:area)` + Painter 画网格，参见 citrine-market-terminal 的自选/持仓表）
- `img` / `video` / `audio` → 原生控件没有这些元素；图片可用 area 自绘
- `ul` / `ol` / `li` / `form` / `span` / `a` → 语义标签，用 `stack` + `label` + `button` 组合表达

## 二、事件面（对照核心 `EVENT_DEFS` + 组件级事件）

图例：✅ 已接（真投递） · ⚠️ **未接（dev_mode 提醒，绝不静默）** · — 无对应概念

| 事件 | 原生状态 | 说明 |
|---|---|---|
| `on_click` | ✅ `button` / `area` | area 的 click 由 down+up 合成（与 DOM 同序）；button 走 `uiButtonOnClicked` |
| `on_change` | ✅ `text_input` / `check_box` | 受控语义：先写回 Signal 再派发（与 DOM 的 check_box 同口径） |
| `on_enter` | ⚠️ | **libui 的 entry 不暴露按键事件** → 回车提交在 v0 不可用；两个 demo 改用按钮提交（`market` 的下单、`sheets` 的公式栏）。候选实现：自绘输入框或用 area 收键 |
| `on_key` | ✅ `area`（含 Hash 键表） | 键名归一为 DOM 风格；`window_key` 经聚焦面板转发——**只有焦点在某个面板上时可用**（`native-area.md` 2.3） |
| `on_mouse_down` / `on_mouse_up` / `on_mouse_move` | ✅ `area` | `on_mouse_move` 是原生扩展（核心 DOM 词表里对应的是 `on_pointer_move`，原生没有 pointer 概念） |
| `on_key_up` | ⚠️ | area 的 KeyEvent 只在按下时投递（v0 没有 `on_key_up`，冒烟里锁了"抬起不投递"） |
| `on_focus` / `on_blur` | ⚠️ | 原生控件的焦点由系统管理，libui 不暴露；需要时用 area + 自己的焦点模型（`AreaHandle#focus`） |
| `on_dblclick` / `on_contextmenu` | ⚠️ | libui 的 area 只给 Down/Up/Count（`Count` 可判双击，但 v0 未映射）；右键菜单属桌面能力（远期候选） |
| `on_mouse_enter` / `on_mouse_leave` | ⚠️ | 适配层有 `MouseCrossed`（`on_area_crossed` 内部订阅），未作为公开事件暴露 |
| `on_wheel` | ⚠️ | **libui-ng 的 area 不投递滚轮**（`uiAreaMouseEvent` 无滚轮字段；GTK 版把按钮 4-7 显式忽略）→ 滚动请用 `scroll: true` + `AreaHandle#scroll_to`（`native-area.md` §5.4） |
| `on_scroll` / `on_submit` / `on_paste` | ⚠️ | 无对应（`on_submit` 属表单语义，原生没有 form） |
| `on_touch_start` / `on_touch_move` / `on_touch_end` | ⚠️ | 桌面端无触摸事件（libui 不暴露） |
| `on_pointer_down` / `on_pointer_move` / `on_pointer_up` | ⚠️ | 原生没有 pointer 抽象；等价物是 area 的 `on_mouse_*` |
| `on_mount` / `on_unmount`（生命周期宏） | ✅ | 核心实现，原生侧随挂载/卸载触发（定时器示例 `examples/todo.rb` 用它停表） |
| `window_key`（类宏） | ✅（有条件） | 由**聚焦中的 area** 转发；没有焦点在面板上时收不到（`native-area.md` 2.3）。scope: `:focused` 同口径 |

**⚠️ 的统一行为**：这些 prop 在受支持元素上写着会被 `warn_unsupported_events` 按 `dev_mode`
**提醒**（去重、带元素名），不会静默丢弃；元素级的不支持（第一节那些标签）则**始终报错**。

## 三、与核心词表的两处出入（如实记录）

1. **`on_mouse_move` 不在核心 DOM 词表里**（DOM 侧是 `on_pointer_move`）：原生 area 的接口在设计
   冻结时就叫 `on_mouse_*`（`native-area.md` 2.1），两条线暂时并行；若将来要统一，改的是
   **native 侧**（DOM 词表是既有契约）。
2. **`on_wheel` 在核心有、原生永远不会有**（libui 的能力边界，不是实现进度）。

## 四、路线图

| 项 | 状态 | 去向 |
|---|---|---|
| `textarea` → `uiNewMultilineEntry` | 未接 | Roadmap N4 |
| `select` / `option` → `uiNewCombobox` | 未接 | Roadmap N4（受响应式选项列表限制） |
| `table` 家族 | 不打算接 | 自绘替代（两个 demo 已这么做） |
| `on_enter`（entry 回车） | 未接 | 需要自绘输入框或焦点模型，N4 评估 |
| 双击 / 右键菜单 | 未接 | 桌面能力（远期候选） |
| `on_focus` / `on_blur` | 未接 | 依赖 libui 暴露焦点事件（上游能力） |
