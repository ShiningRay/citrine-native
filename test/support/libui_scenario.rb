# frozen_string_literal: true
$stdout.sync = true

# 真控件冒烟（**子进程**运行：libui 出问题会 abort 进程，不能拖垮测试进程）。
# CI 不开窗——本脚本默认**不显示窗口**，只创建真控件树，并直接触发
# "已注册到 libui 的原生回调"（Fiddle 闭包，不经过 OS 事件），覆盖四件事：
#
#   1. Counter 点击精确 +1：真 label/button + 真回调 + 真 set_text 链路
#   2. 容器重排（attach_before 的底座 box_move_before）确实改变了物理顺序
#      ——用 libui 自己的 box_delete(index) 反查"谁在 0 号位"，不查我们自己的账本
#   3. 自绘面板（area）：五个回调槽装齐、合成 uiAreaMouseEvent/uiAreaKeyEvent 走真
#      回调（坐标/修饰键/键名归一、Down+Up 配对成 click）、真 libui 文本布局的度量
#      与外接矩形（中文 / 换行）、布局缓存复用与释放
#   4. 有序拆解后 uiUninit 不报泄漏：没有控件残留、没有 double free
#
# `--gui` 模式换一条路径：真窗口 + 真主循环（uiMain），由后台线程经 queue_main
# 排入"点 3 次 → quit"与"改信号 → 面板重绘 → quit"，几毫秒后自行退出
# （窗口会闪现一下）。默认不开，需要时 `CITRINE_NATIVE_GUI=1 bundle exec rake test`
# 或手工跑一次。面板的**真绘制**（真 Painter → libui draw 调用）只在这条路径上跑：
# uiDrawContext 只在 Draw 回调内有效，没有窗口就没有真绘制上下文。
#
# 无 GUI 环境（无 window server）时输出 LIBUI_UNAVAILABLE 并以 0 退出，测试侧跳过。

lib = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
citrine_dev = File.expand_path("../../../citrine/lib", __dir__)
$LOAD_PATH.unshift(citrine_dev) if File.exist?(citrine_dev) && !$LOAD_PATH.include?(citrine_dev)

require "citrine-native"
require "fiddle"
require "rbconfig"

module Smoke
  class << self
    attr_accessor :failures
    attr_reader :checks

    def check(name, actual, expected)
      if actual == expected
        puts "ok   #{name}"
      else
        puts "FAIL #{name}: 期望 #{expected.inspect}，实际 #{actual.inspect}"
        @failures += 1
      end
    end

    # 平台专属断言在别的平台记为跳过（不算失败）：AppKit 对照组只在 macOS 有意义
    def skip(name, reason = "非 macOS 平台")
      puts "skip #{name}（#{reason}）"
    end

    # 模拟用户操作：调用 libui 真正持有的那个回调闭包（gem 把闭包挂在句柄对象上）
    def fire_native(control)
      callbacks = control.instance_variable_get(:@callbacks)
      raise "#{control.inspect} 上没有注册原生回调" if callbacks.nil? || callbacks.empty?

      callbacks.first.call
    end

    def detached?(control) = ::LibUI.control_parent(control).to_i.zero?
  end
end
Smoke.failures = 0

# 冒烟侧的 AppKit 几何读法（**独立对照**：不信框架自己的读数，自己问 AppKit 要）。
# Fiddle 拿不到 32 字节的结构体返回值，所以走 KVC + NSValue#getValue:size:
# （参数全是指针，Fiddle 能表达）。只在 macOS 定义：Windows 等平台上框架侧
# ObjcBridge 本来就 available? == false（回退 Clip*），这些对照断言整段跳过。
MACOS = RbConfig::CONFIG["host_os"].match?(/darwin/i)

if MACOS
module AppKitProbe
  LIB = Fiddle.dlopen("/usr/lib/libobjc.A.dylib")
  SEL = Fiddle::Function.new(LIB["sel_registerName"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
  CLASS = Fiddle::Function.new(LIB["objc_getClass"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
  MSG0 = Fiddle::Function.new(LIB["objc_msgSend"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                              Fiddle::TYPE_VOIDP)
  MSG1 = Fiddle::Function.new(LIB["objc_msgSend"],
                              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                              Fiddle::TYPE_VOIDP)
  MSG_VOID = Fiddle::Function.new(LIB["objc_msgSend"],
                                  [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                                   Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
                                  Fiddle::TYPE_VOID)
  # 返回 BOOL 的方法（makeFirstResponder: / isDescendantOf:）：BOOL = signed char，
  # 必须按 char 读（用指针类型读小整数返回值拿到的是寄存器残值）
  BOOL3 = Fiddle::Function.new(LIB["objc_msgSend"],
                               [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                               Fiddle::TYPE_CHAR)

  module_function

  def sel(name) = SEL.call(name)
  def send0(object, name) = MSG0.call(object, sel(name))
  def send1(object, name, arg) = MSG1.call(object, sel(name), arg)

  # struct 属性（NSRect = 4 个 double）→ { x:, y:, w:, h: }
  def rect(object, key)
    name = MSG1.call(CLASS.call("NSString"), sel("stringWithUTF8String:"), key)
    value = send1(object, "valueForKey:", name)
    buffer = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE * 4, Fiddle::RUBY_FREE)
    MSG_VOID.call(value, sel("getValue:size:"), buffer, Fiddle::SIZEOF_DOUBLE * 4)
    x, y, w, h = buffer[0, Fiddle::SIZEOF_DOUBLE * 4].unpack("d4")
    { x: x, y: y, w: w, h: h }
  end

  # 面板控件句柄（uiArea*）→ 它的 AppKit 视图（滚动面板是 NSScrollView）
  def view_of(area) = ::LibUI.control_handle(area)

  def document_view_of(scroll_view) = send0(scroll_view, "documentView")

  # 窗口此刻的 firstResponder（NA-1d：与框架 focus 的返回值对拍；走**给定窗口**而不是
  # [NSApp keyWindow]，窗口不是 key 时也能读）
  def first_responder_of(window) = send0(window, "firstResponder")

  # 自己读一次 makeFirstResponder: 的 BOOL（BOOL = signed char；用 char 返回类型读）
  def make_first_responder(window, view)
    BOOL3.call(window, sel("makeFirstResponder:"), view) != 0
  end

  # view 是不是 ancestor 的后代（`isDescendantOf:`；自身也算，实测返回 YES）。
  # 滚动面板下 focus 之后 first responder 是 document view 而不是 NSScrollView，
  # 所以"焦点落在面板上"要用这条判据，不能直接比指针。
  def descendant_of?(view, ancestor) = BOOL3.call(view, sel("isDescendantOf:"), ancestor) != 0
end
end # MACOS

class SmokeCounter < Citrine::Component
  state :count, default: 0

  def view
    stack(gap: 8) do
      label(ref: :label) { "计数：#{count}" }
      button(ref: :go, on_click: -> { self.count += 1 }) { "点我 +1" }
    end
  end
end

# 没有 on_key 的面板（NA-1c：键盘返回值的第三种情形——"没人认领"）
class SmokePlainPanel < Citrine::Component
  def view
    element(:area, ref: :panel, on_draw: ->(panel) { panel.rect(0, 0, 8, 8, fill: "#102030") })
  end
end

# 自排队动画（NA-2 P2.2）：画完就再标脏一次，指望下一帧接着画。
# 布局遵循 F11 判据：bare area 直接当组件根会落进框架的非 stretchy 根容器
# （renderer 的 setup_root）——Windows 的严格 stretchy 链在那里就断了（area 塌成
# 0×0、一帧都不画），所以要包一层 stretchy stack（macOS 宽容看不出来）。
class SmokeSelfDrivenPanel < Citrine::Component
  attr_reader :frames

  def initialize(props = {})
    super
    @frames = []
  end

  def view
    stack(style: { flex_grow: 1 }) do
      element(:area, ref: :panel, style: { flex_grow: 1 }, on_draw: ->(panel) { paint(panel) })
    end
  end

  def paint(panel)
    @frames << panel.width
    panel.rect(0, 0, panel.width, panel.height, fill: "#0b1424")
    refs[:panel].repaint
  end
end

# 定时器心跳（NA-1d / NA-2 的 N1）：tick 不得让适配层的**常驻**闭包数组增长
class SmokeTimerHeartbeat < Citrine::Component
  state :ticks, default: 0

  attr_reader :timer

  def view
    stack { label(ref: :status) { "ticks=#{ticks}" } }
  end

  on_mount { @timer = Citrine::Native.every(50) { self.ticks += 1 } }
  on_unmount { @timer.stop }
end

# 自绘面板的冒烟组件：滚动面板（内容 320×600）+ 各图元 + 鼠标/键盘处理器
class SmokePanel < Citrine::Component
  state :cells, default: %w[第一 第二]

  attr_reader :events, :paints, :clips

  def initialize(props = {})
    super
    @events = []
    @paints = []
    @clips = []
  end

  def view
    # 布局遵循 F11 判据（Windows 实测补齐）：参与拉伸的 box 自己要有 stretchy 尺寸、
    # 逐层成立——Windows 的 libui box 是严格的，断链处 area 塌成 0×0 且 Draw 不触发
    # （macOS 对窗口直系子元素宽容，同一棵树在 macOS 上看不出来）。
    stack(gap: 6, style: { flex_grow: 1 }) do
      label(ref: :hint) { "cells=#{cells.size}" }
      element(:area, ref: :panel, scroll: true, size: [320, 600],
                     style: { flex_grow: 1 },
                     watch: -> { cells.size },
                     on_draw: ->(panel) { paint(panel) },
                     on_click: ->(event) { note(:click, event) },
                     on_mouse_down: ->(event) { note(:down, event) },
                     on_mouse_up: ->(event) { note(:up, event) },
                     on_mouse_move: ->(event) { note(:move, event) },
                     on_key: { "ArrowDown" => :key_down, "Enter" => :key_enter, else: :key_other })
    end
  end

  def note(kind, event) = @events << [kind, event.x, event.y, event.shift?]

  def paint(panel)
    @paints << [panel.width, panel.height]
    @clips << panel.clip_rect
    panel.rect(0, 0, panel.width, panel.height, fill: "#14203a", stroke: "#1e2c48")
    panel.line(0, 0, panel.width, panel.height, color: "#1e2c48", width: 1)
    panel.polyline([[0, 0], [40, 60], [90, 20]], color: "#31456b", width: 2)
    panel.polygon([[0, 0], [60, 0], [30, 50]], fill: "#20304f", stroke: "#31456b")
    cells.each_with_index do |cell, index|
      panel.text(cell, x: 12, y: 12 + index * 22, color: "#e6ecf8", size: 14)
      panel.text("1288.50", x: 200, y: 12 + index * 22, color: "#4ecb71", size: 14,
                           weight: :bold, align: :right, width: 100)
    end
    panel.clip(0, 0, panel.width, 40) { panel.rect(0, 0, panel.width, 40, fill: "#0b1424") }
  end

  def key_down(event) = @events << [:key, event.key, event.shift?]
  def key_enter(event) = @events << [:key, event.key, event.shift?]
  def key_other(event) = @events << [:key, event.key, event.shift?]
end

begin
  require "libui"
rescue LoadError => e
  puts "LIBUI_UNAVAILABLE #{e.class}: #{e.message}"
  exit 0
end

begin
  backend = Citrine::Native::Widgets.default
  backend.init
rescue StandardError => e
  puts "LIBUI_UNAVAILABLE #{e.class}: #{e.message}"
  exit 0
end

# ── 真文本布局：度量 / 换行 / 缓存复用与释放（不需要开窗）────────
#
# Painter 的真绘制要 uiDrawContext（只在 Draw 回调里有效），但**布局与度量**
# 只用 libui 的文本接口，所以这一段在默认（不开窗）路径里就能验。
def check_text_layout
  cache = Citrine::Native::Painter::TextCache.new
  args = { size: 14, weight: 400, family: nil, wrap_width: -1.0, align: :left }
  cjk = cache.entry(string: "贵州茅台", color: [1.0, 1.0, 1.0, 1.0], **args)
  ascii = cache.entry(string: "ABCD", color: [1.0, 1.0, 1.0, 1.0], **args)
  wrapped = cache.entry(string: "很长的中文文本需要换行显示的一整段文字", color: nil,
                        size: 14, weight: 400, family: nil, wrap_width: 40.0, align: :left)
  bold = cache.entry(string: "贵州茅台", color: [1.0, 1.0, 1.0, 1.0], **args.merge(weight: 700))

  Smoke.check("中文文本有合理外接矩形",
              [cjk.measured_width.positive?, cjk.measured_height.positive?], [true, true])
  Smoke.check("度量随字号变化（14 → 28 更宽）",
              cache.entry(string: "贵州茅台", color: nil, size: 28, weight: 400, family: nil,
                          wrap_width: -1.0, align: :left).measured_width > cjk.measured_width, true)
  Smoke.check("四个汉字比四个 ASCII 宽", cjk.measured_width > ascii.measured_width, true)
  Smoke.check("不同字重/颜色是不同缓存项", bold.equal?(cjk), false)
  Smoke.check("给定窄宽度会换行（高度变大）", wrapped.measured_height > cjk.measured_height, true)

  # 同一参数重复取 → 命中同一条布局（跨帧复用，避免每帧每格新建 text layout）
  5.times { cache.entry(string: "贵州茅台", color: [1.0, 1.0, 1.0, 1.0], **args) }
  Smoke.check("重复取用命中同一批缓存项", cache.entry_count, 5)

  # clear! 释放真 layout / attributed string / 字体描述符（漏了就是 C 内存泄漏）
  cache.clear!
  Smoke.check("clear! 后缓存清空", [cache.entry_count, cache.font_count], [0, 0])
end
check_text_layout

if ARGV.include?("--gui")
  # 真窗口 + 真主循环：起窗 → 点 3 次 → 关窗退出，全程走 App 的生命周期
  app = Citrine::Native::App.new(SmokeCounter, widgets: backend,
                                              title: "citrine-native 冒烟", width: 320, height: 200)
  Thread.new do
    sleep 0.4
    # 后台线程 → 主线程：文档里给应用代码的唯一跨线程通道
    backend.queue_main do
      3.times { Smoke.fire_native(app.component.refs[:go]) }
      Smoke.check("主循环下的点击计数", backend.get_text(app.component.refs[:label]), "计数：3")
      app.quit
    end
  end
  app.run
  Smoke.check("GUI 模式：拆解后没有残留控件", backend.live_handles, 0)

  # 面板走真绘制：Painter 的每个图元都是真 libui draw 调用（画错了 libui 会 abort）
  panel_app = Citrine::Native::App.new(SmokePanel, widgets: backend,
                                                    title: "citrine-native 面板冒烟", width: 420, height: 320)
  component = panel_app.component
  panel_handle = nil # 挂载发生在 run 里（App.new 只建对象）→ 句柄要等 setup 之后取
  paints_before_change = nil
  paints_before_manual = nil
  Thread.new do
    sleep 0.5
    backend.queue_main do
      panel_handle = component.refs[:panel]
      paints_before_change = component.paints.size
      paints_before_manual = component.paints.size
    end
    sleep 0.1
    backend.queue_main { component.cells = %w[一 二 三] } # watch 依赖变化 → 排重绘
    sleep 0.3
    backend.queue_main do
      # 设计 2.3 的硬要求：显示窗口之后必须激活应用，否则窗口不是 key window、
      # 一个键也收不到（这条断言是那个实测结论的机器可验证形式）。
      # 激活的生效走主循环轮次，所以给几次机会再断言——别把系统时序当框架回归。
      # macOS 专属：window_is_key? / makeFirstResponder: 走 ObjcBridge，其他平台
      # 框架如实返回 false（Windows 下窗口激活与焦点由系统管理，无需等价断言）。
      if defined?(AppKitProbe)
      keyed = false
      5.times do
        break if (keyed = backend.window_is_key?(panel_app.window))

        sleep 0.1
      end
      Smoke.check("App 显示窗口后激活了应用（窗口是 key window）", keyed, true)
      # NA-1d（NA-2 P3）：focus 的返回值必须转达 AppKit 的 BOOL（旧写法只要"窗口是 key
      # window"就 return true）。成功情形的判据是**两件事同时成立**：返回 true，且焦点
      # 真的落在这个面板上——滚动面板的 first responder 是它的 document view（areaView），
      # 不是 NSScrollView 本身，所以用 isDescendantOf: 判，不直接比指针。
      panel_window_view = ::LibUI.control_handle(panel_app.window)
      panel_control_view = AppKitProbe.view_of(panel_handle.handle)
      Smoke.check("AreaHandle#focus 走真 makeFirstResponder:（成功情形返回 true）",
                  panel_handle.focus, true)
      Smoke.check("focus 返回 true 时焦点确实落在面板上（面板视图或它的 document view）",
                  AppKitProbe.descendant_of?(AppKitProbe.first_responder_of(panel_window_view),
                                             panel_control_view), true)

      # 失败情形 A：目标为空 → 如实返回 false，且不产生副作用（焦点不动）
      responder_before = AppKitProbe.first_responder_of(panel_window_view)
      Smoke.check("目标为空时 focus 如实返回 false（能力缺口不伪装成功）", backend.focus_view(0), false)
      Smoke.check("...且没有副作用：firstResponder 不变",
                  AppKitProbe.first_responder_of(panel_window_view).to_i, responder_before.to_i)

      # 失败情形 B：AppKit **受理**了请求，但目标根本没拿到焦点（游离视图：不属于这个窗口）。
      # 这是"返回值必须诚实"的判别用例：只转达 makeFirstResponder: 的 BOOL 会得到 true
      # （实测 macOS 26 上该 BOOL 对不接受 first responder 的目标也是 YES、并把**窗口自己**
      # 设成 first responder），加上"firstResponder 真的是目标（或其后代）"这层才是 false。
      # 断言按"返回值与实际 firstResponder 一致"写：两边必须同时说"没生效"。
      stray = backend.create_area(scroll: false, size: [100, 100]) { |p| p.rect(0, 0, 1, 1, fill: "#000000") }
      stray_view = AppKitProbe.view_of(stray)
      raw = AppKitProbe.make_first_responder(panel_window_view, stray_view) # 独立读数（AppKit 原值）
      relayed = backend.focus_view(stray_view)                              # 框架的答复
      Smoke.check("失败情形：AppKit 的原值是 YES（它只说'窗口受理了'）", raw, true)
      Smoke.check("失败情形：focus 仍如实返回 false（目标没拿到焦点）", relayed, false)
      Smoke.check("失败情形：返回值与实际 firstResponder 一致（目标不是 first responder）",
                  AppKitProbe.first_responder_of(panel_window_view).to_i == stray_view.to_i, false)
      backend.destroy(stray) # 走适配层销毁（顺带作废记账，否则收尾的"零残留"断言会数到它）

      # 恢复：把焦点还给面板（后面还有别的断言依赖面板持有焦点）
      Smoke.check("焦点还给面板（后续断言依赖它）", panel_handle.focus, true)
      else
        Smoke.skip("App 激活/key window 断言")
        Smoke.skip("AreaHandle#focus 的 makeFirstResponder 对照断言（成功/失败情形 + 恢复）")
      end
      Smoke.check("真窗口下 on_draw 跑过", component.paints.size.positive?, true)
      Smoke.check("滚动面板的尺寸来自声明的内容尺寸（macOS 下 Draw 不报尺寸）",
                  component.paints.map { |(w, h)| [w, h] }.uniq, [[320.0, 600.0]])
      Smoke.check("信号变化后面板真的重画了", component.paints.size > paints_before_change.to_i, true)
      # 手动标脏（设计 2.5 的 handle.repaint）也要真的重画
      paints_before_manual = component.paints.size
      panel_handle.repaint
    end
    sleep 0.3
    backend.queue_main do
      Smoke.check("AreaHandle#repaint 真的触发了一次重画",
                  component.paints.size > paints_before_manual.to_i, true)
      Smoke.check("未滚动时可见区在顶部", component.clips.last[1].zero?, true)

      # D2 结论（NA-1c）：滚动面板**吃** flex_grow——控件自己撑满了容器给的空间。
      # 这正是 SHEETS-2 的最小复现里被误判的一条（"换 scroll: false 就撑满"是绘制溢出
      # 造成的错觉，见 docs/design/native-area.md 5.7）。frame/visibleRect 读数走 AppKit，
      # 非 macOS 跳过对照（框架侧回退 Clip*，几何断言只有 macOS 能独立复核）。
      if defined?(AppKitProbe)
      scroll_view = AppKitProbe.view_of(panel_handle.handle)
      scroll_frame = AppKitProbe.rect(scroll_view, "frame")
      Smoke.check("滚动面板的控件撑满了容器（flex_grow 对滚动面板有效）",
                  [scroll_frame[:w] > 300, scroll_frame[:h] > 150], [true, true])

      # D7：clip_rect 必须等于真 AppKit 几何里的可见区（面积见区），而不是脏区/滚动视图框。
      # 两个独立读数对拍：框架给的 clip_rect ↔ 这里自己问 AppKit 要的 visibleRect。
      document = AppKitProbe.document_view_of(scroll_view)
      visible = AppKitProbe.rect(document, "visibleRect")
      clip = component.clips.last
      Smoke.check("clip_rect 的尺寸不超过真实可见区（不含滚动条占位）",
                  [clip[2] <= visible[:w].ceil, clip[3] <= visible[:h].ceil], [true, true])
      # 夹在声明的内容尺寸（320×600）内：视口比内容宽时（这里视口 363 > 内容 320），
      # clip_rect 只报"内容里可见的那一块"，不报超出内容的空白
      expected = [visible[:w].clamp(0.0, 320.0 - visible[:x]), visible[:h].clamp(0.0, 600.0 - visible[:y])]
      Smoke.check("clip_rect 就是真实可见区（夹在声明的内容尺寸内）",
                  [clip[2].round, clip[3].round], expected.map(&:round))
      else
        Smoke.skip("滚动面板 frame/clip_rect 与 AppKit visibleRect 的对拍断言")
      end
      panel_handle.scroll_to(0, 200, 320, 100) # 滚到内容 y=200 处（uiAreaScrollTo）
    end
    sleep 0.4
    backend.queue_main do
      # clip_rect：滚动面板的可见区（内容坐标）——滚过之后不该还停在顶部，
      # 且必须落在内容尺寸（320×600）之内
      Smoke.check("滚动之后 clip_rect 的 y > 0（可见区跟着滚动走）",
                  component.clips.last[1].positive?, true)
      Smoke.check("clip_rect 落在内容尺寸内",
                  component.clips.all? { |(x, y, w, h)| x >= 0 && y >= 0 && w.positive? && h.positive? }, true)
      # 滚动后 clip_rect 的 origin 就是滚动偏移（与 AppKit 的 visibleRect 对拍；macOS 专属）
      if defined?(AppKitProbe)
      visible = AppKitProbe.rect(AppKitProbe.document_view_of(AppKitProbe.view_of(panel_handle.handle)),
                                 "visibleRect")
      Smoke.check("滚动后 clip_rect 的 origin 就是滚动偏移（对拍 AppKit visibleRect）",
                  component.clips.last[1].round, visible[:y].round)
      else
        Smoke.skip("滚动后 clip_rect origin 与 AppKit visibleRect 的对拍")
      end
      panel_app.quit
    end
  end
  panel_app.run
  Smoke.check("GUI 面板：拆解后没有残留控件", backend.live_handles, 0)

  # P2.2：自排队动画（on_draw 里再排一帧）必须真出下一帧——AppKit 在 drawRect 里
  # 忽略 setNeedsDisplay，适配层把它延后到这次绘制收尾再排（NA-2 实测旧行为 frames=1）
  self_driven = SmokeSelfDrivenPanel.new
  driver_app = Citrine::Native::App.new(self_driven, widgets: backend,
                                                     title: "citrine-native 自排队冒烟", width: 240, height: 180)
  frames_before = nil
  closures_before = nil
  Thread.new do
    sleep 0.6
    backend.queue_main do
      frames_before = self_driven.frames.size
      closures_before = backend.instance_variable_get(:@closures).size
    end
    sleep 0.4
    backend.queue_main do
      Smoke.check("on_draw 里 repaint 能出下一帧（自排队动画不冻在第一帧）",
                  self_driven.frames.size > frames_before.to_i + 2,
                  true)
      # 排队用的闭包**不常驻**：自排队动画每帧排一个，常驻就是每帧漏一个闭包
      # （0.4 秒 ≈ 24 帧，真漏的话 @closures 会涨几十个）
      closures_after = backend.instance_variable_get(:@closures).size
      Smoke.check("延后重绘不留常驻闭包（0.4 秒内新增 ≤ 3 个）",
                  closures_after - closures_before.to_i <= 3,
                  true)
      pending = backend.instance_variable_get(:@transient_closures)&.size.to_i
      Smoke.check("延后重绘的闭包执行后即释放（不随帧数增长）", pending <= 2, true)
      self_driven.frames.clear # 别让无限重绘把后面的收尾拖住
      driver_app.quit
    end
  end
  driver_app.run
  Smoke.check("GUI 自排队：拆解后没有残留控件", backend.live_handles, 0)

  # NA-1d（NA-2 的 N1）：定时器每个 tick 都排一个新闭包——若走 queue_main，闭包会常驻
  # 在适配层的 @closures 里（Fiddle 闭包不能被 GC），就是"每 tick 漏一个闭包"：NA-2 实测
  # 50ms 定时器 5 秒 closures/ticks = 54/52，而两个移植 demo 都在用 every。真主循环下量。
  heartbeat = SmokeTimerHeartbeat.new
  heartbeat_app = Citrine::Native::App.new(heartbeat, widgets: backend,
                                                      title: "citrine-native 定时器冒烟",
                                                      width: 200, height: 120)
  marks = {}
  Thread.new do
    sleep 0.6
    backend.queue_main do
      marks[:closures] = backend.instance_variable_get(:@closures).size
      marks[:ticks] = heartbeat.ticks
    end
    sleep 0.6 # 50ms × ~12 tick：旧写法会在这里漏掉 ~12 个常驻闭包
    backend.queue_main do
      ticks = heartbeat.ticks - marks[:ticks].to_i
      growth = backend.instance_variable_get(:@closures).size - marks[:closures].to_i
      Smoke.check("定时器真的在跑（0.6 秒里 ≥ 5 个 tick）", ticks >= 5, true)
      # 本探针自己调了两次 queue_main（各 +1 个常驻闭包）→ 允许新增 2
      Smoke.check("定时器的 tick 不留常驻闭包（~12 tick，新增 ≤ 2）", growth <= 2, true)
      Smoke.check("定时器排队用的是一次性闭包（执行后即释放）",
                  backend.instance_variable_get(:@transient_closures)&.size.to_i <= 2, true)
      heartbeat_app.quit
    end
  end
  heartbeat_app.run
  Smoke.check("GUI 定时器：卸载后不再有 tick（on_unmount 里 stop）", heartbeat.timer.stopped?, true)
  Smoke.check("GUI 定时器：拆解后没有残留控件", backend.live_handles, 0)

  puts(Smoke.failures.zero? ? "SMOKE_OK" : "SMOKE_FAILED #{Smoke.failures}")
  exit(Smoke.failures.zero? ? 0 : 1)
end

# ── 1) Counter：真控件 + 真回调链 ─────────────────────────────
renderer = Citrine::Native::Renderer.new(widgets: backend)
counter = SmokeCounter.new
root = renderer.mount_component(counter, { title: "冒烟", width: 320, height: 200 })
window = renderer.window
label = counter.refs[:label]
button = counter.refs[:go]

Smoke.check("初始文本", backend.get_text(label), "计数：0")
3.times { Smoke.fire_native(button) }
Smoke.check("点击 3 次后精确 +3", backend.get_text(label), "计数：3")
Smoke.check("按钮文本", backend.get_text(button), "点我 +1")
Smoke.check("窗口未显示（冒烟不打扰用户）", ::LibUI.control_visible(window), 0)

# ── 2) 容器重排：物理顺序真的变了 ────────────────────────────
#
# 顺序账本在适配层（libui 不提供 child-at 查询），所以这里用一个**独立**观测：
# 重排后用 libui 自己的 box_delete(0) 删 0 号位，再看谁被摘出来
# （control_parent 变 NULL）——不查我们自己的账本。
# 代价是这一步绕开了适配层记账，收尾也直接用 libui 销毁（不碰 counter 的控件）。
probe = backend.create_box(:column)
first = backend.create_label("A")
second = backend.create_label("B")
third = backend.create_label("C")
[first, second, third].each { |widget| backend.box_append(probe, widget) }
Smoke.check("追加后子控件数", ::LibUI.box_num_children(probe), 3)

backend.box_move_before(probe, third, first) # 期望物理顺序 [C, A, B]

::LibUI.box_delete(probe, 0) # 删 0 号位：谁被摘出来，谁原本就在 0 号位
Smoke.check("重排后 0 号位是 C", [first, second, third].select { |w| Smoke.detached?(w) }, [third])
Smoke.check("重排后仍在容器里的是 A/B", ::LibUI.box_num_children(probe), 2)

# ── 3) 自绘面板：真控件 + 真回调 + 真结构体（不开窗）──────────
panel_renderer = Citrine::Native::Renderer.new(widgets: backend)
panel = SmokePanel.new
panel_root = panel_renderer.mount_component(panel, { title: "面板冒烟", width: 420, height: 320 })
handle = panel.refs[:panel]           # refs 拿到的是 AreaHandle（设计 2.5）
area = handle.handle                  # 直接戳后端时要用它包着的那个句柄
panel_window = panel_renderer.window

Smoke.check("refs[:panel] 是 AreaHandle", handle.class, Citrine::Native::AreaHandle)
Smoke.check("滚动面板：句柄知道自己有滚动条", handle.scrollable?, true)
Smoke.check("五个回调槽必须在创建时装满（libui 调用前不检查 NULL）",
            backend.area_handler_slots(area), %i[Draw MouseEvent MouseCrossed DragBroken KeyEvent])
Smoke.check("area 是真面板控件", backend.kind(area), :area)
# 键盘投递的前提：窗口必须是 key window。uiControlShow 之后**不是**（设计 2.3 实测），
# 要 App 的 activate: 把它激活——冒烟脚本自己建的渲染器没走 App，所以这里应为 false
Smoke.check("未激活时窗口不是 key window（这就是 activate: 存在的原因）",
            backend.window_is_key?(panel_window), false)

# 合成 uiAreaMouseEvent 并调用**已注册的那个闭包**：覆盖"libui 结构体 → PointerEvent"
# 这段链路（OS 真投递仍需人手点一次，见 GOALS 变更日志 NA-1）
backend.simulate_area_mouse(area, x: 12, y: 34, down: 1, count: 1, modifiers: ::LibUI::ModifierShift)
Smoke.check("按下：mouse_down + 本地坐标 + 修饰键", panel.events.last, [:down, 12.0, 34.0, true])
backend.simulate_area_mouse(area, x: 40, y: 50, up: 1)
Smoke.check("按下后抬起：mouse_up + 合成 click",
            panel.events.map(&:first), %i[down up click])
Smoke.check("click 用抬起时的坐标、修饰键跟着抬起那次", panel.events.last, [:click, 40.0, 50.0, false])

events_before = panel.events.size
backend.simulate_area_mouse(area, x: 1, y: 2, up: 1)
Smoke.check("没有按下过的抬起不算 click", panel.events.size - events_before, 1)

# 键名归一（libui 的 Key 是等位字符，ExtKey 是方向/功能键）
backend.simulate_area_key(area, character: "a", modifiers: ::LibUI::ModifierShift)
Smoke.check("字符键归一 + 修饰键", panel.events.last, [:key, "a", true])
backend.simulate_area_key(area, ext_key: ::LibUI::ExtKeyDown)
Smoke.check("方向键归一成 DOM 键名（Hash 键表命中）", panel.events.last, [:key, "ArrowDown", false])
backend.simulate_area_key(area, character: "\n")
Smoke.check("回车归一成 Enter", panel.events.last, [:key, "Enter", false])
events_before = panel.events.size
backend.simulate_area_key(area, character: "a", up: 1)
Smoke.check("抬起不投递（v0 没有 on_key_up）", panel.events.size, events_before)

# ⌘ 键不被吞（NA-1c / NA-2 P1）：这个返回值就是 libui KeyEvent 回调的返回值——
# 非零 = "已处理"，libui 的 sendEvent 就此返回，菜单快捷键（⌘H 这类有绑定的项）
# 再也拿不到事件。所以带 ⌘ 一律返回 0，但不影响回调照常触发（⌘Z 应用自处理）。
meta_before = panel.events.size
Smoke.check("⌘+按键：真闭包返回 0（不吞菜单快捷键）",
            backend.simulate_area_key(area, character: "h", modifiers: ::LibUI::ModifierSuper), 0)
Smoke.check("⌘+按键仍投递给应用（回调照常触发）", panel.events.size - meta_before, 1)
Smoke.check("无修饰键：真闭包返回 1（面板认领，抑制系统提示音）",
            backend.simulate_area_key(area, character: "z"), 1)

# 第三种情形：面板没声明 on_key → 没人认领 → 0（换成真控件、真闭包的独立验证）
plain_renderer = Citrine::Native::Renderer.new(widgets: backend)
plain = SmokePlainPanel.new
plain_renderer.mount_component(plain, { title: "无 on_key 的面板", width: 200, height: 120 })
plain_area = plain.refs[:panel].handle
Smoke.check("未声明 on_key 的面板：真闭包返回 0（不认领任何按键）",
            backend.simulate_area_key(plain_area, character: "a"), 0)
Smoke.check("未声明 on_key 的面板：⌘ 键同样返回 0",
            backend.simulate_area_key(plain_area, character: "h", modifiers: ::LibUI::ModifierSuper), 0)

# ── 4) 面板句柄（设计 2.5）：scroll_to / 传错句柄 fail fast ───
handle.scroll_to(0, 200, 320, 100) # uiAreaScrollTo（仅滚动面板；非滚动面板后端会拦住）
Smoke.check("AreaHandle#scroll_to 在滚动面板上可用（真 uiAreaScrollTo）", true, true)

wrong_handle_raised = begin
  stray = backend.create_box(:column) # 借个真控件当"传错的句柄"
  begin
    backend.area_scroll_to(stray, 0, 0, 1, 1)
    false
  ensure
    backend.destroy(stray) # 收尾：libui 的 alloc 追踪会把漏掉的控件当泄漏报出来
  end
rescue ArgumentError
  true
end
Smoke.check("传错句柄（不是面板）会 fail fast，而不是踩野指针", wrong_handle_raised, true)

# ── 5) 有序拆解：卸载组件 → 销毁窗口 → 收尾 → uninit ─────────
Citrine.unmount(panel)
backend.window_destroy(panel_window)
Citrine.unmount(plain)
backend.window_destroy(plain_renderer.window)
Citrine.unmount(counter)
backend.window_destroy(window)
::LibUI.control_destroy(probe) # 销毁仍在容器里的 A/B
::LibUI.control_destroy(third) # 已摘除的 C
backend.shutdown

Smoke.check("拆解后面板记账清空（回调结构体 + 布局缓存都作废）", backend.live_areas, 0)

puts(Smoke.failures.zero? ? "SMOKE_OK" : "SMOKE_FAILED #{Smoke.failures}")
exit(Smoke.failures.zero? ? 0 : 1)
