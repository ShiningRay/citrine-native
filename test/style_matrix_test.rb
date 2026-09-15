# frozen_string_literal: true

require_relative "test_helper"

# 样式能力矩阵（L1）与 area 的视觉底板（L2）：
#   · 矩阵自洽（状态合法、area 消费组是 :painted 的子集、未登记键有兜底）
#   · :mapped 的落地（padding → 容器内边距、flex → stretchy）
#   · :painted 的行为（area 自动画底板、非 area 提醒、文字键提醒）
#   · 提醒按三档分开说清（为什么 / 怎么办 / 去哪看）
class StyleMatrixTest < NativeTest
  Matrix = Citrine::Native::StyleMatrix

  # hex → 归一化通道（Painter 的 color_of 口径：0..1 浮点 + alpha）
  def rgba(hex)
    bytes = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
    [bytes[0] / 255.0, bytes[1] / 255.0, bytes[2] / 255.0, bytes[3] ? bytes[3] / 255.0 : 1.0]
  end

  def stretchy?(widget) = widget.instance_variable_get(:@stretchy) == true

  # ── 1) 矩阵自洽 ─────────────────────────────────────────────

  def test_every_registered_entry_has_a_valid_status
    refute_empty Matrix::TABLE
    Matrix::TABLE.each do |key, entry|
      assert_includes Matrix::STATUSES, entry.status, "#{key} 的状态非法：#{entry.status.inspect}"
      assert_kind_of Symbol, key
    end
  end

  def test_area_consumed_keys_are_a_painted_subset
    # 视觉底板就这几个：多进来一个都要在渲染器里有对应实现
    assert_equal %i[background border border_color border_radius border_width],
                 Matrix.area_keys.sort
    Matrix.area_keys.each do |key|
      assert_equal Matrix::PAINTED, Matrix.status(key),
                   "#{key} 被 area 自动消费，状态必须是 :painted"
    end
  end

  def test_unknown_key_falls_back_to_ignored
    entry = Matrix.entry(:not_a_real_style_key)

    assert_equal Matrix::IGNORED, entry.status
    assert_match(/未在矩阵中登记/, entry.note)
    refute Matrix.registered?(:not_a_real_style_key)
  end

  def test_mapped_keys_are_the_ones_the_renderer_lands
    # 登记为 :mapped 的键都在渲染器里有落地实现：方向由 stack/row 合成，
    # gap/padding* 走 apply_padding，flex/flex_grow 走 stretchy?
    assert_equal %i[display flex_direction gap padding padding_top padding_right
                    padding_bottom padding_left flex_grow flex].sort,
                 Matrix.mapped_keys.sort
  end

  # ── 2) :mapped 的落地 ───────────────────────────────────────

  class Padded < Citrine::Component
    def view
      stack(style: { padding: 12 }) { label { "x" } }
    end
  end

  class PaddedZero < Citrine::Component
    def view
      stack(style: { padding: 0 }) { label { "x" } }
    end
  end

  class FlexShorthand < Citrine::Component
    def view
      stack { label(style: { flex: "1 1 auto" }) { "x" } }
    end
  end

  class FlexNone < Citrine::Component
    def view
      stack { label(style: { flex: "none" }) { "x" } }
    end
  end

  # container 是框架的根容器（renderer 的 setup_root 建的），组件的 stack 是它的第一个孩子
  def component_box = container.children.first

  def test_padding_maps_to_container_padded
    mount(Padded)

    assert component_box.padded, "padding > 0 应把容器设成 padded"
  end

  def test_zero_padding_leaves_container_unpadded
    mount(PaddedZero)

    refute component_box.padded
  end

  def test_flex_shorthand_stretches_like_flex_grow
    mount(FlexShorthand)

    assert stretchy?(find(kind: :label)), "flex: \"1 1 auto\" 应等价于 flex_grow: 1"
  end

  def test_flex_none_does_not_stretch
    mount(FlexNone)

    refute stretchy?(find(kind: :label))
  end

  # ── 3) :painted —— area 自动画底板（L2）────────────────────

  class StyledPanel < Citrine::Component
    def view
      element(:area, ref: :panel, size: [120, 80], scroll: true,
                     style: { background: "#101827", border: "2px solid #1e2b45", border_radius: 6 },
                     on_draw: ->(panel) { panel.rect(4, 4, 10, 10, fill: "#ffffff") })
    end
  end

  def styled_panel
    component = mount(StyledPanel)
    [component.refs[:panel].handle, component]
  end

  def test_area_paints_style_backboard_before_content
    panel, = styled_panel
    rec = backend.fire_draw(panel)

    first = rec.calls.first
    assert_equal :rect, first.first, "底板必须是第一个图元（内容画在它上面）"
    args = first.last
    assert_equal [0.0, 0.0, 120.0, 80.0], [args[:x], args[:y], args[:w], args[:h]]
    assert_equal rgba("#101827"), args[:fill]
    assert_equal rgba("#1e2b45"), args[:stroke], "border 简写里的颜色"
    assert_equal 2.0, args[:line_width]
    assert_equal 6.0, args[:radius]
    assert_equal %i[rect rect], rec.types, "应用自己的绘制跟在底板后面"
  end

  def test_area_style_is_reread_every_draw
    # 样式走 resolve_style（每帧现读）：Proc 样式改值后下一帧的底板跟着变
    klass = Class.new(Citrine::Component) do
      state :bg, default: "#101827"

      def view
        stack do
          element(:area, ref: :panel, size: [40, 40], scroll: true,
                         style: -> { { background: bg } },
                         on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#ffffff") })
        end
      end
    end
    component = mount(klass)
    panel = component.refs[:panel].handle

    assert_equal rgba("#101827"), backend.fire_draw(panel).calls.first.last[:fill]

    component.bg = "#1e2b45"
    assert_equal rgba("#1e2b45"), backend.fire_draw(panel).calls.first.last[:fill]
  end

  class PlainPanel < Citrine::Component
    def view
      element(:area, ref: :panel, size: [40, 40], scroll: true,
                     on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#ffffff") })
    end
  end

  def test_area_without_visual_style_paints_nothing_extra
    component = mount(PlainPanel)
    rec = backend.fire_draw(component.refs[:panel].handle)

    assert_equal %i[rect], rec.types, "没写视觉样式时框架不该多画一笔"
  end

  class BorderNone < Citrine::Component
    def view
      element(:area, ref: :panel, size: [40, 40], scroll: true,
                     style: { background: "#101827", border: "none" },
                     on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#ffffff") })
    end
  end

  def test_border_none_draws_no_stroke
    component = mount(BorderNone)
    rec = backend.fire_draw(component.refs[:panel].handle)

    assert_nil rec.calls.first.last[:stroke]
    assert_equal rgba("#101827"), rec.calls.first.last[:fill]
  end

  class BorderColorOnly < Citrine::Component
    def view
      element(:area, ref: :panel, size: [40, 40], scroll: true,
                     style: { border_color: "#1e2b45" },
                     on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#ffffff") })
    end
  end

  def test_border_color_only_means_one_pixel_and_no_fill
    component = mount(BorderColorOnly)
    args = backend.fire_draw(component.refs[:panel].handle).calls.first.last

    assert_equal rgba("#1e2b45"), args[:stroke]
    assert_equal 1.0, args[:line_width]
    assert_nil args[:fill], "只写了描边 → 底板不填充"
    assert_equal 0.0, args[:radius]
  end

  class DashedBorder < Citrine::Component
    def view
      element(:area, ref: :panel, size: [40, 40], scroll: true,
                     style: { border: "1px dashed #1e2b45" },
                     on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#ffffff") })
    end
  end

  def test_dashed_border_warns_and_still_draws_solid
    Citrine.dev_mode = true
    component = mount(DashedBorder)
    panel = component.refs[:panel].handle
    # border 的解析在**绘制期**（每帧现读样式）→ 提醒也打在那里
    rec = nil
    _out, err = capture_io { rec = backend.fire_draw(panel) }

    assert_match(/只画实线/, err)
    assert_equal rgba("#1e2b45"), rec.calls.first.last[:stroke]
  end

  # ── 4) 提醒分档 ─────────────────────────────────────────────

  class WarnMix < Citrine::Component
    def view
      stack(style: { box_shadow: "0 1px 2px #000" }) do
        label(style: { font_size: 14 }) { "x" }
      end
    end
  end

  def test_warnings_are_split_by_matrix_bucket
    Citrine.dev_mode = true
    _out, err = capture_io { mount(WarnMix) }

    assert_match(/样式键 :box_shadow 在原生后端没有对应概念/, err)
    assert_match(/样式键 :font_size 在原生后端不支持自动映射（需要自绘）/, err)
    assert_match(/painter\.text/, err, "自绘类提醒要给出可操作的做法")
    assert_match(/docs\/design\/style-matrix\.md/, err)
  end

  def test_mapped_keys_are_silent_in_dev_mode
    Citrine.dev_mode = true
    klass = Class.new(Citrine::Component) do
      def view
        stack(style: { gap: 8, padding: 4, flex: 1 }) { label { "x" } }
      end
    end

    _out, err = capture_io { mount(klass) }

    refute_match(/样式键 :(gap|padding|flex)\b/, err)
  end
end
