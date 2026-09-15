# frozen_string_literal: true

# 单测公共入口：本 gem 的渲染语义测试全部跑在 Memory 桩后端上（GOALS 风险 3：
# CI 不能开真窗口）。真控件的行为由 test/libui_backend_test.rb 以子进程冒烟覆盖。
require "minitest/autorun"
require "citrine-native"

# 渲染语义测试基类：一套组件 + 一个桩后端 + 一棵可断言的控件树。
#
# 每个用例一个渲染器实例（基类约定：一页一渲染器——活动渲染器是全局的，
# 多根挂载必须换实例）。
class NativeTest < Minitest::Test
  attr_reader :backend, :renderer, :root

  def setup
    @backend = Citrine::Native::Widgets::Memory.new
    @mounted = []
    # 默认关掉开发期提醒（噪音会淹没 test 输出）；专门断言提醒的用例自己打开
    Citrine.dev_mode = false
  end

  def teardown
    @mounted.each { |component| Citrine.unmount(component) }
    @mounted.clear
    @root = nil
    Citrine.dev_mode = false
  end

  # 挂载组件（类或实例），返回组件实例
  def mount(component, **options)
    @renderer = Citrine::Native::Renderer.new(widgets: @backend)
    instance = component.is_a?(Class) ? component.new : component
    @mounted << instance
    @root = @renderer.mount_component(instance, { title: "test" }.merge(options))
    instance
  end

  def container = @root.dom
  def window = @renderer.window

  # 控件树查询（桩后端提供的诊断 API）
  def find(kind:, text: nil) = @backend.find(container, kind: kind, text: text)
  def find_all(kind:) = @backend.find_all(container, kind: kind)
  def texts(kind:) = find_all(kind: kind).map { |w| w.text.to_s }
  def tree = @backend.tree(container)
  def live_widgets = @backend.live_widgets

  def click(button) = button.fire(:click)

  # 断言控件树结构（可读形式）：["box column", ["label", "…"], …]
  def assert_tree(expected, message = nil)
    assert_equal expected, tree, message
  end
end

# ── 测试用组件 ──────────────────────────────────────────────

# N1 验收组件：点击精确 +1（对齐主仓 M0 Spike A 的口径）
class TestCounter < Citrine::Component
  state :count, default: 0

  def view
    stack(gap: 8) do
      label { "计数：#{count}" }
      button(on_click: -> { self.count += 1 }) { "点我 +1" }
    end
  end
end
