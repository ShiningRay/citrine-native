# frozen_string_literal: true

module Citrine
  module Native
    # 控件适配层（决策 N-1 的"接口预留"）：渲染器只认这一层，不直接调 libui API——
    # 未来加 GTK 第二后端时只替换本层实现（GOALS 第三节）。
    #
    # 句柄（handle）是**不透明对象**：Libui 后端下是 `Fiddle::Pointer`，
    # Memory 后端下是 `Widgets::Memory::Widget`。渲染器只负责把它挂在
    # `Node#dom` 上、再原样交回本层，不解读内容（与 DOM 渲染器对待元素同一口径）。
    #
    # libui 的能力缺口在**本层**吸收，渲染器不写 `if 后端 == libui`：
    #   - box 只有 append / delete-by-index，没有 insert：顺序由本层记账后重排
    #     （`uiBoxDelete` 只摘除不销毁，实测结论见 GOALS 变更日志 N1）
    #   - 每个控件每种事件只有一个回调位：本层做多订阅分发
    #   - 自绘面板（area）的事件也只有单回调位，且 libui 调用它们前不做 NULL 检查
    #     ——五个回调槽必须在创建时全部装上
    module Widgets
      class << self
        # 默认后端：核心包不带控件实现，解析交给 Citrine::Native.default_backend
        # （后端包被 require 时自设，如 -libui 设 :libui）。测试注入 Memory 后端：
        #   Renderer.new(widgets: Widgets::Memory.new)
        def default
          backend = Citrine::Native.default_backend
          raise Citrine::Native::BackendNotSelectedError,
                "没有选择后端：请传 backend: / widgets:，或先 require 后端 gem"                 "（citrine-native-libui / citrine-native-gtk）" unless backend

          Citrine::Native.resolve_backend(backend)
        end

        # 内存打桩后端（CRuby 单测用；不加载任何 UI 工具包）
        def memory
          Memory.new
        end
      end

      # 后端协议。渲染器用到的每个方法都在此声明；后端没实现的直接抛
      # NotImplementedError（能力缺口不许静默降级成"少画一块"）。
      #
      # 线程模型（GOALS 4.4）：所有控件操作都必须在主线程做——libui 的回调
      # 本身在主线程触发，因此应用逻辑无需考虑跨线程；后台线程想更新 UI，
      # 必须用 `queue_main` 把块排回主线程。
      class Base
        # 允许后端只实现自己有的能力：声明 required 方法，缺省实现即报错
        def self.required(*names)
          names.each do |name|
            define_method(name) do |*_args, **_kwargs, &_block|
              raise NotImplementedError, "#{self.class}##{name} 未实现（控件适配层协议，见 widgets.rb）"
            end
          end
        end

        # ── 工具包生命周期与主循环 ──────────────────────────────
        # 初始化工具包（幂等；libui 后端每次调用都走 uiInit，可重复调用）
        def init; end

        # 反初始化（退出前调用；libui 后端在还有控件存活时会警告泄漏）
        def shutdown; end

        # 阻塞跑事件循环，直到 quit 被调用。所有控件回调都在这里面触发。
        required :main_loop

        # 请求退出主循环（可从回调内调用；libui 的 uiQuit 是线程安全的）
        required :quit

        # 把块排到主线程执行（后台线程更新 UI 的唯一合法通道）
        required :queue_main

        # 同 queue_main，但**块执行完就不该再被任何人引用**（可以 GC）。语义差别只在
        # "闭包是否常驻"，用于"反复排队且每次都是一次性闭包"的路径：定时器每次到点
        # （timer.rb）、绘制期延后重绘（libui.rb 的 flush_deferred_redraws）。
        # libui 后端覆写成真正不常驻的版本；缺省实现退化为 queue_main（桩后端等
        # 没有常驻问题的后端不必关心它）。
        def queue_main_once(&block)
          queue_main(&block)
        end

        # ── 窗口 ────────────────────────────────────────────────
        required :create_window, :window_set_child, :window_on_closing,
                 :window_show, :window_destroy

        # ── 容器（box：libui 的横/竖排列容器，与 stack/row 同构）──
        required :create_box, :box_append, :box_remove, :box_children

        # 把 child 挪到 target 之前（target 为 nil → 挪到末尾）。
        # 落位是平台钩子 `attach_before` 的底座，见 renderer.rb 的实现说明。
        required :box_move_before

        # 粗粒度内边距（citrine 的 gap 样式键只有 0/非 0 两档，GOALS 4.5）
        required :set_padding

        # ── 叶子控件 ────────────────────────────────────────────
        required :create_label, :create_button, :create_entry, :create_checkbox,
                 :set_text, :get_text, :set_enabled, :destroy

        # 受控值：entry 的文本、checkbox 的勾选态（双向绑定用；写入是静默的，
        # 不会反过来触发 on_change/on_toggle——两个后端都保证这一点）
        required :set_value, :get_value, :set_checked, :checked?

        # ── 事件订阅（每个控件每种事件可挂多个订阅者）──────────
        # 块在用户操作时触发；控件被销毁后不再触发。
        def on_click(_control, &_block)
          raise NotImplementedError, "#{self.class}#on_click 未实现：本后端不支持按钮点击"
        end

        # 输入变更（entry）/ 勾选变更（checkbox）都走这里——按控件种类落到原生回调
        def on_change(_control, &_block)
          raise NotImplementedError, "#{self.class}#on_change 未实现：本后端不支持变更事件"
        end

        # 回车提交（能力按后端声明）：GTK 绑 entry 的 activate；不支持的后端
        # 实现为 warn-once 的空操作（应用跨后端运行时不炸，见 Renderer#bind_events）
        def on_enter(_control, &_block)
          raise NotImplementedError, "#{self.class}#on_enter 未实现：本后端不支持回车提交"
        end

        # ── 自绘面板（area，设计 2.1 / 2.3 / 2.5）──────────────
        # 面板把绘制与输入都交给应用：适配层只负责"建控件 → 装回调 → 把事件与
        # Painter 转交订阅者"，以及三个面板特有的操作（重绘/滚动/焦点）。
        required :create_area, :area_queue_redraw

        # 订阅面板事件（每个面板每种事件一个回调位 → 与控件订阅同一套多路分发）。
        # 回调拿到的都是**平台无关**的形态：
        #   on_area_draw(area)    { |painter| }   painter 是 Painter 或 Painter::Recording
        #   on_area_pointer(area) { |event| }     event = {kind: :down/:up/:move,
        #                                                  x:, y:, button:, count:,
        #                                                  modifiers: {shift:, ctrl:, alt:, meta:}}
        #   on_area_key(area)     { |event| }     event = {key: "ArrowUp", up: false, modifiers: {…}}
        #                                         键名已归一成 DOM 风格（平台归一在适配层做）；
        #                                         块返回真值 = 已处理（libui 据此抑制系统提示音）
        #   on_area_crossed(area) { |left| }      true = 鼠标离开面板
        #   on_area_drag_broken(area) { }         拖拽被系统打断
        def on_area_draw(_area, &_block)
          raise NotImplementedError, "#{self.class}#on_area_draw 未实现：本后端不支持自绘面板"
        end

        def on_area_pointer(_area, &_block)
          raise NotImplementedError, "#{self.class}#on_area_pointer 未实现：本后端不支持自绘面板"
        end

        def on_area_key(_area, &_block)
          raise NotImplementedError, "#{self.class}#on_area_key 未实现：本后端不支持自绘面板"
        end

        # 滚轮（能力按后端声明）：载荷 {delta_x:, delta_y:, modifiers:}（beryl L1 同口径）；
        # 不支持的后端实现为 warn-once 空操作
        def on_area_wheel(_area, &_block)
          raise NotImplementedError, "#{self.class}#on_area_wheel 未实现：本后端不支持滚轮事件"
        end

        def on_area_crossed(_area, &_block)
          raise NotImplementedError, "#{self.class}#on_area_crossed 未实现：本后端不支持自绘面板"
        end

        def on_area_drag_broken(_area, &_block)
          raise NotImplementedError, "#{self.class}#on_area_drag_broken 未实现：本后端不支持自绘面板"
        end

        # 仅滚动面板：uiAreaScrollTo（非滚动面板上调它会 abort 进程，所以后端要拦住）
        def area_scroll_to(_area, _x, _y, _w, _h)
          raise NotImplementedError, "#{self.class}#area_scroll_to 未实现"
        end

        # 这个面板有没有滚动条（AreaHandle#scrollable? 用）
        def area_scrollable?(_area) = false

        # 把键盘焦点给面板（设计 2.3）：返回 true/false，做不到就如实返回 false
        def area_focus(_area) = false

        # 面板**真实可见视口**的尺寸 [w, h]（诊断 + dev_mode 的"面板被压扁"提醒用）。
        # 滚动面板下它不等于 Painter 的尺寸（后者是声明的内容尺寸）：libui 后端读
        # clip view 的真实边界。后端没有这个信息（桩后端、还没布局、非 macOS）时返回
        # nil —— 提醒逻辑据此只按 Painter 尺寸判断。
        def area_visible_size(_area) = nil

        # ── 窗口激活（设计 2.3：macOS 下 uiControlShow 之后窗口不是 key window，
        # 必须先激活应用，键盘才有人收）────────────────────────
        # 返回 true/false（后端没有激活能力时如实返回 false）
        def window_activate(_window) = false

        # 控件种类（:window/:box/:label/:button/:entry/:checkbox/:area）：诊断与断言用
        required :kind

        # 句柄 → 稳定字符串（日志与错误信息用；不参与逻辑判定）
        def describe(handle)
          "#<#{kind(handle)}>"
        end
      end
    end
  end
end

# 桩后端始终随适配层加载（不依赖 libui，测试与真实后端并存的成本只是一个小文件）。
# 放在文件末尾：Memory < Base 需要 Base 已定义。
require_relative "widgets/memory"
