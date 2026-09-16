# frozen_string_literal: true

require "minitest/autorun"
require "citrine-native"

# 事件层错误边界：两后端同口径的"只报不抛"契约（Fiddle 闭包 / GTK 信号块
# 都不能让异常进平台事件栈）。Renderer 的各 dispatch 入口包 guard，行为
# 由这里的单测锁住。
class EventGuardTest < Minitest::Test
  def test_guard_returns_block_value
    assert_equal 42, Citrine::Native::EventGuard.guard("回调") { 42 }
  end

  def test_guard_swallows_and_reports_exceptions
    err = capture_io do
      assert_nil Citrine::Native::EventGuard.guard("按钮的 on_click") { raise "boom" }
    end[1]

    assert_match(/按钮的 on_click 抛出 RuntimeError: boom/, err)
    assert_match(/event_guard_test/, err)   # 栈帧进报告（首 8 帧）
  end

  def test_report_keeps_formatting_for_callers_that_rescue_themselves
    err = capture_io do
      Citrine::Native::EventGuard.report(RuntimeError.new("x"), "键盘派发")
    end[1]

    assert_match(/\[citrine-native\] 键盘派发 抛出 RuntimeError: x/, err)
  end
end
