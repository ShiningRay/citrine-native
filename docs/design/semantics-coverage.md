# 语义覆盖：主仓断言 ↔ 原生后端（N3）

> Roadmap N3 的交付物之一："把主仓 `test/` 的断言清单逐条对齐"。本文件是那张清单：
> 每条主仓断言的**承担方**与 native 侧的对应断言（或为什么不需要对应对）。
> 更新时机：主仓新增渲染语义断言时；native 侧改了平台钩子时。

## 一、分工原则（先看这条，它决定了哪些要"对齐"）

`Citrine::Native::Renderer` **继承** `Citrine::Renderer`：节点树、Effect 装配、块级重建、
keyed 复用、透明容器（fragment / portal / suspense）、错误边界**全部复用核心实现**，
native 只实现平台钩子（`setup_root` / `create_dom` / `attach` / `attach_before` / `detach` /
`apply_props` / `bind_events` / `set_text` / `setup_widget` / `reactive?`）。

因此分三类：

| 类别 | 承担方 | 例子 |
|---|---|---|
| **A. 渲染器无关的语义** | **主仓测试**（native 不重复） | keyed 复用的实例保持、unkeyed 按位置复用、props 变化不重建 keyed 子组件、生命周期钩子的符号/Proc/继承、portal 的宿主语义、suspense 的占位切换 |
| **B. 平台钩子契约** | **native 测试**（必须自己断言） | 控件创建/销毁/搬运、文本清空、事件归一、样式映射、句柄语义、拆解顺序 |
| **C. DOM/SSR 专属** | **不适用** | `css_class` 串接、属性透传到 HTML、SSR 转义、内联 CSS 文本 |

> 为什么 B 不能靠 A 兜住：核心保证"节点树与 Effect 行为正确"，但**控件是否真的被创建/
> 搬运/销毁**只有 native 的桩后端（`Widgets::Memory`）与真控件冒烟能证明——主仓的 DOM
> 桩断言的是 DOM 树，不是 libui 控件。

## 二、B 类：平台钩子的断言映射

| 平台钩子 | native 断言 | 文件 |
|---|---|---|
| `create_dom` 元素词表 | `test_element_vocabulary_maps_to_widgets` | renderer_test |
| 未支持元素报错（不静默降级） | `test_unsupported_element_raises_with_hint`、`test_unknown_element_still_fails_fast` | renderer_test / area_test |
| `attach` / `attach_before` 搬运 | `test_keyed_reorder_reuses_widgets_and_keeps_new_order`、`test_component_root_rerun_returns_to_original_position` | renderer_test |
| `detach` / 销毁顺序 | `test_unmount_destroys_every_widget_except_window_and_root_container`、`test_removed_keyed_component_unmounts_and_keeps_siblings` | renderer_test |
| `set_text`（清空旧文本） | `test_text_is_cleared_when_block_stops_producing_text`、`test_non_string_content_renders_via_to_s` | renderer_test |
| `apply_props`（样式/禁用态） | `test_reactive_gap_updates_padding_without_rebuilding_children`、`test_disabled_prop_maps_to_widget_enabled_state`、`test_gap_maps_to_container_padding` | renderer_test / style_matrix_test |
| `bind_events` 现取处理器 | `test_click_handler_is_read_from_props_at_dispatch_time`、`test_controlled_widgets_do_not_rebind_native_callbacks_when_reused` | renderer_test |
| `setup_widget` 受控初值 | `test_text_input_follows_signal_writes`、`test_check_box_writes_toggle_back_to_signal` | renderer_test |
| 透明容器落到控件树 | `test_multi_root_component_renders_all_roots`、`test_portal_content_lands_on_root_container`、`test_suspense_switches_in_place` | renderer_test |
| 真控件（libui）链路 | `libui_scenario.rb`（子进程冒烟：创建/点击/重排/绘制/拆解无泄漏） | libui_backend_test |
| 样式键落点矩阵 | `test/style_matrix_test.rb`（16 项） | style_matrix_test |

## 三、主仓 `test/renderer_test.rb`（16 条）逐条对齐

| 主仓断言 | 状态 | native 侧 |
|---|---|---|
| `test_rerun_error_is_caught_by_childs_own_fallback` | ✅ 已对齐 | `test_error_boundary_catches_rerun_failure` |
| `test_rerun_error_without_fallback_still_propagates` | ✅ **N3 新增** | `test_rerun_error_without_fallback_propagates` |
| `test_fragment_root_rerun_error_renders_fallback_in_place` | ✅ **N3 新增** | `test_multi_root_rerun_error_renders_fallback_in_place` |
| `test_first_render_error_uses_childs_own_fallback_without_parent_boundary` | ✅ **N3 新增** | `test_first_render_error_uses_childs_own_fallback` |
| `test_text_to_nil_clears_previous_text` | ✅ 已对齐 | `test_text_is_cleared_when_block_stops_producing_text` |
| `test_text_to_children_switch_clears_previous_text` | ⚠️ 等价（语义不同） | 原生**容器没有文本位**：容器里的字符串会被忽略并提醒（`container_text`），文本清理只在 label / button 上成立 |
| `test_ssr_css_class_array_is_joined_with_space` | — N/A | C 类：`css_class` 在原生侧无对应（见 style-matrix.md 第九节） |
| `test_box_with_explicit_grid_does_not_emit_flex_direction` | ⚠️ 语义差异（已记录） | 原生元素永远是 box：方向由 `direction`（stack/row）决定，`display: grid` 会走 `warn_non_flex_display` 提醒（`test_non_flex_display_warns`）。主仓规则是"grid 容器不受 direction 管辖"，原生没有 grid 控件，故不照搬 |
| `test_box_flex_and_default_still_apply_direction` | ✅ 已对齐 | `test_element_vocabulary_maps_to_widgets`（stack/row → 竖/横 box） |
| `test_kebab_case_style_keys_are_normalized` | ✅ **N3 新增** | `test_kebab_case_style_keys_are_normalized` |
| `test_passthrough_prop_with_signal_warns` | ✅ **N3 新增** | `test_passthrough_prop_with_signal_warns` |
| `test_controlled_value_signal_does_not_warn` | ✅ **N3 新增** | `test_controlled_value_signal_does_not_warn` |
| `test_dispatch_callable_symbol_respects_arity` | ✅ 等价（native 侧覆盖） | `test_symbol_handler_dispatches_to_component_method`（符号处理器经原生事件派发到组件方法） |
| `test_dispatch_callable_proc_keeps_closure_self_unless_bind` | A 类（核心层） | 原生事件走同一 `dispatch_callable`，不重复断言 |
| `test_dispatch_callable_rejects_unknown_handler` | A 类（核心层） | 同上 |
| `test_style_key_conversion_is_memoized` | A 类（核心层） | `Style.normalize` 的 memo 是核心实现细节 |

## 四、其它相关文件的承担方

| 文件 | 条数 | 承担方 | native 侧对应 |
|---|---|---|---|
| `error_boundary_test.rb` | 3 | 核心 + native | 三条都已对齐（含 N3 新增的两条变体） |
| `nesting_test.rb` | 31 | **A 类为主**：keyed/unkeyed 复用、实例保持、卸载钩子、重复 key、类型切换 | native 抽了与控件树相关的 6 条：keyed 重排、keyed 卸载、重复 key、类型切换、多根渲染、根重跑归位；其余由核心保证 |
| `portal_test.rb` | 4 | 核心（+ native 一条落点断言） | `test_portal_content_lands_on_root_container`（原生宿主只有根容器） |
| `suspense_test.rb` | 4 | 核心（+ native 一条切换断言） | `test_suspense_switches_in_place` |
| `lifecycle_hooks_test.rb` | 6 | A 类（核心层） | 原生侧以 `on_mount` / `on_unmount` 的使用性断言覆盖（`test/todo_example_test.rb` 的定时器、`test_removed_keyed_component_unmounts_and_keeps_siblings`） |
| `attr_passthrough_test.rb` | 6 | C 类（HTML 专属） | 不适用；原生侧的对应物是"属性没有对应概念"的提醒（`test_unsupported_style_and_props_still_warn`） |

## 五、仍未覆盖（诚实清单）

以下主仓断言在 native 侧**没有**对等断言，判断是"核心已保证 + 真控件冒烟兜底"，暂不补；
若将来 native 改了对应的钩子实现（`attach` / `detach` / `run_block`），要先补上：

- `nesting_test.rb` 的 `test_child_callback_reaches_parent`（回调冒泡到父组件）
- `nesting_test.rb` 的 `test_unkeyed_child_is_reused_by_position`（无 key 的位置复用）
- `nesting_test.rb` 的 `test_element_keys_are_reused_too`（元素级 key 复用）
- `nesting_test.rb` 的 `test_props_change_keeps_keyed_child_instance`
- `attr_passthrough_test.rb` 的布尔/转义细则（HTML 专属，不涉及原生）

判定与复查建议：这几条都落在"核心 Effect/复用"路径上（A 类），而 native 的平台钩子
只消费核心给的 `attach/detach/set_text` 调用序列——真控件冒烟的"创建/搬运/销毁无泄漏"
断言是它们在本后端的最终落点。
