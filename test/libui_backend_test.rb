# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

# 真控件冒烟（GOALS N1 验收 / 风险 3）：渲染语义测试跑桩后端，这里跑一次
# **真 libui** 的后端，验证三件桩测不出来的事：
#   1. 真控件的创建/销毁/重排链路不崩（libui 撞错会 abort 进程）
#   2. 点击 → 回调 → Signal → Effect → label_set_text 在真控件上精确 +1
#   3. 有序拆解后 uiUninit 不报泄漏（既没漏控件，也没 double free）
#
# 场景脚本放在子进程里跑：libui 的 bug 检查会让进程 abort（exit 133），
# 放在测试进程内会把整个 rake test 带崩，真因反而看不出来。
class LibuiBackendTest < Minitest::Test
  SCENARIO = File.expand_path("support/libui_scenario.rb", __dir__)

  def test_real_widget_scenario_runs_clean
    out, err, status = run_scenario

    if out.include?("LIBUI_UNAVAILABLE")
      skip "环境无可用的 libui/GUI：#{out.lines.first.strip}"
    end

    assert_equal 0, status.exitstatus, "冒烟脚本非零退出：\n#{out}\n#{err}"
    assert_match(/SMOKE_OK/, out)
    refute_match(/^FAIL/, out)
    refute_match(/You have a bug/, err, "libui 报了泄漏/double free")
    refute_match(/leaked/i, err)
  end

  def test_real_widget_scenario_has_no_warnings_on_stderr
    out, err, = run_scenario
    skip "环境无可用的 libui/GUI" if out.include?("LIBUI_UNAVAILABLE")

    assert_empty err, "真控件路径不该往 stderr 写东西（泄漏警告会在这里露头）"
  end

  # GUI 模式（真窗口 + 真主循环）默认不跑：CI 无法开窗，且窗口会闪现。
  # 需要时 CITRINE_NATIVE_GUI=1 bundle exec rake test
  def test_gui_smoke_is_opt_in
    skip "未开启 CITRINE_NATIVE_GUI" unless ENV["CITRINE_NATIVE_GUI"] == "1"

    out, err, status = run_scenario("--gui")

    skip "环境无可用的 GUI：#{out.lines.first.strip}" if out.include?("LIBUI_UNAVAILABLE")
    assert_equal 0, status.exitstatus, "GUI 冒烟失败：\n#{out}\n#{err}"
    assert_match(/SMOKE_OK/, out)
    assert_match(/主循环下的点击计数/, out)
    # 绘制期的异常被适配层的 safe() 吞掉后只打 stderr（不让它穿过 Fiddle 栈），
    # 所以"stderr 干净"是"真绘制路径没抛异常"的唯一机器可验证形式（L2 的圆角
    # 底板就走这条路径：uiDrawPath 的 arc 只有真后端有）
    assert_empty err, "GUI 绘制路径不该往 stderr 写东西"
  end

  private

  def run_scenario(*args)
    Open3.capture3(RbConfig.ruby, SCENARIO, *args)
  end
end
