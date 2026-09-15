# frozen_string_literal: true

require_relative "test_helper"
require "fiddle"

# 平台能力矩阵（backlog E5 的可落地部分）：把"矩阵里写的降级行为"变成**机器校验**。
#
# 这一组只覆盖可以在无窗口环境断言的部分——ObjcBridge（macOS 直通桥）的可用性与
# "不可用时如实返回 false"的口径。矩阵里其余条目（控件天然高度、布局严格性、
# 信号集合…）依赖真控件几何或进程级行为，靠桩测断言不了，继续由文档 + 冒烟兜住
# （见 docs/design/platform-matrix.md 第五节"约定"）。
#
# 为什么值得单独锁：这些降级点散在桥里（activate / window_key? / focus / rect_of），
# 合并成一条"available? 为假就整桥降级"的语义。有人新增桥能力却忘了在非 macOS 上
# 走 available? 守卫时，这里会红。
class PlatformMatrixTest < Minitest::Test
  MACOS = RbConfig::CONFIG["host_os"].match?(/darwin/i)

  # libui 后端是懒加载的（Widgets.default 里 require）；测试自己要拿到 ObjcBridge，
  # 就得显式加载——环境没有 libui 时整体跳过（CI 的 Linux 机器属于这种）
  begin
    require "libui"
    require_relative "../lib/citrine/native/widgets/libui"
    Libui = Citrine::Native::Widgets::Libui
  rescue LoadError => e
    Libui = nil
    LOAD_ERROR = e.message
  end

  MATRIX_DOC = File.expand_path("../docs/design/platform-matrix.md", __dir__)

  def setup
    skip "环境没有 libui：#{LOAD_ERROR}" if Libui.nil?
  end

  def bridge = Libui::ObjcBridge.new

  # ── 桥的可用性 ──────────────────────────────────────────

  def test_bridge_availability_matches_the_platform
    if MACOS
      assert bridge.available?, "macOS 上 libobjc 应当可用（平台能力矩阵第一节）"
    else
      refute bridge.available?, "非 macOS 上 ObjcBridge 必须如实报告不可用"
    end
  end

  # 桥的每个能力在"不可用"时都要如实返回 false / nil，而不是抛异常或假装成功
  def test_unavailable_bridge_degrades_honestly
    skip "macOS：桥可用，本用例只验非 macOS 的降级路径" if MACOS

    b = bridge
    fake = Fiddle::Pointer.new(0x1234)

    assert_equal false, b.activate, "activate 在非 macOS 上如实返回 false"
    assert_equal false, b.window_key?, "window_key? 在非 macOS 上如实返回 false"
    assert_equal false, b.focus(fake), "focus 在非 macOS 上如实返回 false（不假装成功）"
    assert_nil b.rect_of(fake, "visibleRect"), "几何读取拿不到就返回 nil（调用方回退 Clip*）"
    assert_nil b.scrolling_document_view(fake), "滚动面板视图拿不到就返回 nil"
  end

  # 空句柄（0）不该被当成"能读"：桥不可用时也不该崩
  def test_bridge_handles_null_pointer
    b = bridge

    assert_equal false, b.focus(nil) if !MACOS
    assert_equal false, b.focus(Fiddle::Pointer.new(0)) unless MACOS
  end

  # ── 文档 ↔ 代码对拍（与 element_event_matrix_test 同一手法）────────

  def test_matrix_doc_records_the_capabilities_this_bridge_covers
    doc = File.read(MATRIX_DOC)
    # 桥覆盖的降级点：在矩阵文档里必须能找到对应说法（改了名字/删了行都会红）
    %w[window_is_key AreaHandle#focus window_activate clip_rect].each do |token|
      assert_includes doc, token, "平台能力矩阵没提到 #{token}（补 docs/design/platform-matrix.md）"
    end
  end

  # 桥的每个能力都走同一条守卫（`available?`），适配层的入口只是转达：
  # 有人加桥能力却忘了守卫时，这里会红
  def test_bridge_methods_share_the_availability_guard
    source = File.read(File.expand_path("../lib/citrine/native/widgets/libui.rb", __dir__))
    guards = source.scan(/^\s+return (?:false|nil) unless available\?/).size

    assert_operator guards, :>=, 5,
                    "ObjcBridge 的能力方法应当逐个经 available? 守卫（平台能力矩阵第一节）"
    %w[def activate def focus def window_key? def rect_of def scrolling_document_view].each do |signature|
      assert_includes source, signature, "适配层缺少 #{signature}（平台降级入口）"
    end
  end
end
