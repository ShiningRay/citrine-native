# frozen_string_literal: true

module Citrine
  module Native
    # 自绘面板句柄（设计 2.5，冻结）：`ref:` 登记的就是它，**不是 libui 裸指针**——
    # 应用只经它做三件面板特有的事，其余（绘制/事件）都走 on_draw / on_* 回调。
    #
    #   element(:area, ref: :grid, on_draw: …)
    #   refs[:grid].repaint              # 立即标脏重画（等价于"我知道内容变了"）
    #   refs[:grid].scroll_to(0, 200, 300, 120)   # 仅滚动面板：把这块滚进视口
    #   refs[:grid].focus                # 把键盘焦点给面板（macOS；见 2.3 的实测）
    #
    # 句柄只是"适配层的门面"：能力缺口（没有滚动条 / 平台不给焦点）由后端如实返回，
    # 句柄不自己编造成功。
    class AreaHandle
      # 后端句柄（Fiddle::Pointer / 桩后端的 Widget）：诊断与测试用，应用一般不用碰
      attr_reader :handle

      def initialize(widgets:, handle:)
        @widgets = widgets
        @handle = handle
      end

      # 标脏 + 排一次重绘（libui 的 uiAreaQueueRedrawAll：合并进下一帧）
      def repaint
        @widgets.area_queue_redraw(@handle)
        self
      end

      # 仅滚动面板（设计 2.5）：把内容坐标里的 (x, y, w, h) 滚进视口。
      # 非滚动面板没有滚动条——libui 对此会 uiprivUserBug 终止进程，所以后端会
      # fail fast（ArgumentError，提示改用 scroll: true）；先用 scrollable? 判断。
      def scroll_to(x, y, w, h)
        @widgets.area_scroll_to(@handle, x, y, w, h)
        self
      end

      # 把键盘焦点给面板（设计 2.3：macOS 走 [keyWindow makeFirstResponder:]）。
      # 返回 true/false——平台没这条能力时如实返回 false，不假装成功。
      def focus = @widgets.area_focus(@handle)

      # 有没有滚动条（scroll: true 的面板才有）
      def scrollable? = @widgets.area_scrollable?(@handle)

      def to_s = "#<Citrine::Native::AreaHandle #{@widgets.describe(@handle)}>"
      def inspect = to_s
    end
  end
end
