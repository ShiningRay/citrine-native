# frozen_string_literal: true

# Citrine::Native —— Citrine 组件的 CRuby 原生运行时**核心**（后端无关）。
#
# 这里只有平台无关的部分：Renderer（节点树 → 控件树翻译）、App（窗口生命周期）、
# StyleMatrix、Painter 协议（Primitives + Recording）、Widgets::Base 协议 +
# Memory 桩、定时器。具体控件由后端 gem 提供，按名字选择：
#
#   require "citrine-native"          # 核心
#   Citrine::Native.run(Counter, backend: :libui)   # → citrine-native-libui
#   Citrine::Native.run(Counter, backend: :gtk)     # → citrine-native-gtk
#
# 约定：后端 gem 名 = citrine-native-<名字>，控件适配类 =
# Citrine::Native::Widgets::<CamelCase>(名字)（libui → Libui，gtk → Gtk，qt → Qt）。
# 非常规命名用 Citrine::Native.register_backend 注册。也可以直接传实例：
#   Citrine::Native.run(Counter, widgets: SomeBackend.new)
#
# 后端包（如 citrine-native-libui）被加载时会自登记，并把自己设为
# default_backend——所以"require 后端 gem 之后不传 backend:"也能跑。

require "citrine"

module Citrine
  module Native
    # 本 gem 的基类异常（组件代码不必 rescue，出错就是要看见）
    class Error < StandardError; end

    # 元素/属性在原生后端没有对应概念（GOALS 4.3：不静默降级）
    class UnsupportedElementError < Error; end

    # 后端工具包不可用（缺少 libui/GTK 动态库等）
    class ToolkitUnavailableError < Error; end

    # 未选择后端（core 自己不带控件实现）
    class BackendNotSelectedError < Error; end
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

      # 默认后端名（符号）：由后端包在被加载时自设（如 -libui 设 :libui），
      # 应用也可以显式指定。nil = 未设（run 时不传 backend:/widgets: 会报错）。
      attr_accessor :default_backend

      # 已登记的后端（名字 → 控件适配类全名）
      def registry
        @registry ||= {}
      end

      # 登记后端（非常规命名的出口；常规命名靠 resolve_backend 的约定即可）
      def register_backend(name, widgets:)
        registry[name.to_sym] = widgets.to_s
        self
      end

      # 按名字解析并实例化后端：约定 require "citrine-native-<名字>"，
      # 控件类 = Citrine::Native::Widgets::<Camel>(名字)
      def resolve_backend(name)
        name = name.to_sym
        widgets_class = registry[name] ||
                        "Citrine::Native::Widgets::#{camelize(name)}"
        require "citrine-native-#{name}"
        widgets_class.split("::").inject(Object) { |mod, constant| mod.const_get(constant) }.new
      rescue LoadError => e
        raise ToolkitUnavailableError,
              "后端 #{name} 不可用（#{e.message}）：gem citrine-native-#{name} " \
              "没有装，或它的运行时依赖缺失"
      end

      # libui → Libui；gtk → Gtk；windows_font → WindowsFont
      def camelize(name)
        name.to_s.split("_").map { |part| part.capitalize }.join
      end

      # 周期定时器（设计 2.5）→ Timer 句柄，可 #stop；块在主线程执行
      #
      #   @ticker = Citrine::Native.every(200) { self.tick }
      #   # on_unmount 里：@ticker.stop
      def every(milliseconds, &block) = Timer.every(milliseconds, &block)

      # 一次性定时器（设计 2.5）
      def after(milliseconds, &block) = Timer.after(milliseconds, &block)

      # 起一个原生窗口应用（阻塞到窗口关闭）。
      #
      #   Citrine::Native.run(Counter, backend: :libui, title: "计数器", width: 400, height: 300)
      #
      # component 可以是组件类（无 prop 构造）或已构造的实例。
      # 后端三选一：backend:（名字，按上面的约定解析）／ widgets:（现成实例）／
      # 都不传则用 default_backend（后端包被 require 时自设）。其余关键字直接
      # 作为窗口描述交给渲染器：title / width / height / margined。
      #
      # dev_mode 默认开：原生运行时没有构建管线（脚本即应用），开发期提醒
      # （未支持的样式键/属性、未声明方向的 box）应当直接可见；显式传
      # dev_mode: false 可关掉，传 nil 则保留调用方此前的设置。
      #
      # signals 默认 nil（不接管进程级信号）：库不该悄悄覆盖宿主已有的处理器。
      # 把运行脚本当独立进程时传 `signals: :default`，Ctrl+C / SIGTERM 就会走
      # "退出主循环 → 有序拆解"，而不是硬杀（见 App#trap_quit!）。
      def run(component, dev_mode: true, widgets: nil, backend: nil, **options)
        Citrine.dev_mode = dev_mode unless dev_mode.nil?
        App.new(component, widgets: pick_backend(widgets, backend), **options).run
      end

      # 只建窗口挂组件、不进主循环（测试与自管事件循环用）
      def start(component, dev_mode: nil, widgets: nil, backend: nil, **options)
        Citrine.dev_mode = dev_mode unless dev_mode.nil?
        App.new(component, widgets: pick_backend(widgets, backend), **options).tap(&:setup)
      end

      private

      def pick_backend(widgets, backend)
        return widgets if widgets
        return resolve_backend(backend) if backend
        return Widgets.default if default_backend

        raise BackendNotSelectedError,
              "没有选择后端：请传 backend: :libui / :gtk（需要安装对应后端 gem），" \
              "或 widgets: 后端实例；也可以 require 后端 gem（它会自设默认后端）"
      end
    end
  end
end
