# frozen_string_literal: true

require_relative "test_helper"

# 应用入口与生命周期（GOALS 4.4）：窗口创建/显示、主循环、有序拆解。
# 真窗口的起停由 libui_backend_test.rb 的冒烟脚本覆盖（CI 不开窗）。
class AppTest < Minitest::Test
  def setup
    Citrine.dev_mode = false
    @backend = Citrine::Native::Widgets::Memory.new
  end

  def teardown
    Citrine.dev_mode = false
  end

  def test_window_is_created_from_run_options_and_shown
    app = Citrine::Native.start(TestCounter, widgets: @backend,
                                            title: "计数器", width: 400, height: 300)

    assert_equal({ title: "计数器", width: 400, height: 300, margined: true },
                 @backend.window_options(app.window))
    assert @backend.shown?(app.window)
  ensure
    app&.teardown
  end

  # 设计 2.3 的实测结论：`uiControlShow` 之后窗口**不是 key window**（firstResponder 为 nil）
  # → 必须激活应用，否则"窗口看得见、键盘用不了"
  def test_window_is_activated_after_show_by_default
    app = Citrine::Native.start(TestCounter, widgets: @backend)

    assert @backend.activated?(app.window), "显示窗口后要激活应用（macOS 的键盘前提）"
  ensure
    app&.teardown
  end

  def test_activation_can_be_disabled
    app = Citrine::Native.start(TestCounter, widgets: @backend, activate: false)

    refute @backend.activated?(app.window), "activate: false 时不抢用户焦点"
  ensure
    app&.teardown
  end

  def test_run_blocks_in_main_loop_until_window_closes
    observed = nil
    @backend.on_main_loop do |backend|
      window = backend.window
      button = backend.find(window, kind: :button)
      3.times { button.fire(:click) }
      observed = backend.find(window, kind: :label).text
      backend.fire_closing(window)
    end

    app = Citrine::Native.run(TestCounter, widgets: @backend)

    assert_equal "计数：3", observed
    assert @backend.quit?, "关窗后主循环应收到 quit"
    assert_empty @backend.live_widgets, "拆解后控件（含窗口）应全部销毁"
  ensure
    app&.teardown
  end

  def test_native_run_enables_dev_mode_by_default
    Citrine.dev_mode = false
    @backend.on_main_loop { |backend| backend.fire_closing(backend.window) }

    Citrine::Native.run(TestCounter, widgets: @backend)

    assert Citrine.dev_mode?, "原生运行时默认开开发期提醒（脚本即应用，没有构建管线）"
  end

  def test_native_run_can_disable_dev_mode
    @backend.on_main_loop { |backend| backend.fire_closing(backend.window) }

    Citrine::Native.run(TestCounter, widgets: @backend, dev_mode: false)

    refute Citrine.dev_mode?
  end

  class Tracked < Citrine::Component
    class << self
      attr_accessor :unmounts, :window_widget, :window_alive_at_unmount, :state_at_unmount
    end

    state :count, default: 0

    def view
      stack { label { "计数：#{count}" } }
    end

    # 卸载钩子跑在"组件子树已拆、窗口还在"的窗口期
    on_unmount do
      self.class.unmounts += 1
      self.class.window_alive_at_unmount = !self.class.window_widget.destroyed?
      self.class.state_at_unmount = count
    end
  end

  def test_teardown_unmounts_component_before_destroying_window_and_is_idempotent
    Tracked.unmounts = 0
    Tracked.window_alive_at_unmount = false
    Tracked.state_at_unmount = nil
    app = Citrine::Native.start(Tracked, widgets: @backend)
    Tracked.window_widget = app.window

    app.teardown
    app.teardown # 幂等：重复拆解不重复跑钩子、不重复销毁

    assert_equal 1, Tracked.unmounts
    assert Tracked.window_alive_at_unmount, "窗口必须活到组件卸载之后才销毁"
    assert_equal 0, Tracked.state_at_unmount, "卸载钩子里还能读到状态（状态没被提前拆掉）"
    assert_empty @backend.live_widgets
  end

  class Broken < Citrine::Component
    def view
      stack { table { "x" } }
    end
  end

  def test_failed_mount_still_destroys_the_window
    app = Citrine::Native::App.new(Broken, widgets: @backend)

    assert_raises(Citrine::Native::UnsupportedElementError) { app.setup }
    app.teardown

    assert_empty @backend.live_widgets, "挂载失败也不该把半成品控件树漏在内存里"
  end

  def test_native_start_accepts_component_class_and_instance
    app = Citrine::Native.start(TestCounter, widgets: @backend)
    assert_instance_of TestCounter, app.component

    instance = TestCounter.new
    other = Citrine::Native.start(instance, widgets: Citrine::Native::Widgets::Memory.new)
    assert_same instance, other.component
  ensure
    app&.teardown
    other&.teardown
  end

  def test_quit_stops_the_main_loop
    @backend.on_main_loop { |backend| backend.quit }
    app = Citrine::Native.run(TestCounter, widgets: @backend)

    assert @backend.quit?
  ensure
    app&.teardown
  end
end
