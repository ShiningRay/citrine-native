# frozen_string_literal: true

# Citrine::Native — Citrine 组件的 CRuby 原生运行时（Shoes 式：ruby app.rb 直接起窗口）。
#
# 设计与计划见 GOALS.md。本 gem 实现 `Citrine::Renderer` 的平台钩子（renderer.rb），
# 把节点树翻译成原生控件树；只依赖 citrine 的平台无关核心，**不引入 Opal**。
#
#   require "citrine-native"
#
#   class Counter < Citrine::Component
#     state :count, 0
#     def view
#       stack(gap: 8) do
#         label { "计数：#{count}" }
#         button(on_click: -> { self.count += 1 }) { "点我 +1" }
#       end
#     end
#   end
#
#   Citrine::Native.run(Counter, title: "计数器", width: 400, height: 300)

require "citrine"

module Citrine
  module Native
    # 本 gem 的基类异常（组件代码不必 rescue，出错就是要看见）
    class Error < StandardError; end

    # 元素/属性在原生后端没有对应概念（GOALS 4.3：不静默降级）
    class UnsupportedElementError < Error; end

    # 后端工具包不可用（缺少 libui 动态库等）
    class ToolkitUnavailableError < Error; end
  end
end

require_relative "native/version"
require_relative "native/style_matrix"
require_relative "native/pointer_event"
require_relative "native/painter"
require_relative "native/area_handle"
require_relative "native/widgets"
require_relative "native/renderer"
require_relative "native/timer"
require_relative "native/app"

module Citrine
  module Native
    class << self
      # 活动后端（适配层实例）：由 Renderer 建立时登记（与核心"活动渲染器 = 最近
      # 挂载的那个"同口径）。定时器靠它把自己排回主线程，应用一般不用碰。
      attr_accessor :active_widgets

      # 周期定时器（设计 2.5）→ Timer 句柄，可 #stop；块在主线程执行
      #
      #   @ticker = Citrine::Native.every(200) { self.tick }
      #   # on_unmount 里：@ticker.stop
      def every(milliseconds, &block) = Timer.every(milliseconds, &block)

      # 一次性定时器（设计 2.5）
      def after(milliseconds, &block) = Timer.after(milliseconds, &block)

      # 起一个原生窗口应用（阻塞到窗口关闭）。
      #
      #   Citrine::Native.run(Counter, title: "计数器", width: 400, height: 300)
      #
      # component 可以是组件类（无 prop 构造）或已构造的实例。
      # 其余关键字直接作为窗口描述交给渲染器：title / width / height / margined。
      #
      # dev_mode 默认开：原生运行时没有构建管线（脚本即应用），开发期提醒
      # （未支持的样式键/属性、未声明方向的 box）应当直接可见；显式传
      # dev_mode: false 可关掉，传 nil 则保留调用方此前的设置。
      #
      # signals 默认 nil（不接管进程级信号）：库不该悄悄覆盖宿主已有的处理器。
      # 把运行脚本当独立进程时传 `signals: :default`，Ctrl+C / SIGTERM 就会走
      # "退出主循环 → 有序拆解"，而不是硬杀（见 App#trap_quit!）。
      def run(component, dev_mode: true, widgets: nil, **options)
        Citrine.dev_mode = dev_mode unless dev_mode.nil?
        App.new(component, widgets: widgets, **options).run
      end

      # 只建窗口挂组件、不进主循环（测试与自管事件循环用）
      def start(component, dev_mode: nil, widgets: nil, **options)
        Citrine.dev_mode = dev_mode unless dev_mode.nil?
        App.new(component, widgets: widgets, **options).tap(&:setup)
      end
    end
  end
end
