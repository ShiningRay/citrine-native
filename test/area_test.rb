# frozen_string_literal: true

require_relative "test_helper"

# 自绘面板（area）语义测试——桩后端（GOALS 风险 3：CI 不能开真窗口）。
# 覆盖设计 docs/design/native-area.md 验收场景 1：元素契约、事件分发与键名归一、
# 重绘调度、定时器、Painter::Recording 的图元断言、未支持项的提醒、卸载清理。
#
# 真控件（libui）部分见 test/libui_backend_test.rb + test/support/libui_scenario.rb。
class AreaTest < NativeTest
  # ── 测试用组件 ──────────────────────────────────────────

  # 全事件面板：收到的每个事件记进 @log（普通数组，不触发渲染）
  class FullPanel < Citrine::Component
    state :rows, default: %w[a b]

    attr_reader :log

    def initialize(props = {})
      super
      @log = []
    end

    def view
      stack(gap: 4) do
        label(ref: :status) { "rows=#{rows.size}" }
        element(:area, ref: :panel,
                       size: [200, 100],
                       watch: -> { rows.size },
                       on_draw: ->(panel) { paint(panel) },
                       on_click: ->(event) { note(:click, event) },
                       on_mouse_down: ->(event) { note(:down, event) },
                       on_mouse_up: ->(event) { note(:up, event) },
                       on_mouse_move: ->(event) { note(:move, event) },
                       on_key: { "ArrowUp" => :arrow_key, "Enter" => :enter_key, else: :other_key })
      end
    end

    def paint(panel)
      panel.rect(0, 0, panel.width, panel.height, fill: "#14203a")
      rows.each_with_index { |row, index| panel.text(row, x: 8, y: 8 + index * 16, color: "#e6ecf8") }
    end

    def note(kind, event) = @log << [kind, event]
    def arrow_key(event) = note(:key_arrow, event)
    def enter_key(event) = note(:key_enter, event)
    def other_key(event) = note(:key_other, event)
  end

  def panel = find(kind: :area)
  def log = @subject.log

  # refs[:panel] 是 AreaHandle（设计 2.5）；测试要直接戳后端时取它包着的那个句柄
  def area_of(component) = component.refs[:panel].handle

  def mount_panel(**options)
    @subject = mount(FullPanel, **options)
    panel
  end

  # 只被 on_draw 读的信号：绘制回调不建订阅（设计 2.4）
  class DrawOnlyReader < Citrine::Component
    state :cell_size, default: 4

    def view
      element(:area, ref: :panel, on_draw: ->(panel) { paint(panel) })
    end

    def paint(panel)
      panel.text("size=#{cell_size}", x: 0, y: 0)
      panel.rect(0, 0, cell_size, cell_size, fill: "#fff")
    end
  end

  # 只被 watch 读的信号：依赖变化 → 排这个面板的重绘
  class WatchedPanel < Citrine::Component
    state :version, default: 0

    def view
      element(:area, ref: :panel, watch: -> { version },
                     on_draw: ->(panel) { panel.text("v#{version}", x: 0, y: 0) })
    end
  end

  # keyed 复用换处理器：area 节点被复用（不重绑事件），处理器在派发时从 props 现取
  class SwappingHandlers < Citrine::Component
    state :mode, default: :first

    attr_reader :log

    def initialize(props = {})
      super
      @log = []
    end

    def view
      stack do
        element(:area, key: :panel, ref: :panel,
                       on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") },
                       on_click: mode == :first ? ->(_event) { @log << :first } : ->(_event) { @log << :second })
        button(on_click: -> { self.mode = :second }) { "换" }
      end
    end
  end

  # 全图元画笔
  class AllPrimitives < Citrine::Component
    def view
      element(:area, ref: :panel, on_draw: ->(panel) { paint(panel) })
    end

    def paint(panel)
      panel.rect(0, 0, 10, 10, fill: "#0f0", stroke: "#333", line_width: 2, radius: 3)
      panel.line(0, 0, 10, 10, color: [0.5, 0.25, 0.1], width: 1.5)
      panel.polyline([[0, 0], [1, 2], [3, 4]], color: "#abc")
      panel.polygon([[0, 0], [10, 0], [5, 8]], fill: "#abc", stroke: :none)
      panel.text("贵州茅台", x: 4, y: 6, color: "#8f8", size: 15, weight: :bold,
                            family: "Menlo", align: :right, width: 90)
      panel.clip(1, 2, 3, 4) { panel.rect(1, 2, 3, 4, fill: "#fff") }
    end
  end

  # ── 1) 元素契约（设计 2.1）───────────────────────────────

  def test_area_element_creates_a_panel_widget
    panel = mount_panel

    assert_equal :area, backend.kind(panel)
    assert_equal 1, backend.find_all(container, kind: :area).size
    assert_equal "rows=2", backend.get_text(@subject.refs[:status])
  end

  def test_ref_points_at_an_area_handle_wrapping_the_panel
    panel = mount_panel
    handle = @subject.refs[:panel]

    assert_instance_of Citrine::Native::AreaHandle, handle
    assert_same panel, handle.handle, "句柄里包着后端句柄（应用一般不用碰）"
  end

  def test_area_handle_repaint_queues_a_redraw
    panel = mount_panel
    before = backend.redraw_count(panel)

    @subject.refs[:panel].repaint

    assert_equal before + 1, backend.redraw_count(panel)
  end

  def test_area_handle_focus_goes_through_the_backend
    panel = mount_panel

    assert @subject.refs[:panel].focus
    assert backend.focused?(panel)
  end

  def test_area_handle_scroll_to_on_a_plain_panel_fails_fast
    panel = mount_panel
    handle = @subject.refs[:panel]

    refute handle.scrollable?
    error = assert_raises(ArgumentError) { handle.scroll_to(0, 100, 200, 120) }
    assert_match(/非滚动面板没有滚动条/, error.message)
  end

  class ScrollingPanel < Citrine::Component
    def view
      element(:area, ref: :panel, scroll: true, size: [300, 800],
                     on_draw: ->(panel) { panel.rect(0, 0, 10, 10, fill: "#fff") })
    end
  end

  def test_area_handle_scroll_to_on_a_scrolling_panel_reaches_the_backend
    component = mount(ScrollingPanel)
    handle = component.refs[:panel]

    assert handle.scrollable?
    handle.scroll_to(0, 200, 300, 120)

    assert_equal [0.0, 200.0, 300.0, 120.0], backend.scrolled_to(handle.handle)
  end

  def test_on_draw_is_required
    klass = Class.new(Citrine::Component) do
      def view = element(:area)
    end

    error = assert_raises(Citrine::Native::Error) { mount(klass) }
    assert_match(/必须提供 on_draw/, error.message)
  end

  def test_unknown_element_still_fails_fast
    klass = Class.new(Citrine::Component) do
      def view = element(:canvas)
    end

    assert_raises(Citrine::Native::UnsupportedElementError) { mount(klass) }
  end

  def test_content_block_on_area_is_reported_and_ignored
    Citrine.dev_mode = true
    klass = Class.new(Citrine::Component) do
      def view = element(:area, on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") }) { "文字" }
    end

    _out, err = capture_io { mount(klass) }

    assert_match(/没有文本位/, err)
    assert_match(/面板内容请在 on_draw 里画/, err)
  end

  # scroll: true 的内容尺寸在 libui 里创建时定死（uiNewScrollingArea），且滚动面板下
  # Draw 不报尺寸（ui.h: only defined for nonscrolling areas）——所以 size 是必需的
  def test_scrolling_area_requires_size
    klass = Class.new(Citrine::Component) do
      def view = element(:area, scroll: true, on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })
    end

    error = assert_raises(Citrine::Native::Error) { mount(klass) }
    assert_match(/scroll: true 需要同时给 size/, error.message)
  end

  def test_scrolling_area_passes_content_size_to_backend
    klass = Class.new(Citrine::Component) do
      def view
        element(:area, scroll: true, size: [640, 480],
                       on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })
      end
    end

    mount(klass)

    assert_equal [640.0, 480.0], backend.area_size(panel)
    assert backend.scrolling?(panel)
  end

  def test_static_size_on_plain_area_is_ignored_with_a_hint
    Citrine.dev_mode = true
    _out, err = capture_io { mount_panel }

    assert_match(/size: 在 scroll: false 时不生效/, err)
    assert_nil backend.area_size(panel), "非滚动面板的尺寸由外层容器布局决定，不该透传给后端"
  end

  def test_invalid_size_fails_fast
    klass = Class.new(Citrine::Component) do
      def view = element(:area, size: 200, on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })
    end

    error = assert_raises(Citrine::Native::Error) { mount(klass) }
    assert_match(/size 应为 \[宽, 高\]/, error.message)
  end

  def test_reactive_size_is_reported_and_ignored
    Citrine.dev_mode = true
    klass = Class.new(Citrine::Component) do
      state :wide, default: true

      def view
        element(:area, size: -> { wide ? [10, 10] : [1, 1] },
                       on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })
      end
    end

    _out, err = capture_io { mount(klass) }

    assert_match(/size 传了 Proc/, err)
  end

  # 未支持的 prop/样式仍按既有口径提醒（不静默）；area 自己消费的 prop 不该被误报
  def test_unsupported_style_and_props_still_warn
    Citrine.dev_mode = true
    klass = Class.new(Citrine::Component) do
      def view
        element(:area, css_class: "panel", style: { background: "#000" },
                       size: [10, 10], scroll: true, watch: -> { 1 },
                       on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })
      end
    end

    _out, err = capture_io { mount(klass) }

    assert_match(/css_class 在原生后端没有对应概念/, err)
    assert_match(/样式键 :background 在原生后端不支持/, err)
    # size / scroll / watch 是本后端**自己消费**的 prop：既不该被说成"没有对应概念"，
    # watch: 也不该被基类当成"Proc 不会被求值"的误用
    refute_match(/属性 "(size|scroll|watch)"/, err)
    refute_match(/prop :watch 收到 Proc/, err)
  end

  # ── 2) 事件分发与归一（设计 2.3）─────────────────────────

  def test_click_is_synthesized_from_down_and_up
    panel = mount_panel

    backend.fire_mouse_down(panel, 12, 34)
    assert_equal [:down], log.map(&:first)

    backend.fire_mouse_up(panel, 12, 34)
    assert_equal %i[down up click], log.map(&:first), "DOM 顺序：mousedown → mouseup → click"
  end

  def test_click_carries_local_coordinates_and_modifiers
    panel = mount_panel
    backend.fire_click(panel, 30, 40, modifiers: { shift: true, meta: true })

    event = log.find { |(kind, _)| kind == :click }.last
    assert_instance_of Citrine::Native::PointerEvent, event
    assert_equal "click", event.type
    assert_equal [30.0, 40.0], event.position
    assert event.shift?
    assert event.meta?
    assert event.command?, "⌘ 与 Ctrl 都算 command（与 KeyEvent 同口径）"
    refute event.ctrl?
    assert event.left?
  end

  def test_pointer_event_types_are_mapped
    panel = mount_panel
    backend.fire_mouse_down(panel, 1, 1)
    backend.fire_mouse_move(panel, 2, 2)
    backend.fire_mouse_up(panel, 3, 3)

    assert_equal [[:down, "mouse_down"], [:move, "mouse_move"], [:up, "mouse_up"], [:click, "click"]],
                 log.map { |(kind, event)| [kind, event.type] }
  end

  def test_pointer_event_has_no_wheel_type
    refute_includes Citrine::Native::PointerEvent::TYPES, "wheel",
                    "设计 2.3：libui 的 area 不带滚轮事件（要滚动用 scroll: true + scroll_to）"
  end

  def test_mouse_up_without_press_is_not_a_click
    panel = mount_panel
    backend.fire_mouse_up(panel, 5, 5)

    assert_equal [:up], log.map(&:first), "没有按下过的抬起不算 click"
  end

  def test_a_press_without_release_does_not_click_twice
    panel = mount_panel
    backend.fire_mouse_down(panel, 1, 1)
    backend.fire_mouse_up(panel, 1, 1)
    backend.fire_mouse_up(panel, 1, 1)

    assert_equal 1, log.count { |(kind, _)| kind == :click }
  end

  # keyed 复用：节点沿用时**不重绑**事件，处理器在派发时从 props 现取
  def test_handlers_are_read_from_props_at_dispatch_time
    component = mount(SwappingHandlers)
    panel = area_of(component)
    backend.fire_click(panel, 1, 1)

    find(kind: :button).fire(:click) # 触发重渲染换上另一个处理器
    backend.fire_click(panel, 1, 1)

    assert_equal %i[first second], component.log
  end

  def test_key_hash_table_dispatches_by_key_name
    panel = mount_panel
    backend.fire_key(panel, "ArrowUp")
    backend.fire_key(panel, "Enter")
    backend.fire_key(panel, "z")

    assert_equal %i[key_arrow key_enter key_other], log.map(&:first)
  end

  def test_key_event_view_carries_key_and_modifiers
    panel = mount_panel
    backend.fire_key(panel, "Enter", modifiers: { shift: true, ctrl: true, alt: true, meta: true })

    event = log.first.last
    assert_instance_of Citrine::KeyEvent, event
    assert_equal "Enter", event.key
    assert event.shift? && event.ctrl? && event.alt? && event.meta?
    assert event.command?
  end

  # ── 2b) ⌘ 键不吞菜单快捷键（NA-2 P1 / 设计 2.3、5.3）──────
  # libui 的 KeyEvent 回调先于菜单快捷键：返回非零 = 事件到此为止，⌘H 这类菜单项
  # 在焦点落到面板时会失效（NA-2 用真 OS 投递对照实验证明过）。规则是"⌘ 一律回报
  # 未处理，但回调照常触发"。桩后端的 fire_key 返回值与 libui 闭包的返回值同口径。

  def test_command_key_is_not_claimed_but_still_delivered
    panel = mount_panel

    refute backend.fire_key(panel, "z", modifiers: { meta: true }),
           "⌘ 组合键必须回报 false（libui 据此继续走菜单快捷键），实际吞掉了"

    assert_equal %i[key_other], log.map(&:first), "回调仍要触发（应用自处理的 ⌘Z 不受影响）"
    assert log.first.last.meta?, "事件视图里仍带着 ⌘"
  end

  def test_plain_key_with_handler_is_claimed
    panel = mount_panel

    assert backend.fire_key(panel, "z"), "无 ⌘ 且声明了 on_key：回报已处理（抑制系统提示音）"
  end

  def test_shift_or_alt_alone_still_claims_the_key
    panel = mount_panel

    assert backend.fire_key(panel, "z", modifiers: { shift: true }),
           "只有 ⌘ 会被让给菜单：Shift/Alt 组合仍由面板认领"
    assert backend.fire_key(panel, "z", modifiers: { alt: true, ctrl: true })
  end

  def test_command_key_without_handler_is_not_claimed
    klass = Class.new(Citrine::Component) do
      def view = element(:area, on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })
    end

    mount(klass)

    refute backend.fire_key(find(kind: :area), "h", modifiers: { meta: true })
  end

  # window_key 也走同一条返回口径：⌘ 组合键在应用侧照样收到，但整体不认领
  def test_command_key_through_window_key_is_not_claimed
    component = mount(GlobalKeys)

    refute backend.fire_key(area_of(component), "z", modifiers: { meta: true }),
           "window_key 收了 ⌘Z 也不能吞掉菜单快捷键"
    assert_equal ["z"], component.seen, "全局处理器仍要收到按键"
  end

  def test_key_up_is_not_delivered
    panel = mount_panel
    backend.fire_key(panel, "Enter", up: true)

    assert_empty log, "v0 没有 on_key_up（抬起不投递）"
  end

  def test_key_without_handler_is_harmless
    klass = Class.new(Citrine::Component) do
      def view = element(:area, on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })
    end

    mount(klass)

    refute backend.fire_key(find(kind: :area), "a"), "没有处理器时返回 false（libui 据此走系统默认处理）"
  end

  # ── 3) window_key 由聚焦面板转发（G-9 / 设计 2.3）─────────

  class GlobalKeys < Citrine::Component
    window_key :global_key

    attr_reader :seen

    def initialize(props = {})
      super
      @seen = []
    end

    def view = element(:area, ref: :panel, on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })

    def global_key(event) = @seen << event.key
  end

  def test_window_key_receives_keys_from_the_panel
    component = mount(GlobalKeys)
    backend.fire_key(panel, "ArrowDown")

    assert_equal ["ArrowDown"], component.seen
  end

  def test_window_key_and_panel_handler_both_run
    component = mount(GlobalKeys)
    panel = area_of(component)

    assert backend.fire_key(panel, "a")
    assert_equal ["a"], component.seen
  end

  def test_window_keys_are_unregistered_on_unmount
    component = mount(GlobalKeys)
    panel = find(kind: :area)
    Citrine.unmount(component)

    assert_empty component.seen
    assert_raises(ArgumentError) { backend.fire_key(panel, "ArrowDown") }
  end

  class ScopedKeys < Citrine::Component
    window_key :scoped_key, scope: :focused

    attr_reader :seen

    def initialize(props = {})
      super
      @seen = []
    end

    def view = stack { label { "这个组件里没有面板" } }

    def scoped_key(event) = @seen << event.key
  end

  # 面板与 window_key 组件是**兄弟**：焦点面板不在它子树里 → scope: :focused 不响应
  # （DOM 侧是 activeElement 落在组件 root 内；原生侧"焦点"= 哪个面板收到了按键）
  class PanelAndScopedSibling < Citrine::Component
    def view
      stack do
        render(ScopedKeys, ref: :scoped)
        element(:area, ref: :panel, on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })
      end
    end
  end

  def test_scoped_window_key_ignores_keys_from_a_sibling_panel
    component = mount(PanelAndScopedSibling)
    backend.fire_key(area_of(component), "a")

    assert_empty component.refs[:scoped].seen
  end

  class HostWithScopedPanel < Citrine::Component
    window_key :scoped_key, scope: :focused

    attr_reader :seen

    def initialize(props = {})
      super
      @seen = []
    end

    def view = element(:area, ref: :panel, on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })

    def scoped_key(event) = @seen << event.key
  end

  def test_scoped_window_key_responds_inside_its_own_subtree
    component = mount(HostWithScopedPanel)
    backend.fire_key(area_of(component), "x")

    assert_equal ["x"], component.seen
  end

  # ── 4) 重绘调度（设计 2.4）──────────────────────────────

  def test_mount_queues_a_redraw
    assert_operator backend.redraw_count(mount_panel), :>=, 1
  end

  # P2.2：在 on_draw 里调 handle.repaint 必须**排到这次绘制之后**——真后端下 AppKit
  # 在 drawRect 里忽略 setNeedsDisplay，直接排会被静默丢掉，"在 on_draw 末尾再排一帧"
  # 的自排队动画就冻在第一帧（NA-2 实测 frames=1）。桩后端与真后端同契约。
  class SelfSchedulingPanel < Citrine::Component
    def view
      element(:area, ref: :panel, on_draw: ->(panel) { paint(panel) })
    end

    # 自排队动画的写法：画完就再标脏一次，指望下一帧接着画
    def paint(panel)
      panel.rect(0, 0, 1, 1, fill: "#fff")
      refs[:panel].repaint
    end
  end

  def test_repaint_inside_on_draw_is_deferred_not_dropped
    component = mount(SelfSchedulingPanel)
    panel = area_of(component)
    backend.fire_draw(panel, width: 40, height: 30) # 先把挂载期的兜底重绘排掉
    during = nil
    # 渲染器的订阅者先跑（它才会调应用的 on_draw），所以这里看到的是"应用刚 repaint 完"的状态
    backend.on_area_draw(panel) do |_painter|
      during ||= [backend.drawing?(panel), backend.redraw_count(panel)]
    end
    before = backend.redraw_count(panel)

    backend.fire_draw(panel, width: 40, height: 30)

    assert_equal [true, before], during, "绘制期间：面板标着正在绘制，且重绘请求还没落地（延后）"
    assert_equal before + 1, backend.redraw_count(panel), "绘制收尾后补上这次重绘（下一帧能画出来）"
  end

  def test_repaint_outside_on_draw_is_immediate
    component = mount(SelfSchedulingPanel)
    panel = area_of(component)
    before = backend.redraw_count(panel)

    component.refs[:panel].repaint

    assert_equal before + 1, backend.redraw_count(panel), "绘制期之外照旧立即标脏"
  end

  def test_deferred_repaints_are_coalesced_per_panel
    component = mount(SelfSchedulingPanel)
    panel = area_of(component)
    before = backend.redraw_count(panel)
    backend.on_area_draw(panel) { |_painter| 3.times { backend.area_queue_redraw(panel) } }

    backend.fire_draw(panel, width: 40, height: 30)

    assert_equal before + 1, backend.redraw_count(panel), "同一轮里的多次请求合并成一次（不会画 3 帧）"
  end

  def test_watch_dependency_queues_exactly_one_redraw
    component = mount(WatchedPanel)
    panel = area_of(component)
    before = backend.redraw_count(panel)

    component.version = 1

    assert_equal before + 1, backend.redraw_count(panel),
                 "watch 的信号没被 view 读 → 只有 watch 这一条路径排重绘"
  end

  def test_view_signal_change_repaints_through_the_settle_fallback
    panel = mount_panel
    before = backend.redraw_count(panel)

    @subject.rows = %w[a b c]

    assert_operator backend.redraw_count(panel) - before, :>=, 1
    assert_equal "rows=3", backend.get_text(@subject.refs[:status])
  end

  # 没有 watch: 的面板靠"收敛点兜底重绘"跟上变化（设计 2.4 的第二条）：
  # 视图重渲染落定后，活着的面板都会被排一次重绘
  class NoWatchPanel < Citrine::Component
    state :label_text, default: "a"
    state :value, default: 0

    def view
      stack do
        label { label_text }   # 让视图订阅这个信号：改它 → 收敛 → 兜底重绘
        element(:area, ref: :panel,
                       on_draw: ->(panel) { panel.text(value.to_s, x: 0, y: 0) })
      end
    end
  end

  def test_settle_fallback_repaints_panels_without_watch
    component = mount(NoWatchPanel)
    panel = area_of(component)
    before = backend.redraw_count(panel)

    component.label_text = "b"

    assert_equal before + 1, backend.redraw_count(panel),
                 "没有 watch: 的面板也要在收敛点被排重绘（否则画面停在旧帧）"
  end

  # 绘制回调在 libui 的 Draw 里跑（不在 Effect 内）：里面的信号读取不建立订阅，
  # 否则每帧都会重排一次订阅
  def test_signal_read_inside_on_draw_does_not_subscribe
    component = mount(DrawOnlyReader)
    panel = area_of(component)
    before = backend.redraw_count(panel)

    component.cell_size = 8

    assert_equal before, backend.redraw_count(panel), "on_draw 里的读取不该建立订阅"
  end

  def test_unmounted_panel_is_destroyed_and_not_repainted
    panel = mount_panel
    count = backend.redraw_count(panel)
    Citrine.unmount(@subject)

    assert_empty backend.find_all(container, kind: :area)
    assert panel.destroyed?
    assert_equal count, backend.redraw_count(panel), "面板没了就不该再排重绘"
  end

  # ── 5) Painter::Recording 图元断言（设计 2.2）────────────

  def recording(panel)
    backend.fire_draw(panel)
  end

  def test_recording_captures_the_draw_sequence
    panel = mount_panel
    rec = recording(panel)

    assert_equal %i[rect text text], rec.types
    assert_equal %w[a b], rec.calls_of(:text).map { |call| call[:text] }
    rect = rec.calls_of(:rect).first
    assert_equal [0.0, 0.0, 200.0, 100.0], [rect[:x], rect[:y], rect[:w], rect[:h]]
    assert_in_delta(0.078, rect[:fill][0], 0.001, "hex 颜色归一成 0..1 浮点")
    assert_equal 1.0, rect[:fill][3]
  end

  def test_recording_uses_the_requested_viewport
    panel = mount_panel
    rec = backend.fire_draw(panel, width: 320, height: 240)

    assert_equal [320.0, 240.0], [rec.width, rec.height]
    assert_equal [320.0, 240.0], rec.content_size, "内容尺寸 = 面板尺寸（非滚动面板）"
    assert_equal [0.0, 0.0, 320.0, 240.0], rec.clip_rect, "非滚动面板整块可见"
  end

  def test_recording_clip_rect_is_the_visible_region_on_a_scrolling_panel
    rec = Citrine::Native::Painter::Recording.new(width: 300, height: 800,
                                                  clip: [0.0, 240.0, 300.0, 120.0])

    assert_equal [300.0, 800.0], rec.content_size
    assert_equal [0.0, 240.0, 300.0, 120.0], rec.clip_rect, "滚动面板：clip_rect 随滚动位置变化"
    assert_in_delta(240.0, rec.clip_rect[1], 0.001)
  end

  def test_all_primitives_are_recorded_with_normalized_arguments
    mount(AllPrimitives)
    rec = recording(panel)

    assert_equal %i[rect line polyline polygon text clip_begin rect clip_end], rec.types

    rect = rec.calls_of(:rect).first
    assert_equal [0.0, 0.0, 10.0, 10.0], [rect[:x], rect[:y], rect[:w], rect[:h]]
    assert_equal [0.0, 1.0, 0.0, 1.0], rect[:fill]
    assert_equal 2.0, rect[:line_width]
    assert_equal 3.0, rect[:radius]

    line = rec.calls_of(:line).first
    assert_equal [0.5, 0.25, 0.1, 1.0], line[:color]
    assert_equal 1.5, line[:width]

    polygon = rec.calls_of(:polygon).first
    assert_equal [[0.0, 0.0], [10.0, 0.0], [5.0, 8.0]], polygon[:points]

    text = rec.calls_of(:text).first
    assert_equal "贵州茅台", text[:text]
    assert_equal 15.0, text[:size]
    assert_equal 700, text[:weight]
    assert_equal "Menlo", text[:family]
    assert_equal :right, text[:align]
    assert_equal 90.0, text[:width]
    assert_equal [0.533, 1.0, 0.533, 1.0], text[:color].map { |channel| channel.round(3) }

    clip = rec.calls_of(:clip_begin).first
    assert_equal [1.0, 2.0, 3.0, 4.0], [clip[:x], clip[:y], clip[:w], clip[:h]]
  end

  def test_color_forms_are_normalized
    rec = Citrine::Native::Painter::Recording.new
    rec.rect(0, 0, 1, 1, fill: "#abc")
    rec.rect(0, 0, 1, 1, fill: "#11223344")
    rec.rect(0, 0, 1, 1, fill: [0.1, 0.2, 0.3])
    rec.rect(0, 0, 1, 1, fill: :none, stroke: "#000")
    widths = rec.calls_of(:rect).map { |call| call[:fill] }
    stroke = rec.calls_of(:rect).last

    assert_equal [0.667, 0.733, 0.8, 1.0], widths[0].map { |channel| channel.round(3) }
    assert_in_delta(0.067, widths[1][0], 0.001)
    assert_equal 0.267, widths[1][3].round(3)
    assert_equal [0.1, 0.2, 0.3, 1.0], widths[2]
    assert_nil widths[3]
    assert_equal [0.0, 0.0, 0.0, 1.0], stroke[:stroke]
  end

  def test_recording_measure_text_is_a_documented_estimate
    mount(AllPrimitives)
    rec = recording(panel)
    width, height = rec.measure_text("贵州茅台", size: 15)

    assert_operator width, :>, 0
    assert_operator height, :>, 0
    assert_operator rec.measure_text("贵州茅台", size: 30).first, :>, width, "字号变大 → 变宽"
  end

  def test_recording_flags_unsupported_usage
    rec = Citrine::Native::Painter::Recording.new
    rec.text("x", x: 0, y: 0, align: :right) # 没有 width
    rec.text("y", x: 0, y: 0, weight: :heavy)
    rec.text("z", x: 0, y: 0, align: :middle)
    rec.rect(0, 0, 5, 5, fill: "not-a-color")
    rec.rect(0, 0, 4, 4, fill: [200, 40, 60], radius: 99)

    keys = rec.warnings.keys
    assert_includes keys, :align_without_width
    assert_includes keys, [:weight, "heavy"]
    assert_includes keys, [:align, "middle"]
    assert_includes keys, [:color, "not-a-color"]
    assert_includes keys, [:color_range, "[200, 40, 60]"]
    assert_includes keys, [:radius, 99.0]
    assert_match(/0\.\.1/, rec.warnings[[:color_range, "[200, 40, 60]"]],
                 "提醒里说清颜色的 0..1 口径")
  end

  # 绘制期的提醒走 dev_mode 去重输出（Painter 每帧新建，自己 warn 会刷屏）
  class NoisyPainter < Citrine::Component
    def view
      element(:area, ref: :panel, on_draw: ->(panel) { panel.rect(0, 0, 5, 5, fill: "bogus") })
    end
  end

  def test_painter_warnings_are_reported_once_in_dev_mode
    Citrine.dev_mode = true
    component = mount(NoisyPainter)

    _out, err = capture_io { 3.times { backend.fire_draw(area_of(component)) } }

    assert_equal 1, err.scan(/bogus/).size, "同一提醒只输出一次（按 key 去重）"
  end

  def test_painter_warnings_are_silent_outside_dev_mode
    Citrine.dev_mode = false
    component = mount(NoisyPainter)

    _out, err = capture_io { backend.fire_draw(area_of(component)) }

    assert_empty err
  end

  # 设计 2.1 v2 去掉了 on_wheel（libui 的 area 不带滚轮事件）→ 它按"未支持的事件 prop"
  # 走既有提醒口径，而不是假装收到了
  def test_on_wheel_is_reported_as_unsupported
    Citrine.dev_mode = true
    klass = Class.new(Citrine::Component) do
      def view
        element(:area, on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") },
                       on_wheel: ->(event) { event })
      end
    end

    _out, err = capture_io { mount(klass) }

    assert_match(/on_wheel 在原生后端不支持/, err)
  end

  # ── 5b) 面板拿不到空间（P2.1 / SHEETS D2 的坑）──────────
  # libui 的 box 布局里在容器链上逐层拿不到 stretchy 空间的控件会被 Auto Layout 解成 0×0，
  # 而且**不报错**：应用只看到"面板不见了"。注意"没有尺寸来源就 0×0"是**过度概括**（NA-1e）：
  # 单个非 stretchy 面板在 stack 里照样拿到剩余空间（真 GUI 实测 760×544），0×0 出现在
  # "两个非 stretchy 面板互相抢"或"被 label 钉住的嵌套链"里（设计 §5.1 / §5.7.2）。
  # 绘制回调是唯一能观察到真尺寸的地方（宽/高为 0 就是没拿到）。
  def test_area_without_a_size_warns_in_dev_mode
    Citrine.dev_mode = true
    panel = mount_panel

    _out, err = capture_io { backend.fire_draw(panel, width: 0, height: 0) }

    assert_match(/拿到了 0 尺寸/, err)
    assert_match(/flex_grow/, err, "提醒必须给出可操作的下一步")
    assert_match(/嵌套 box/, err, "提示 libui 的嵌套 box 陷阱（D2 的真因）")
  end

  # NA-1d：提示必须对"已经给了 flex_grow 还是被压"的形状也可操作（NA-2 实测：
  # `row(flex_grow: 1) { stack { area(flex_grow: 1) }; stack { area } }` 里面板自己
  # 有 flex_grow，仍被压成 0 宽 → 旧提示"给面板 flex_grow"对这个形状是空转）。
  # 正确判据是"**面板所在的每一层容器**在各自父容器里要有 stretchy 尺寸"。
  def test_starved_area_hint_points_at_the_container_not_only_the_panel
    Citrine.dev_mode = true
    panel = mount_panel

    _out, err = capture_io { backend.fire_draw(panel, width: 0, height: 0) }

    assert_match(/每一层容器/, err, "判据是'所在容器链有没有 stretchy 尺寸'")
    assert_match(/外层/, err, "已有 flex_grow 仍被压时，要指向外层容器")
    refute_match(/每个嵌套 box 都要有一个 stretchy 子控件/, err,
                 "被反例否证的旧规则不许再出现（NA-2 用两个形状证伪）")
  end

  # NA-1d：滚动面板的**真实可见视口**塌陷是旧口径的盲区——Painter 拿到的是声明的
  # 内容尺寸（2000×2000，非 0），于是旧判据（只看 Painter 尺寸）一言不发，
  # 而应用看到的是一块挤扁的面板（SHEETS-2 现场的形状）。
  class ScrollingPanel < Citrine::Component
    def view
      element(:area, ref: :panel, scroll: true, size: [2000, 2000],
                     on_draw: ->(panel) { panel.rect(0, 0, panel.width, panel.height, fill: "#102030") })
    end
  end

  def test_collapsed_scroll_viewport_warns_even_though_painter_has_the_declared_size
    Citrine.dev_mode = true
    component = mount(ScrollingPanel)
    panel = area_of(component)
    backend.set_visible_size(panel, 736, 16) # 真实视口（libui 读 clip view 的真实边界）

    _out, err = capture_io { backend.fire_draw(panel, width: 2000, height: 2000) }

    assert_match(/真实可见视口/, err, "视口塌了必须提醒（Painter 拿到的是声明内容尺寸）")
    assert_match(/736\.0×16\.0/, err, "提醒里给出真实视口尺寸")
    refute_match(/拿到了 0 尺寸/, err, "Painter 尺寸非 0，不该报另一条")
  end

  # NA-1e：滚动面板的 Painter 尺寸是**声明的内容尺寸**，不是控件大小——于是"内容矮"
  # 不代表"控件被挤扁"。反例（NA-2c 复审核对的真 GUI 数）：`scroll: true, size: [2000, 20]`
  # 的横向缩略图条实到 760×544、视口 743×527，是一块健康面板，旧代码却打印
  # "控件被挤成一条：2000.0×20.0"，还把用户引向"容器链/flex_grow"这种无关建议。
  # 判别变量是 **scroll**（问后端的 `area_scrollable?`），不是尺寸数字——所以下面用
  # 同一组 2000×20 做对照：非滚动面板下 Painter 尺寸就是控件 frame，必须照报。
  class StripPair < Citrine::Component
    def view
      stack(gap: 0) do
        element(:area, ref: :strip, scroll: true, size: [2000, 20], on_draw: ->(panel) { paint(panel) })
        element(:area, ref: :plain, scroll: false, on_draw: ->(panel) { paint(panel) })
      end
    end

    def paint(panel) = panel.rect(0, 0, panel.width, panel.height, fill: "#102030")
  end

  def test_short_content_size_is_not_a_squeeze_on_scroll_panels_but_is_on_plain_ones
    Citrine.dev_mode = true
    component = mount(StripPair)
    backend.set_visible_size(component.refs[:strip].handle, 743, 527) # 真 GUI 实测的健康视口

    _out, err = capture_io { backend.fire_draw(component.refs[:strip].handle, width: 2000, height: 20) }

    assert_empty err, "声明的内容尺寸矮（2000×20）不等于控件被挤扁：滚动面板的 Painter 尺寸不是控件 frame"

    _out, err = capture_io { backend.fire_draw(component.refs[:plain].handle, width: 2000, height: 20) }

    assert_match(/控件被挤成一条/, err,
                 "非滚动面板下 Painter 尺寸就是控件 frame，20pt 高必须报（判据②只跳过滚动面板）")
    assert_match(/2000\.0×20\.0/, err)
  end

  def test_healthy_scroll_viewport_does_not_warn
    Citrine.dev_mode = true
    component = mount(ScrollingPanel)
    panel = area_of(component)
    backend.set_visible_size(panel, 736, 528)

    _out, err = capture_io { backend.fire_draw(panel, width: 2000, height: 2000) }

    assert_empty err, "视口正常时不该提醒"
  end

  # NA-1d：**非滚动**面板被挤成细条（NA-2 实测 753×16）——旧口径只看"是不是 0"，
  # 于是这种"挤扁但非 0"的形状一言不发，而用户看到的是一块画不出东西的条。
  # 非滚动面板下 Painter 尺寸就是控件的真实 frame，所以这条判据不需要后端几何。
  def test_squeezed_non_scroll_panel_warns
    Citrine.dev_mode = true
    panel = mount_panel

    _out, err = capture_io { backend.fire_draw(panel, width: 753, height: 16) }

    assert_match(/控件被挤成一条/, err)
    assert_match(/753\.0×16\.0/, err)
    assert_match(/外层/, err, "提示要指向容器链，而不是'给面板自己 flex_grow'")
  end

  # 阈值边界：刚好一行高（24pt）算可用，不提醒——别把正常的窄面板也报出来
  def test_panel_at_the_usable_threshold_does_not_warn
    Citrine.dev_mode = true
    panel = mount_panel

    _out, err = capture_io { backend.fire_draw(panel, width: 760, height: 24) }

    assert_empty err
  end

  def test_viewport_check_is_optional_for_backends_without_geometry
    Citrine.dev_mode = true
    component = mount(ScrollingPanel)
    panel = area_of(component)

    # 桩后端默认不给视口（nil）→ 提醒退回"只看 Painter 尺寸"的老口径，不误报
    _out, err = capture_io { backend.fire_draw(panel, width: 2000, height: 2000) }

    assert_nil backend.area_visible_size(panel)
    assert_empty err
  end

  def test_area_size_warning_is_emitted_once_per_panel
    Citrine.dev_mode = true
    panel = mount_panel

    _out, err = capture_io { 3.times { backend.fire_draw(panel, width: 0, height: 0) } }

    assert_equal 1, err.scan(/拿到了 0 尺寸/).size, "同一面板只提醒一次（绘制每帧都会跑）"
  end

  def test_area_size_warning_is_silent_outside_dev_mode
    Citrine.dev_mode = false
    panel = mount_panel

    _out, err = capture_io { backend.fire_draw(panel, width: 0, height: 0) }

    assert_empty err
  end

  def test_normal_size_does_not_warn
    Citrine.dev_mode = true
    panel = mount_panel

    _out, err = capture_io { backend.fire_draw(panel) }

    refute_match(/拿到了 0 尺寸/, err)
  end

  # ── 6) 定时器（设计 2.5）────────────────────────────────

  def wait_until(timeout: 2.0)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    yield
  end

  def teardown
    # 活动后端是全局的（Timer 的跨线程通道）：测试之间不要互相借
    Citrine::Native.active_widgets = nil
    super
  end

  # 定时器靠活动后端把回调排回主线程（Citrine::Native.active_widgets，由 Renderer 登记），
  # 所以不挂组件的定时器测试要先建一个渲染器
  def active_backend
    Citrine::Native::Renderer.new(widgets: @backend)
    @backend
  end

  def test_every_ticks_repeatedly_and_stops
    active_backend
    ticks = []
    timer = Citrine::Native.every(10) { ticks << :tick }
    begin
      assert wait_until { ticks.size >= 2 }, "周期定时器该反复触发"
      timer.stop
      stopped_at = ticks.size
      sleep 0.05
      assert_equal stopped_at, ticks.size, "stop 之后不该再有 tick"
      assert timer.stopped?
      refute timer.running?
      assert_same timer, timer.stop, "stop 幂等"
    ensure
      timer.stop
    end
  end

  def test_after_fires_once
    active_backend
    ticks = []
    timer = Citrine::Native.after(10) { ticks << :tick }
    begin
      assert wait_until { ticks.size >= 1 }, "一次性定时器该触发"
      sleep 0.05
      assert_equal 1, ticks.size
    ensure
      timer.stop
    end
  end

  def test_stop_before_the_first_tick_cancels_it
    active_backend
    ticks = []
    timer = Citrine::Native.every(200) { ticks << :tick }
    timer.stop
    sleep 0.05

    assert_empty ticks
  end

  def test_timer_requires_a_block_and_a_positive_interval
    active_backend
    assert_raises(ArgumentError) { Citrine::Native.every(10) }
    assert_raises(ArgumentError) { Citrine::Native.every(0) { :noop } }
  end

  # NA-1d（NA-2 的 N1）：定时器每次到点都排一个新闭包，若走 queue_main（闭包常驻，
  # 见 widgets/libui.rb 的 @closures），就是"每个 tick 漏一个闭包"——真后端上无界增长
  # （实测 50ms 定时器 5 秒 closures/ticks = 54/52），而两个移植 demo 都在用 every。
  # 桩后端不持有闭包，但"走哪个队列槽"是后端无关的语义，所以在桩上就锁住。
  def test_timer_ticks_do_not_queue_resident_closures
    active_backend
    ticks = []
    timer = Citrine::Native.every(5) { ticks << :tick }
    begin
      assert wait_until { ticks.size >= 4 }, "定时器该反复触发"
      assert_operator @backend.queue_log.count(:transient), :>=, 4, "每个 tick 一次一次性排队"
      assert_equal 0, @backend.queue_log.count(:resident),
                   "定时器不许排常驻闭包（那就是每 tick 漏一个）"
    ensure
      timer.stop
    end
  end

  # NA-1d：句柄只如实转达后端的答复，不自己编造成功（后端说做不到 → false）
  def test_area_handle_focus_relays_the_backend_answer
    component = mount(FullPanel)
    handle = component.refs[:panel]

    @backend.define_singleton_method(:area_focus) { |_area| false }
    refute handle.focus, "后端说做不到时必须如实返回 false"

    @backend.define_singleton_method(:area_focus) { |_area| true }
    assert handle.focus
  end

  # 回调里的异常不中断应用（与控件回调同口径）：周期定时器继续跑，错误打到 stderr
  def test_timer_callback_errors_do_not_kill_the_timer
    active_backend
    ticks = []
    timer = nil
    _out, err = capture_io do
      timer = Citrine::Native.every(10) do
        ticks << :tick
        raise "boom"
      end
      wait_until { ticks.size >= 2 }
    end
    timer.stop

    assert_operator ticks.size, :>=, 2
    assert_match(/定时器回调抛出 RuntimeError: boom/, err)
  end

  # 卸载时应用在 on_unmount 里 #stop：之后再改信号/过时间都不该再响
  class TickingPanel < Citrine::Component
    state :ticks, default: 0

    attr_reader :timer

    def view
      element(:area, ref: :panel, on_draw: ->(panel) { panel.text("t#{ticks}", x: 0, y: 0) })
    end

    on_mount { @timer = Citrine::Native.every(10) { self.ticks += 1 } }
    on_unmount { @timer.stop }
  end

  def test_timer_is_stopped_by_on_unmount
    component = mount(TickingPanel)
    panel = area_of(component)
    assert wait_until { component.ticks >= 2 }, "心跳该跑起来"

    Citrine.unmount(component)
    ticks_at_unmount = component.ticks
    sleep 0.08

    assert component.timer.stopped?, "on_unmount 里 stop"
    assert_equal ticks_at_unmount, component.ticks, "卸载后不该再被定时器叫醒"
    assert panel.destroyed?, "面板随组件销毁"
  end
end
