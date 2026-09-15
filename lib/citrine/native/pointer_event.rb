# frozen_string_literal: true

require "citrine"

module Citrine
  module Native
    # 面板指针事件（平台无关视图，设计 2.3）：适配层把 libui 的
    # uiAreaMouseEvent（或桩后端喂进来的等价数据）交给渲染器，渲染器归一成它。
    #
    # 为什么要包装：与 DOM / Canvas 侧同一口径——组件代码不混平台原生对象，
    # CRuby 也能单测；命中测试由应用负责（面板是矩形，应用知道自己的布局，
    # 与 canvas 后端的 @hits 反查同思路）。
    #
    # type 的取值（设计 2.3）："click" / "mouse_down" / "mouse_up" / "mouse_move"。
    # **没有 "wheel"**：libui 的 uiAreaHandler 不带滚轮事件（设计 2.2 的说明），
    # 要滚动就用 scroll: true 的滚动面板 + AreaHandle#scroll_to。
    # modifiers 是 {shift:, ctrl:, alt:, meta:}。
    class PointerEvent < Citrine::Event
      TYPES = %w[click mouse_down mouse_up mouse_move].freeze

      attr_reader :x, :y, :modifiers, :button

      def initialize(type, x: 0, y: 0, button: 1, modifiers: nil, raw: nil)
        super(type, raw: raw)
        @x = x.to_f
        @y = y.to_f
        @button = button
        @modifiers = modifiers || {}
      end

      # 面板本地坐标（左上角原点）——鼠标位置
      def position = [@x, @y]

      def shift? = @modifiers[:shift] == true
      def ctrl?  = @modifiers[:ctrl] == true
      def alt?   = @modifiers[:alt] == true
      # ⌘ / Ctrl 等价判断：与 KeyEvent#command? 同口径
      def meta?  = @modifiers[:meta] == true
      def command? = meta? || ctrl?

      # 左键（libui 的按钮编号：1 左 / 2 中 / 3 右）
      def left? = @button == 1

      def to_s = "#<Citrine::Native::PointerEvent #{type} (#{x}, #{y})>"
      def inspect = to_s
    end
  end
end
