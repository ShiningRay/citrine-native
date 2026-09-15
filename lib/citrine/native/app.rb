# frozen_string_literal: true

require "citrine"
require_relative "widgets"
require_relative "renderer"

module Citrine
  module Native
    # 应用入口：窗口 + 主循环（`Citrine::Native.run` 的落地实现）。
    #
    # 生命周期（GOALS 4.4）：**全部在主线程**——libui 的控件回调本身在主线程触发，
    # 因此 Signal 写入与 Effect 重跑天然串行，`Citrine.batch` 直接可用；
    # 后台线程（网络/文件）想更新 UI 必须走 `widgets.queue_main`。
    #
    # 拆解顺序（libui 的硬约束，见 widgets/libui.rb）：
    #   卸载组件（逐个 dispose：先子后父，销毁各自控件）
    #   → 销毁窗口（连坐根容器）
    #   → uiUninit
    # 顺序错了两头都会踩：窗口先销毁，组件卸载就动到已释放的控件；
    # 组件不卸载就先销毁窗口，unmount 钩子与 Effect 释放全被跳过。
    class App
      DEFAULT_OPTIONS = { title: "Citrine", width: 640, height: 480, margined: true,
                          activate: true }.freeze

      # 优雅退出用的信号集合（launcher 传 `signals: :default` 时用这一组）。
      # 为什么是这几个：`run` 把 teardown 放在 ensure 里，而 Ruby 对**未捕获**的终止
      # 信号是直接终止进程、不跑 ensure——libui 的控件销毁记账就整个跳过了（见
      # docs/design/platform-matrix.md 第三节）。实际安装时会按 `Signal.list` 过滤：
      # Windows 没有 HUP/QUIT/ALRM，`trap` 会直接 ArgumentError。
      DEFAULT_QUIT_SIGNALS = %w[INT TERM HUP QUIT ALRM].freeze

      attr_reader :component, :options, :widgets, :renderer, :window, :root

      def initialize(component, widgets: nil, signals: nil, **options)
        @component = component.is_a?(Class) ? component.new : component
        @options = DEFAULT_OPTIONS.merge(options)
        @widgets = widgets || Widgets.default
        @renderer = Renderer.new(widgets: @widgets)
        @signals = signals
        @torn_down = false
      end

      # 建窗口 + 挂载组件 + 进主循环（阻塞到窗口关闭）
      def run
        setup
        trap_quit!(signals: @signals) if @signals
        @widgets.main_loop
        self
      ensure
        teardown
      end

      # 装"收到终止信号就退出主循环"的处理器：退出后仍走 `run` 的 ensure → 有序拆解。
      # 只在本平台**实际存在**的信号上装（按 `Signal.list` 过滤），返回真正装上的名字，
      # 便于启动器记日志或断言。
      #
      # 为什么不在 `run` 里默认装：`trap` 是**进程级**的，会覆盖宿主已有的处理器——
      # 库不该悄悄接管宿主的信号策略（被嵌入时尤其如此）。应用把自己当独立进程
      # （脚本即应用）时传 `signals: :default` 即可，例如：
      #
      #   Citrine::Native.run(MyApp, signals: :default, title: "我的应用")
      #   # 或自管主循环：
      #   app = Citrine::Native.start(MyApp, title: "我的应用")
      #   app.trap_quit!   # 或 trap_quit!(signals: %w[INT TERM])
      #   app.widgets.main_loop
      #   app.teardown
      def trap_quit!(signals: DEFAULT_QUIT_SIGNALS)
        names = (signals == :default ? DEFAULT_QUIT_SIGNALS : Array(signals)).map(&:to_s)
        registered = names.select { |name| ::Signal.list.key?(name) }
        registered.each { |name| trap(name) { quit } }
        registered
      end

      # 非阻塞的前半程（测试与"自己管主循环"的场景用）
      def setup
        @widgets.init
        @root = @renderer.mount_component(@component, @options)
        @window = @renderer.window
        @widgets.window_on_closing(@window) { true } # 回 true 表示"允许关窗"（适配层据此 quit）
        @widgets.window_show(@window)
        activate_window
        self
      end

      # 有序拆解：先卸载组件（跑 on_unmount、dispose 全部 Effect、销毁控件），
      # 再销毁窗口，最后反初始化工具包。幂等。
      def teardown
        return self if @torn_down

        @torn_down = true
        begin
          Citrine.unmount(@component) if @root
        ensure
          destroy_window
          @widgets.shutdown
        end
        self
      end

      def quit
        @widgets.quit
        self
      end

      private

      # 显示窗口之后必须**激活应用**（设计 2.3 的实测结论）：macOS 下
      # `uiControlShow` 出来的窗口不是 key window（firstResponder 为 nil），
      # 于是应用一个键也收不到——"窗口看得见、键盘用不了"。
      # `activate: false` 可关掉（不想抢用户焦点时），此时键盘要靠点一下面板。
      def activate_window
        return false unless @options.fetch(:activate, true)

        @widgets.window_activate(@window)
      end

      def destroy_window
        window = @window || @renderer.window
        return false unless window

        @widgets.window_destroy(window)
        true
      end
    end
  end
end
