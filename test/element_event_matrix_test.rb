# frozen_string_literal: true

require_relative "test_helper"

# 元素/事件支持矩阵（N4）的机器可校验部分：
#   · 核心元素词表里每个"原生不支持"的标签都必须有替代建议（否则报错没有出路）
#   · 每个受支持元素声明的事件面与适配层能力一致（不声明支持却收不到、或收得到却没声明）
#   · 未支持的事件 prop 在 dev_mode 下有提醒（不静默）
#   · 窗口级快捷键只有一个入口（window_key 经聚焦面板转发）
#
# 矩阵的散文版见 docs/design/element-event-matrix.md：改这里就要同步改那里。
class ElementEventMatrixTest < NativeTest
  Renderer = Citrine::Native::Renderer

  # 核心知道的元素词表（Component::ELEMENT_TAGS）；本仓支持的是 ELEMENTS 那几个
  def core_tags = Citrine::Component::ELEMENT_TAGS
  def supported_elements = Renderer::ELEMENTS.keys

  # ── 元素面 ────────────────────────────────────────────────

  def test_every_unsupported_core_element_has_a_replacement_hint
    missing = core_tags - supported_elements - Renderer::ELEMENT_HINTS.keys

    assert_empty missing, "这些核心元素既没被支持、也没有替代建议（报错会没有出路）：#{missing.inspect}"
  end

  def test_unsupported_element_error_carries_the_hint
    klass = Class.new(Citrine::Component) do
      def view
        element(:tr) { label { "x" } }
      end
    end

    error = assert_raises(Citrine::Native::UnsupportedElementError) { mount(klass) }

    assert_match(/tr/, error.message)
    assert_match(/自绘/, error.message, "报错要给出替代路径")
  end

  def test_hint_table_only_mentions_unimplemented_core_elements
    stray = Renderer::ELEMENT_HINTS.keys - core_tags - supported_elements

    assert_empty stray, "提示表里有核心词表之外（或已支持）的键：#{stray.inspect}"
  end

  # ── 事件面 ────────────────────────────────────────────────

  # 核心的事件词表：DOM 渲染器的 EVENT_DEFS + 组件级 on_change / on_enter
  # （生命周期 on_mount / on_unmount 是宏、window_key 是类宏，不在这张表里，见矩阵文档）
  CORE_EVENT_PROPS = %i[
    on_click on_focus on_blur on_key on_key_up on_dblclick on_contextmenu
    on_mouse_enter on_mouse_leave on_mouse_down on_mouse_up on_wheel on_scroll
    on_submit on_paste on_touch_start on_touch_move on_touch_end
    on_pointer_down on_pointer_move on_pointer_up
    on_change on_enter
  ].freeze

  # 原生侧在核心词表之外的冻结事件（设计 2.1 的 area 接口）：自绘面板专属
  NATIVE_EVENT_EXTENSIONS = %i[on_draw on_mouse_move].freeze

  MATRIX_DOC = File.expand_path("../docs/design/element-event-matrix.md", __dir__)

  def native_event_props = Renderer::SUPPORTED_EVENTS.values.flatten.uniq

  def test_supported_events_are_core_vocabulary_or_documented_extensions
    unknown = native_event_props - CORE_EVENT_PROPS - NATIVE_EVENT_EXTENSIONS

    assert_empty unknown, "这些事件既不在核心词表、也不在原生扩展清单里：#{unknown.inspect}"
  end

  # N4 的硬要求：**未支持的事件必须在矩阵文档里有记录**（新事件出现时先分类，再决定实现）
  def test_every_unsupported_core_event_is_recorded_in_the_matrix_doc
    gaps = CORE_EVENT_PROPS - native_event_props
    doc = File.read(MATRIX_DOC)
    unrecorded = gaps.reject { |prop| doc.include?(prop.to_s) }

    assert_empty unrecorded,
                 "矩阵文档没提到这些未支持事件：#{unrecorded.inspect}（补 docs/design/element-event-matrix.md）"
  end

  def test_unsupported_event_prop_warns_in_dev_mode
    Citrine.dev_mode = true
    klass = Class.new(Citrine::Component) do
      def view
        stack { label(on_key: { "Enter" => :noop }) { "x" } }
      end
    end

    _out, err = capture_io { mount(klass) }

    assert_match(/on_key/, err)
    assert_match(/没有对应概念|不支持/, err)
  end

  def test_supported_events_do_not_warn_in_dev_mode
    Citrine.dev_mode = true
    klass = Class.new(Citrine::Component) do
      state :text, default: ""

      def view
        stack do
          button(on_click: -> { self.text = "x" }) { "go" }
          text_input(value: -> { text }, on_change: ->(value) { self.text = value })
          check_box(checked: -> { false }, on_change: ->(_checked) {})
          element(:area, size: [10, 10], scroll: true,
                         on_draw: ->(panel) { panel.rect(0, 0, 1, 1, fill: "#fff") })
        end
      end
    end

    _out, err = capture_io { mount(klass) }

    refute_match(/事件/, err, "声明支持的事件不该被提醒")
  end

  # area 的事件面就是设计文档冻结的那六个（多一个都要有实现与文档）
  def test_area_event_surface_is_frozen
    assert_equal %i[on_draw on_click on_mouse_down on_mouse_up on_mouse_move on_key].sort,
                 Renderer::SUPPORTED_EVENTS[:area].sort
  end
end
