# frozen_string_literal: true

require_relative "test_helper"

# 渲染语义回归（GOALS N1/N3）：这些用例锁的是"控件树上的行为"——
# 与主仓 test/render_test.rb、nesting_test.rb 的断言一一对应（同一份组件代码，
# 换一个后端应当仍然成立）。真控件的实测由 libui_backend_test.rb 覆盖。
class RendererTest < NativeTest
  # ── N1 验收：点击精确 +1 ──────────────────────────────────

  def test_counter_click_increments_exactly_once_per_click
    mount(TestCounter)
    label = find(kind: :label)
    button = find(kind: :button)

    assert_equal "计数：0", label.text
    5.times { click(button) }
    assert_equal "计数：5", label.text
    assert_equal "点我 +1", button.text
  end

  def test_counter_keeps_widget_identity_across_updates
    mount(TestCounter)
    label = find(kind: :label)
    button = find(kind: :button)

    click(button)

    assert_same label, find(kind: :label), "块级更新不该重建兄弟节点"
    assert_same button, find(kind: :button)
  end

  # ── 元素词表 → 控件映射（GOALS 4.3）───────────────────────

  class Layouts < Citrine::Component
    def view
      stack(gap: 8) do
        row do
          label { "a" }
          button { "b" }
        end
        label { "c" }
      end
    end
  end

  def test_element_vocabulary_maps_to_widgets
    mount(Layouts)

    # 窗口根容器 → 组件的 stack（view 的根）→ row / label
    assert_equal ["box column", ["box row", ["label", "a"], ["button", "b"]], ["label", "c"]],
                 @backend.tree(container.children.first)
  end

  def test_gap_maps_to_container_padding
    mount(Layouts)

    stack_box = container.children.first
    assert stack_box.padded, "gap 非 0 → 容器 padded"
    refute stack_box.children.first.padded, "row 没写 gap → 不 padded"
  end

  class ZeroGap < Citrine::Component
    def view
      stack(gap: 0) { label { "a" } }
    end
  end

  def test_zero_gap_leaves_container_unpadded
    mount(ZeroGap)

    refute container.children.first.padded
  end

  class Flex < Citrine::Component
    def view
      row do
        label(style: { flex_grow: 1 }) { "grow" }
        label { "fixed" }
      end
    end
  end

  def test_flex_grow_maps_to_stretchy
    mount(Flex)
    row = container.children.first

    assert row.children.first.instance_variable_get(:@stretchy)
    refute row.children.last.instance_variable_get(:@stretchy)
  end

  class Disabled < Citrine::Component
    def view
      stack do
        button(disabled: true) { "禁用" }
      end
    end
  end

  def test_disabled_prop_maps_to_widget_enabled_state
    mount(Disabled)

    refute @backend.enabled?(find(kind: :button))
  end

  # ── keyed 复用与重排 ──────────────────────────────────────

  class KeyedList < Citrine::Component
    state :items, default: %w[a b c]

    def view
      stack do
        items.each { |item| label(key: item) { item } }
        button(on_click: -> { self.items = items.reverse }) { "reverse" }
      end
    end
  end

  def test_keyed_reorder_reuses_widgets_and_keeps_new_order
    mount(KeyedList)
    labels = find_all(kind: :label)
    by_text = labels.to_h { |widget| [widget.text, widget] }

    click(find(kind: :button))

    # 同一个 key 复用同一个控件（不是重建）
    assert_same by_text["a"], @backend.find(container, kind: :label, text: "a")
    assert_equal %w[c b a], find_all(kind: :label).map(&:text)
    # 物理顺序就是渲染顺序（末尾是那个按钮）
    stack_box = container.children.first
    assert_equal %w[c b a reverse], stack_box.children.map(&:text)
  end

  # ── S1-2：组件根重跑的落位（attach_before 的承重用例）──────

  class Child < Citrine::Component
    state :n, default: 0

    def view
      label { "n=#{n}" }
    end

    def bump = self.n += 1
  end

  class ParentWithChild < Citrine::Component
    def view
      stack do
        render(Child, key: :child, ref: :child)
        label { "tail" }
      end
    end
  end

  def test_component_root_rerun_returns_to_original_position
    parent = mount(ParentWithChild)
    stack_box = container.children.first
    child_label = @backend.find(container, kind: :label, text: "n=0")

    parent.refs[:child].bump

    assert_equal "n=1", child_label.text
    # 若 attach_before 退化成"追加到末尾"，这里会是 ["tail", "n=1"]
    assert_equal %w[n=1 tail], stack_box.children.map(&:text)
  end

  # ── 文本与块级更新的边界（C3）────────────────────────────

  class TextSwitch < Citrine::Component
    state :text, default: "文本"

    def view
      stack do
        label { text }
        button(on_click: -> { self.text = nil }) { "清空" }
      end
    end
  end

  def test_text_is_cleared_when_block_stops_producing_text
    mount(TextSwitch)
    label = find(kind: :label)

    click(find(kind: :button))

    assert_equal "", label.text, "旧文本必须显式清空（否则与新内容叠加）"
  end

  class NonString < Citrine::Component
    def view
      stack { label { 42 } }
    end
  end

  def test_non_string_content_renders_via_to_s
    _out, err = capture_io { mount(NonString) }

    assert_equal "42", find(kind: :label).text
    assert_match(/内容 block 返回了 Integer/, err)
  end

  # ── 透明容器（fragment / portal / suspense）──────────────

  class MultiRoot < Citrine::Component
    def view
      label { "one" }
      label { "two" }
    end
  end

  class FragmentHost < Citrine::Component
    def view
      stack do
        label { "head" }
        render(MultiRoot)
      end
    end
  end

  def test_multi_root_component_renders_all_roots
    mount(FragmentHost)

    assert_equal %w[head one two], texts(kind: :label)
  end

  class PortalHost < Citrine::Component
    def view
      stack do
        label { "main" }
        portal { label { "overlay" } }
      end
    end
  end

  def test_portal_content_lands_on_root_container
    mount(PortalHost)

    # portal 逃出父容器：标签挂在窗口根容器下，而不是内层 stack 里
    assert_equal ["overlay"], container.children.last(1).map(&:text)
    assert_equal %w[overlay], container.children.select { |w| w.kind == :label }.map(&:text)
    assert_equal %w[main], container.children.first.children.map(&:text)
  end

  class Loader < Citrine::Component
    state :ready, default: false

    def view
      stack do
        suspense(ready: -> { ready }, loading: -> { label { "加载中" } }) do
          label { "内容" }
        end
      end
    end
  end

  def test_suspense_switches_in_place
    loader = mount(Loader)
    placeholder = find(kind: :label)

    assert_equal "加载中", placeholder.text

    loader.ready = true

    assert_equal ["内容"], texts(kind: :label)
    # 同一槽位按位置复用（citrine 的既有语义）：占位控件原地变成真实内容，
    # 组件实例与 state 全程保留，切换不重建
    assert_same placeholder, find(kind: :label)
  end

  # ── 错误边界（S1-6 / C1：重跑路径也要接得住）──────────────

  class Boom < Citrine::Component
    state :armed, default: false

    error_fallback { |error| label { "出错：#{error.message}" } }

    def view
      raise "炸了" if armed

      label { "ok" }
    end
  end

  def test_error_boundary_catches_rerun_failure
    boom = mount(Boom)

    assert_equal ["ok"], texts(kind: :label)

    boom.armed = true

    assert_equal ["出错：炸了"], texts(kind: :label)
  end

  # ── 事件派发：处理器现取（keyed 复用的老坑）──────────────

  class ModeButton < Citrine::Component
    prop :mode, type: Symbol

    class << self
      attr_accessor :hits
    end

    def view
      button(key: :go, on_click: -> { self.class.hits << mode }) { "go" }
    end
  end

  class ModeHost < Citrine::Component
    state :mode, default: :a

    def view
      stack do
        render(ModeButton, mode: mode, key: :btn)
        label { "mode=#{mode}" }
      end
    end
  end

  def test_click_handler_is_read_from_props_at_dispatch_time
    ModeButton.hits = []
    host = mount(ModeHost)
    button = find(kind: :button)

    click(button)
    host.mode = :b
    click(button)

    assert_equal %i[a b], ModeButton.hits
  end

  # ── ref: 句柄 ─────────────────────────────────────────────

  class WithRef < Citrine::Component
    def view
      stack { label(ref: :title) { "标题" } }
    end
  end

  def test_ref_registers_widget_handle
    component = mount(WithRef)

    assert_equal "标题", component.refs[:title].text
    assert_same find(kind: :label), component.refs[:title]
  end

  # ── 未支持元素：报错而非静默降级（GOALS 4.3）────────────

  class Unsupported < Citrine::Component
    def view
      stack { textarea { "多行" } }
    end
  end

  def test_unsupported_element_raises_with_hint
    error = assert_raises(Citrine::Native::UnsupportedElementError) { mount(Unsupported) }

    assert_match(/textarea/, error.message)
    assert_match(/uiNewMultilineEntry/, error.message)
    assert_match(/v0 支持 box \/ label \/ button \/ text_input \/ check_box/, error.message)
  end

  # ── 开发期提醒（dev_mode）────────────────────────────────

  class Noisy < Citrine::Component
    def view
      stack(style: { width: "200px" }) do
        label(id: "x", style: { color: "red" }) { "hi" }
      end
    end
  end

  def test_dev_mode_warns_about_unsupported_style_and_props
    Citrine.dev_mode = true
    _out, err = capture_io { mount(Noisy) }

    # 提醒按 StyleMatrix 分档：:color 是"只能自绘"，:width 是"没有对应概念"
    assert_match(/样式键 :color 在原生后端不支持自动映射（需要自绘）/, err)
    assert_match(/painter\.text/, err)
    assert_match(/样式键 :width 在原生后端没有对应概念/, err)
    assert_match(/属性 "id"/, err)
    assert_match(/已忽略/, err)
    assert_match(/docs\/design\/style-matrix\.md/, err, "提醒要指向样式能力矩阵")
  end

  def test_unsupported_style_is_silent_outside_dev_mode
    Citrine.dev_mode = false
    _out, err = capture_io { mount(Noisy) }

    assert_empty err
  end

  class KeyboardHost < Citrine::Component
    window_key :shortcut

    def view
      stack(css_class: "shell") { label { "x" } }
    end

    def shortcut = nil
  end

  # window_key 自 NA-1 起是支持的（由聚焦中的自绘面板转发，见 area_test.rb）；
  # 这里只盯"没有对应概念的属性"这一条口径不回归
  def test_dev_mode_warns_about_css_class
    Citrine.dev_mode = true
    _out, err = capture_io { mount(KeyboardHost) }

    assert_match(/css_class 在原生后端没有对应概念/, err)
    refute_match(/window_key/, err)
  end

  # ── N3：响应式语义回归（对齐主仓 test/ 的断言口径）────────

  class ReactiveGap < Citrine::Component
    state :wide, default: false

    def view
      stack(gap: -> { wide ? 8 : 0 }) do
        label { "x" }
        button(on_click: -> { self.wide = !wide }) { "toggle" }
      end
    end
  end

  def test_reactive_gap_updates_padding_without_rebuilding_children
    mount(ReactiveGap)
    stack_box = container.children.first
    label = find(kind: :label)

    refute stack_box.padded

    click(find(kind: :button))

    assert stack_box.padded, "响应式 gap 重跑后容器 padding 要跟上"
    assert_same label, find(kind: :label), "属性重跑不该重建子树"
  end

  class RowWithHook < Citrine::Component
    prop :name, type: String

    class << self
      attr_accessor :unmounted
    end

    def view
      label { name }
    end

    on_unmount { RowWithHook.unmounted << name }
  end

  class ListHost < Citrine::Component
    state :names, default: %w[a b]

    def view
      stack do
        names.each { |name| render(RowWithHook, name: name, key: name) }
        button(on_click: -> { self.names = names - ["a"] }) { "remove" }
      end
    end
  end

  def test_removed_keyed_component_unmounts_and_keeps_siblings
    RowWithHook.unmounted = []
    mount(ListHost)
    before = find_all(kind: :label)
    kept = @backend.find(container, kind: :label, text: "b")

    click(find(kind: :button))

    assert_equal ["a"], RowWithHook.unmounted
    assert_equal ["b"], texts(kind: :label)
    assert_same kept, find(kind: :label), "留下的行要复用同一个控件"
    assert_equal 1, before.count { |widget| widget.destroyed? }, "被删的行要销毁"
  end

  class DupKeys < Citrine::Component
    def view
      stack do
        label(key: :x) { "1" }
        label(key: :x) { "2" }
      end
    end
  end

  def test_duplicate_sibling_keys_raise
    error = assert_raises(RuntimeError) { mount(DupKeys) }

    assert_match(/重复 key/, error.message)
  end

  class TypeA < Citrine::Component
    class << self
      attr_accessor :unmounts
    end

    def view
      label { "A" }
    end

    on_unmount { TypeA.unmounts += 1 }
  end

  class TypeB < Citrine::Component
    def view
      label { "B" }
    end
  end

  class TypeSwitcher < Citrine::Component
    state :use_a, default: true

    def view
      stack do
        use_a ? render(TypeA) : render(TypeB)
        label { "tail" }
      end
    end
  end

  def test_switching_component_type_unmounts_old_instance
    TypeA.unmounts = 0
    switcher = mount(TypeSwitcher)
    old_widget = find(kind: :label)

    assert_equal %w[A tail], texts(kind: :label)

    switcher.use_a = false

    assert_equal %w[B tail], texts(kind: :label)
    assert_equal 1, TypeA.unmounts, "换组件类型要卸载旧实例"
    assert old_widget.destroyed?, "旧组件根的控件要销毁（不能留在控件树里）"
  end

  # ── 卸载：控件逐个销毁、不留活口 ────────────────────────

  def test_unmount_destroys_every_widget_except_window_and_root_container
    component = mount(Layouts)

    Citrine.unmount(component)

    assert_equal %i[box window], live_widgets.map(&:kind).sort
    assert_operator @backend.destroyed_widgets.size, :>=, 4
  end

  # ── N2：受控输入 ─────────────────────────────────────────

  class Form < Citrine::Component
    state :draft, default: ""
    state :submitted, default: nil
    state :done, default: false
    state :last_checked, default: nil

    def view
      stack do
        text_input(value: signal(:draft), on_change: ->(text) { self.submitted = text })
        label { "draft=#{draft}" }
        # check_box 没有内容位（同 DOM 的 <input type=checkbox>）：标签用相邻 label，
        # 传块会被 DSL 静默丢弃
        check_box(checked: signal(:done), on_change: ->(checked) { self.last_checked = checked })
        label { "done=#{done}" }
      end
    end
  end

  def test_text_input_writes_user_typing_back_to_signal
    form = mount(Form)
    entry = find(kind: :entry)

    entry.value = "hello"
    entry.fire(:change)

    assert_equal "hello", form.draft
    assert_equal "hello", form.submitted, "on_change 收到新文本"
    assert_equal ["draft=hello", "done=false"], texts(kind: :label)
  end

  def test_text_input_follows_signal_writes
    form = mount(Form)
    entry = find(kind: :entry)

    form.draft = "reset"

    assert_equal "reset", entry.value
  end

  # on_enter：回车提交（DOM 侧 on_enter 的原生对应）。接线先写回 Signal 再派发，
  # 处理器读到的是新值——与 on_change 同一口径
  class EnterForm < Citrine::Component
    state :draft, default: ""
    state :entered, default: nil

    def view
      stack do
        text_input(value: signal(:draft), on_enter: ->(_text) { self.entered = draft })
        label { "entered=#{entered}" }
      end
    end
  end

  def test_text_input_on_enter_writes_back_and_fires
    form = mount(EnterForm)
    entry = find(kind: :entry)

    entry.value = "提交内容"
    backend.fire_enter(entry)

    assert_equal "提交内容", form.draft
    assert_equal "提交内容", form.entered
    assert_equal ["entered=提交内容"], texts(kind: :label)
  end

  def test_text_input_without_on_enter_does_not_wire_activate
    form = mount(Form)
    entry = find(kind: :entry)

    entry.value = "x"
    assert_equal false, backend.fire_enter(entry)  # 没订阅就没有处理器可触发
    assert_nil form.submitted
  end

  # 事件层错误边界（EventGuard）：处理器抛异常不带走主循环（libui/GTK 同口径）
  class ExplodingButton < Citrine::Component
    state :count, default: 0

    def view
      stack do
        button(on_click: ->(_e) { raise "boom" })
        label { "count=#{count}" }
      end
    end
  end

  def test_event_handler_exception_is_contained
    subject = mount(ExplodingButton)
    btn = find(kind: :button)

    out, err = capture_io do
      click(btn)
    end

    assert_match(/boom/, err)
    assert_match(/on_click/, err)
    # 主循环继续：控件树仍可查询，后续点击同样不抛
    assert_equal ["count=0"], texts(kind: :label)
    capture_io { click(btn) }
    assert_equal ["count=0"], texts(kind: :label)
  end

  def test_check_box_writes_toggle_back_to_signal
    form = mount(Form)
    checkbox = find(kind: :checkbox)

    checkbox.checked = true
    checkbox.fire(:toggle)

    assert_equal true, form.done
    assert_equal true, form.last_checked
    assert_equal ["draft=", "done=true"], texts(kind: :label)
  end

  def test_controlled_widgets_do_not_rebind_native_callbacks_when_reused
    mount(Form)

    assert_equal 1, find(kind: :entry).callback_count(:change)
    assert_equal 1, find(kind: :checkbox).callback_count(:toggle)
  end

  # ── N3（续）：错误边界的三个变体、样式键归一、符号处理器、Signal 透传提醒 ──

  # 无兜底的重跑错误照常抛给调用方（错误边界只兜它自己覆盖的子树）
  class BareBomb < Citrine::Component
    class << self
      attr_accessor :instance
    end

    state :armed, default: false

    def initialize(props = {})
      super
      self.class.instance = self
    end

    def view
      raise "无兜底爆炸" if armed

      label { "ok" }
    end
  end

  class BareBombHost < Citrine::Component
    def view
      stack { render(BareBomb, key: :b) }
    end
  end

  def test_rerun_error_without_fallback_propagates
    mount(BareBombHost)
    child = BareBomb.instance

    error = assert_raises(RuntimeError) { child.armed = true }

    assert_match(/无兜底爆炸/, error.message)
  end

  # 多根组件（fragment 语义）重跑失败 → 自己的兜底就地替换掉全部根
  class MultiRootBomb < Citrine::Component
    class << self
      attr_accessor :instance
    end

    state :armed, default: false

    error_fallback { |_error| label { "多根兜底" } }

    def initialize(props = {})
      super
      self.class.instance = self
    end

    def view
      raise "多根爆炸" if armed

      label { "甲" }
      label { "乙" }
    end
  end

  class MultiRootHost < Citrine::Component
    def view
      stack { render(MultiRootBomb, key: :m) }
    end
  end

  def test_multi_root_rerun_error_renders_fallback_in_place
    mount(MultiRootHost)

    assert_equal %w[甲 乙], texts(kind: :label)

    MultiRootBomb.instance.armed = true

    assert_equal ["多根兜底"], texts(kind: :label), "兜底要替换掉全部根，且不残留旧内容"
  end

  # 首次渲染就抛错：子组件自己的兜底接住，不需要父级边界
  class FirstRenderBomb < Citrine::Component
    error_fallback { |error| label { "首次兜底：#{error.message}" } }

    def view
      raise "首次爆炸"
    end
  end

  def test_first_render_error_uses_childs_own_fallback
    klass = Class.new(Citrine::Component) do
      def view
        stack do
          label { "head" }
          render(FirstRenderBomb)
        end
      end
    end

    mount(klass)

    assert_equal ["head", "首次兜底：首次爆炸"], texts(kind: :label)
  end

  # 样式键归一：kebab-case 与 camelCase 都要落到同一套语义（主仓 style_test 的口径）
  def test_kebab_case_style_keys_are_normalized
    klass = Class.new(Citrine::Component) do
      def view
        stack(style: { "gap" => 6 }) do
          label(style: { "flex-grow" => 1 }) { "x" }
        end
      end
    end
    mount(klass)

    assert container.children.first.padded, "kebab-case 的 gap 要映射到容器 padding"
    assert_equal true, find(kind: :label).instance_variable_get(:@stretchy),
                 "kebab-case 的 flex-grow 要等价于 flex_grow"
  end

  # 事件处理器写成符号方法名：按 arity 派发（主仓 dispatch_callable 的口径）
  class SymbolHandler < Citrine::Component
    attr_reader :hits

    def initialize(props = {})
      super
      @hits = []
    end

    def view
      button(on_click: :bump) { "go" }
    end

    def bump = @hits << :zero_arity
  end

  def test_symbol_handler_dispatches_to_component_method
    component = mount(SymbolHandler)

    click(find(kind: :button))

    assert_equal [:zero_arity], component.hits
  end

  # 透传属性收到 Signal 要提醒（值不会解包、会渲染成 #<Citrine::Signal…>）；
  # 受控值属性（value:）传 Signal 是正常用法，不该提醒
  def test_passthrough_prop_with_signal_warns
    Citrine.dev_mode = true
    klass = Class.new(Citrine::Component) do
      def view
        stack { label(title: Citrine::Signal.new("x")) { "hi" } }
      end
    end

    _out, err = capture_io { mount(klass) }

    assert_match(/收到 Signal/, err)
    assert_match(/受控值/, err)
  end

  def test_controlled_value_signal_does_not_warn
    Citrine.dev_mode = true
    klass = Class.new(Citrine::Component) do
      def view
        stack { text_input(value: Citrine::Signal.new("draft")) }
      end
    end

    _out, err = capture_io { mount(klass) }

    refute_match(/收到 Signal/, err)
  end
end
