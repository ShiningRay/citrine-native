# frozen_string_literal: true

require_relative "../widgets"

module Citrine
  module Native
    module Widgets
      # libui 后端（决策 N-1：v0 唯一后端）。用 kojix2/libui gem 绑定的 libui-ng
      # 动态库，控件是各平台原生控件（Cocoa / Win32 / GTK）。
      #
      # 本层吸收的三处 libui 特性（实测结论，见 GOALS 变更日志 N1）：
      # 1. `uiBoxDelete` **只摘除、不销毁**控件（探针实测：摘除后控件仍在分配表里，
      #    且 `uiControlParent` 变为 NULL），因此落位重排可以无损搬运；
      # 2. box 只有 append / delete-by-index，没有 insert-at：`box_move_before`
      #    用"摘尾部 → 追加 → 回挂尾部"实现；顺序账本在本层维护（libui 不提供
      #    child-at-index 查询）；
      # 3. 每个控件每种事件只有**一个**回调位（`uiButtonOnClicked` 是覆盖式赋值）：
      #    本层用订阅者列表做多路分发，回调只装一次。
      #
      # 句柄是 `Fiddle::Pointer`（裸指针），不是富对象——文本读取得自己 `.to_s`，
      # 生命周期完全由 Ruby 侧（渲染器的 dispose）负责：libui 不会因 GC 回收控件。
      class Libui < Base
        def initialize
          @kinds = {}       # 控件地址 => 种类（:window/:box/:label/…）
          @children = {}    # 容器地址 => [子控件]（libui 没有 child-at 查询，顺序记账）
          @stretchy = {}    # 子控件地址 => 追加时的 stretchy（重排回挂时按原样恢复）
          @subscribers = {} # [控件地址, 事件] => [块]
          @closures = []    # 强引用住 Fiddle 闭包（回调被 GC 掉就是野指针）
          @handles = {}     # 控件地址 => Fiddle::Pointer（**必须常驻**：libui gem 把
                            # Fiddle 闭包挂在指针对象上，指针被 GC 回收 = 回调变野指针）
          @areas = {}       # 面板地址 => {handler:, closures:, size:, cache:, control:, scroll:}
          @drawing = []     # 正在绘制中的面板地址（绘制期发出的重绘请求要延后，见 area_queue_redraw）
          @deferred_redraws = nil # 绘制期攒下的重绘请求：[地址 => 面板]
          require "libui"
        rescue LoadError => e
          raise Citrine::Native::ToolkitUnavailableError,
                "加载 libui 失败（#{e.message}）：citrine-native 的 v0 后端需要 libui gem。" \
                "请 `gem install libui` 或检查 Gemfile；纯逻辑测试请注入 Memory 后端" \
                "（Citrine::Native::Widgets::Memory）"
        end

        # ── 工具包生命周期与主循环 ──────────────────────────────

        def init
          # 幂等守卫：App#setup 会再调一次 init，而 Windows 的 libui 对二次 init
          # 报"registering utility window class; code 1410 类已存在"（返回错误字符串、
          # 打到 stderr）—— macOS 上第二次 init 是静默 no-op，看不出来。
          return self if @initialized

          ::LibUI.init
          @initialized = true
          self
        end

        def shutdown
          ::LibUI.uninit
          @initialized = false # 允许下一轮 init（GUI 冒烟里多个 App 顺序复用同一 backend）
          self
        end

        # 阻塞跑事件循环（所有控件回调都在这里面触发）；窗口关闭时 quit 返回
        def main_loop
          ::LibUI.main
          self
        end

        def quit
          ::LibUI.quit
          self
        end

        # 后台线程更新 UI 的唯一通道：uiQueueMain 线程安全
        def queue_main(&block)
          handler = ->(*) { safe("queue_main") { block.call } }
          @closures << handler
          ::LibUI.queue_main(handler)
          self
        end

        # 与 queue_main 同义，但闭包**不常驻**：执行完就没人再引用它（可以 GC）。
        # 用于"每帧都可能排队"的延迟重绘——常驻的写法会让自排队动画每帧漏一个闭包。
        def queue_main_once(&block)
          handler = nil
          handler = lambda do |*|
            @transient_closures.delete(handler)
            safe("延迟重绘") { block.call }
          end
          (@transient_closures ||= []) << handler
          ::LibUI.queue_main(handler)
          self
        end

        # ── 窗口 ────────────────────────────────────────────────

        def create_window(title: "Citrine", width: 640, height: 480, margined: true)
          window = ::LibUI.new_window(title.to_s, width.to_i, height.to_i, 0)
          ::LibUI.window_set_margined(window, margined ? 1 : 0)
          remember(window, :window)
        end

        def window_set_child(window, child)
          ::LibUI.window_set_child(window, child)
          # 窗口也算一层容器，只是它只有一个子控件：记账进来，
          # 销毁窗口时才能（递归）作废整棵子树里的句柄
          @children[key(window)] = [child]
          child
        end

        # 关窗回调：**一律返回 0 阻止工具包自行销毁窗口**（libui 的语义是
        # 非零 → 销毁窗口，0 → 取消关闭，见 libui-ng ui.h:423-425）。
        # 让 libui 销毁窗口的话，后续的有序拆解（卸载组件 → 销毁控件 → 销毁窗口）
        # 就会动到已释放的控件；因此"是否允许关闭"只决定要不要 quit，
        # 销毁顺序始终由 App 接管。
        def window_on_closing(window, &block)
          handler = ->(*) {
            allowed = safe("窗口关闭") { block.call } != false
            quit if allowed
            0
          }
          @closures << handler
          ::LibUI.window_on_closing(window, handler)
          self
        end

        def window_show(window)
          ::LibUI.control_show(window)
          self
        end

        # 销毁窗口会连坐它的子控件（实测），因此必须先卸载组件再销毁窗口。
        # 记账同步作废：控件已随窗口释放，留着句柄只会在后续操作里踩野指针。
        def window_destroy(window)
          addr = key(window)
          ::LibUI.control_destroy(window)
          forget_tree(addr)
          @handles.delete(addr)
          self
        end

        # ── 容器 ────────────────────────────────────────────────

        def create_box(direction)
          box = direction == :column ? ::LibUI.new_vertical_box : ::LibUI.new_horizontal_box
          remember(box, :box)
          @children[key(box)] = []
          box
        end

        # append 语义与 DOM 的 appendChild 一致：已在容器里的先摘除（搬运到末尾），
        # 否则 libui 的 uiControlSetParent 会撞"控件已有父容器"的内部断言。
        def box_append(box, child, stretchy: false)
          detach_from_parent(child)
          ::LibUI.box_append(box, child, stretchy ? 1 : 0)
          children_of(box) << child
          @stretchy[key(child)] = stretchy
          child
        end

        # 只摘除、不销毁（对应 libui 的 uiBoxDelete 语义）
        def box_remove(box, child)
          list = children_of(box)
          index = index_of(list, child)
          return false unless index

          ::LibUI.box_delete(box, index)
          list.delete_at(index)
          @stretchy.delete(key(child))
          true
        end

        def box_children(box)
          children_of(box).dup
        end

        def box_move_before(box, child, target)
          list = children_of(box)
          from = index_of(list, child)
          unless from
            raise ArgumentError, "box_move_before：控件不在目标容器里（渲染器记账与控件树不一致）"
          end

          return child if target.nil? && from == list.size - 1 # 已在末尾
          return child if target && (to = index_of(list, target)) && from == to - 1 # 已就位

          # 先摘除 child：后面的索引都以"child 已摘除"的坐标系计算
          ::LibUI.box_delete(box, from)
          list.delete_at(from)
          if target.nil? || (to = index_of(list, target)).nil?
            append_child(box, list, child)
            return child
          end

          # libui 没有 insert-at：把 target 及其后的兄弟整段摘下（从尾往前删，
          # 索引不受影响），追加 child 后再按原相对顺序回挂
          tail = list[to..] || []
          (list.size - 1).downto(to) do |i|
            ::LibUI.box_delete(box, i)
            list.delete_at(i)
          end
          append_child(box, list, child)
          tail.each { |sibling| append_child(box, list, sibling) }
          child
        end

        def set_padding(box, padded)
          ::LibUI.box_set_padded(box, padded ? 1 : 0)
          self
        end

        # ── 叶子控件 ────────────────────────────────────────────

        def create_label(text = "")
          remember(::LibUI.new_label(text.to_s), :label)
        end

        def create_button(text = "")
          remember(::LibUI.new_button(text.to_s), :button)
        end

        def create_entry(password: false)
          control = password ? ::LibUI.new_password_entry : ::LibUI.new_entry
          remember(control, :entry)
        end

        def create_checkbox(text = "", checked: false)
          control = ::LibUI.new_checkbox(text.to_s)
          ::LibUI.checkbox_set_checked(control, checked ? 1 : 0)
          remember(control, :checkbox)
        end

        def set_text(control, text)
          value = text.to_s
          case kind(control)
          when :label    then ::LibUI.label_set_text(control, value)
          when :button   then ::LibUI.button_set_text(control, value)
          when :checkbox then ::LibUI.checkbox_set_text(control, value)
          when :entry    then ::LibUI.entry_set_text(control, value)
          when :window   then ::LibUI.window_set_title(control, value)
          else raise ArgumentError, "#{describe(control)} 不支持文本内容"
          end
          self
        end

        def get_text(control)
          pointer = case kind(control)
                    when :label    then ::LibUI.label_text(control)
                    when :button   then ::LibUI.button_text(control)
                    when :checkbox then ::LibUI.checkbox_text(control)
                    when :entry    then ::LibUI.entry_text(control)
                    else raise ArgumentError, "#{describe(control)} 没有文本"
                    end
          read_text(pointer)
        end

        # 受控值写入是**静默**的（实测：uiEntrySetText / uiCheckboxSetChecked
        # 都不触发 onChanged / onToggled），因此信号 → 控件的同步不会回到信号形成环
        def set_value(control, value)
          ::LibUI.entry_set_text(control, value.to_s)
          self
        end

        def get_value(control)
          read_text(::LibUI.entry_text(control))
        end

        def set_checked(control, checked)
          ::LibUI.checkbox_set_checked(control, checked ? 1 : 0)
          self
        end

        def checked?(control)
          ::LibUI.checkbox_checked(control) != 0
        end

        def set_enabled(control, enabled)
          enabled ? ::LibUI.control_enable(control) : ::LibUI.control_disable(control)
          self
        end

        # 摘除 + 销毁（先摘再销毁：libui 的 uiControlDestroy 要求控件不带父容器，
        # 违反会直接 abort 进程）
        def destroy(control)
          detach_from_parent(control)
          if (parent = parent_of(control))
            # 走到这里说明账本与控件树不一致（漏摘或摘错了容器）——宁可报清楚的错，
            # 也不要让 libui 的 bug 检查把进程带走
            raise Error, "#{describe(control)} 销毁前仍有父容器 #{describe(parent)}：" \
                         "摘除路径没走通（控件树与适配层账本不一致）"
          end

          addr = key(control)
          ::LibUI.control_destroy(control)
          forget(addr)
          self
        end

        # ── 事件订阅（每个控件每种事件一个回调位 → 本层做多路分发）──
        # on_change 按控件种类落到原生回调：entry → uiEntryOnChanged，
        # checkbox → uiCheckboxOnToggled（勾选变更在 citrine 侧同为 on_change）

        def on_click(control, &block)
          subscribe(control, :click, &block)
        end

        def on_change(control, &block)
          subscribe(control, :change, &block)
        end

        # ── 自绘面板（area，设计 2.1/2.3）───────────────────────
        #
        # 三条实测结论（GOALS 变更日志 NA-1）：
        # 1. `uiAreaHandler` 的五个回调槽**必须全装**：libui 调用前不做 NULL 检查
        #    （darwin/area.m 里直接 `(*(a->ah->MouseCrossed))(...)`），留着 NULL 就是野指针；
        #    所以槽位在创建时装满 no-op，订阅者挂上来后由 dispatch 分发给它们。
        # 2. `uiAreaSetSize` 只对**滚动**面板有效：非滚动面板上调它，libui 走
        #    uiprivUserBug 直接 abort 进程（实测 exit 134）。所以 size: 只在
        #    scroll: true（`uiNewScrollingArea` 的内容尺寸）时落地。
        # 3. 滚动面板下 `uiAreaDrawParams.AreaWidth/AreaHeight` 是 **0**
        #    （ui.h：这两个字段 only defined for nonscrolling areas），面板尺寸得
        #    从声明的内容尺寸来。
        def create_area(size: nil, scroll: false)
          content = size && Array(size).map { |value| value.to_f.round }
          if scroll && (content.nil? || content.size != 2)
            raise ArgumentError, "滚动面板需要 size: [宽, 高]——libui 的内容尺寸在创建时定死" \
                                 "（uiNewScrollingArea），且滚动面板下 Draw 不报尺寸"
          end

          handler, closures = build_area_handler
          area = scroll ? ::LibUI.new_scrolling_area(handler, content[0], content[1])
                        : ::LibUI.new_area(handler)
          remember(area, :area)
          # 结构体与闭包必须常驻（被 GC 回收 = 回调变野指针）；文本布局缓存随面板销毁清掉
          # （libui 的对象不归 Ruby GC 管，见 Painter::TextCache）
          @areas[key(area)] = { handler: handler, closures: closures, size: content,
                                scroll: scroll == true, cache: Painter::TextCache.new,
                                control: area, area_view: nil }
          area
        end

        # 标脏 + 排一次重绘（uiAreaQueueRedrawAll = darwin 的 setNeedsDisplay:YES，合并进下一帧）。
        # **在 on_draw 里调用要延后**：AppKit 在绘制过程中忽略 setNeedsDisplay，所以
        # "在 on_draw 末尾再排一帧"这种自排队动画会静默冻在第一帧（NA-2 P2.2 实测：
        # frames=1 之后再无绘制）。绘制中发出的请求先记账，等这次绘制收尾再经 queue_main
        # 排到下一轮主循环——既出下一帧，又不会在绘制里递归重绘（同一面板一轮只排一次）。
        def area_queue_redraw(area)
          addr = key(area)
          if @drawing.include?(addr)
            (@deferred_redraws ||= {})[addr] = area
            return self
          end

          ::LibUI.area_queue_redraw_all(area)
          self
        end

        # 仅滚动面板：uiAreaScrollTo 对非滚动面板会 uiprivUserBug **终止进程**
        # （实测，与 uiAreaSetSize 同一类），所以这里拦住而不是交给 libui
        def area_scroll_to(area, x, y, w, h)
          raise ArgumentError,
                "非滚动面板没有滚动条，scroll_to 无从生效：请把元素改成 scroll: true（并给 size:）" \
                unless area_scrollable?(area)

          ::LibUI.area_scroll_to(area, x.to_f, y.to_f, w.to_f, h.to_f)
          self
        end

        def area_scrollable?(area) = area_record(area)[:scroll] == true

        # 真实可见视口（诊断 + "面板被压扁"提醒）：滚动面板取 clip view 的真实边界
        # （未夹内容尺寸、也不做正数过滤——视口塌成 0 正是要报的形状）。
        # 非滚动面板不做额外读取：Painter 的尺寸就是 libui 报的布局尺寸（= 控件 frame），
        # 没有别的信息可给，返回 nil 让提醒走"只看 Painter 尺寸"的分支。
        def area_visible_size(area)
          record = @areas[key(area)]
          return nil unless record && record[:scroll]

          rect = raw_visible_rect(record)
          rect && [rect[2], rect[3]]
        end

        # 给面板键盘焦点：libui 没有这条 API，走 Cocoa 的
        # [keyWindow makeFirstResponder: uiControlHandle(area)]（设计 2.3 的实测结论）。
        # 注意窗口得先是 key window（App 的 activate: 负责，见 window_activate）。
        def area_focus(area)
          objc.focus(::LibUI.control_handle(area))
        end

        # 激活应用（macOS）：uiControlShow 之后窗口不是 key window，一个键也收不到，
        # 必须先 [NSApp activateIgnoringOtherApps:YES]（设计 2.3 的实测结论）
        def window_activate(_window) = objc.activate

        def on_area_draw(area, &block) = subscribe(area, :draw, &block)
        def on_area_pointer(area, &block) = subscribe(area, :pointer, &block)
        def on_area_key(area, &block) = subscribe(area, :key, &block)
        def on_area_crossed(area, &block) = subscribe(area, :crossed, &block)
        def on_area_drag_broken(area, &block) = subscribe(area, :drag_broken, &block)

        # 诊断（冒烟用）：窗口是不是 key window（设计 2.3 的键盘前提——
        # uiControlShow 之后不是，必须 activate；这条断言就是那个结论的机器可验证形式）
        def window_is_key?(_window) = objc.window_key?

        # 诊断（冒烟用）：某个窗口此刻的 firstResponder（AppKit 视图地址；没有则 nil）。
        # 与 focus 的返回值对拍：契约是"返回 true ⇔ 目标真的成了 first responder"——
        # 实测只在一个方向成立（见 ObjcBridge#focus 的边界说明）。
        def window_first_responder(window) = objc.first_responder_of(::LibUI.control_handle(window))

        # 诊断（冒烟用）：对**任意视图**走一次 Cocoa 的 makeFirstResponder:。
        # AreaHandle#focus 只覆盖面板句柄；要验"AppKit 拒绝时如实返回 false"需要一个
        # 它一定会拒绝的目标（普通 NSView：不接受成为 first responder）。
        def focus_view(view) = objc.focus(view)

        # 诊断：五个回调槽是否都装上了（冒烟脚本断言"注册成功"用；读的是真结构体字段）
        def area_handler_slots(area)
          handler = area_record(area)[:handler]
          %i[Draw MouseEvent MouseCrossed DragBroken KeyEvent].select do |slot|
            pointer = handler.public_send(slot)
            !pointer.nil? && pointer.to_i != 0
          end
        end

        # 诊断（冒烟用）：合成一个 uiAreaMouseEvent / uiAreaKeyEvent，调用**已注册到 libui
        # 结构体里的那个回调闭包**——覆盖"libui 结构体 → 适配层事件视图"这段链路
        # （OS 真投递仍需人手点一次，见 GOALS 变更日志 NA-1）。
        # 与桩后端的 fire_* 同口径：不经 OS，只走 libui 真正持有的回调。
        def simulate_area_mouse(area, x:, y:, down: 0, up: 0, count: 0, modifiers: 0)
          event = ::LibUI::FFI::AreaMouseEvent.malloc
          event.X = x.to_f
          event.Y = y.to_f
          event.AreaWidth = 0.0
          event.AreaHeight = 0.0
          event.Down = down
          event.Up = up
          event.Count = count
          event.Modifiers = modifiers
          event.Held1To64 = 0
          call_area_slot(area, :MouseEvent, event)
        end

        def simulate_area_key(area, character: nil, ext_key: 0, modifiers: 0, up: 0)
          event = ::LibUI::FFI::AreaKeyEvent.malloc
          event.Key = character.to_s.empty? ? 0 : character.to_s.bytes.first
          event.ExtKey = ext_key
          event.Modifier = 0
          event.Modifiers = modifiers
          event.Up = up
          call_area_slot(area, :KeyEvent, event)
        end

        # ── 诊断 ────────────────────────────────────────────────

        def kind(handle)
          @kinds[key(handle)] ||
            raise(ArgumentError, "未知控件句柄 #{raw(handle)}：可能已被销毁，或不是本后端创建的")
        end

        def describe(handle)
          name = @kinds[key(handle)]
          name ? "#<libui #{name}>" : "#<libui 已销毁/未知控件>"
        end

        # 诊断：记账里还活着的控件数（测试断言"拆解干净、没漏控件"用）
        def live_handles = @kinds.size

        # 诊断：还活着的面板数（面板另有一套记账：回调结构体 + 文本布局缓存，
        # 拆解时都必须作废——否则就是 C 内存泄漏）
        def live_areas = @areas.size

        private

        # ── 自绘面板：回调装配与事件转发 ────────────────────────

        # 五个槽一次装满（libui 调用前不检查 NULL）。返回 [结构体, 闭包数组]，
        # 两者都由 @areas[地址] 常驻持有——闭包被 GC 掉就是野指针。
        def build_area_handler
          handler = ::LibUI::FFI::AreaHandler.malloc
          closures = []
          add = lambda do |slot, return_type, arg_types, &body|
            closure = Fiddle::Closure::BlockCaller.new(return_type, arg_types, &body)
            closures << closure
            handler.public_send("#{slot}=", closure)
          end

          add.call(:Draw, Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP] * 3) do |_handler, area, params|
            safe("面板绘制") { draw_area(key_of(area), params) }
          end
          add.call(:MouseEvent, Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP] * 3) do |_handler, area, event|
            safe("面板指针事件") { pointer_area(key_of(area), event) }
          end
          add.call(:MouseCrossed, Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT]) do |_handler, area, left|
            safe("面板鼠标进出") { dispatch_area(key_of(area), :crossed, left != 0) }
          end
          add.call(:DragBroken, Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP] * 2) do |_handler, area|
            safe("面板拖拽打断") { dispatch_area(key_of(area), :drag_broken) }
          end
          add.call(:KeyEvent, Fiddle::TYPE_INT, [Fiddle::TYPE_VOIDP] * 3) do |_handler, area, event|
            # 返回非零 = 已处理：libui 的 sendEvent 就此返回，不再走系统默认处理（未处理的
            # 按键会被 AppKit 提示音"叮"一声）。注意它**先于**菜单快捷键：所以带 ⌘ 的按键
            # 即使应用处理了也返回 0，让系统照常走菜单（⌘H/⌘⌥H 这类有绑定的菜单项属于系统，
            # NA-2 的真 OS 投递对照实验：声明 on_key 的面板曾把 ⌘H 吃掉）。
            # 返回值必须是 Integer：闭包的返回类型是 int，返回 true/false/nil 会在
            # Fiddle 边界抛 TypeError（那就穿过 libui 的 C 栈了）
            safe("面板键盘") { key_area(key_of(area), event) } ? 1 : 0
          end
          [handler, closures]
        end

        def draw_area(addr, params_ptr)
          subscribers = @subscribers[[addr, :draw]]
          record = @areas[addr]
          return if subscribers.nil? || subscribers.empty? || record.nil?

          params = ::LibUI::FFI::AreaDrawParams.new(params_ptr)
          width, height = area_viewport(record, params)
          painter = Painter.new(ctx: params.Context, width: width, height: height,
                                cache: record[:cache],
                                clip: area_clip(record, params, width, height))
          @drawing << addr
          begin
            subscribers.dup.each { |block| block.call(painter) }
          ensure
            @drawing.delete(addr)
            flush_deferred_redraws
          end
        end

        # 绘制期间攒下的重绘请求：这次绘制收尾后各排一次（面板可能已被卸载，先查记账）
        def flush_deferred_redraws
          pending = @deferred_redraws
          return if pending.nil? || pending.empty?

          @deferred_redraws = nil
          pending.each_value do |area|
            queue_main_once { ::LibUI.area_queue_redraw_all(area) if @areas.key?(key(area)) }
          end
          self
        end

        # 面板尺寸：非滚动面板用 libui 报的布局尺寸；滚动面板下那两个字段恒为 0
        # （ui.h：only defined for nonscrolling areas），退回声明的内容尺寸
        def area_viewport(record, params)
          width = params.AreaWidth.to_f
          height = params.AreaHeight.to_f
          return [width, height] if width.positive? && height.positive?

          (record[:size] || [0.0, 0.0]).map(&:to_f)
        end

        # 当前可见区（Painter#clip_rect，内容坐标）：
        # - 非滚动面板：整块面板可见。darwin 下 Clip* 报的是"需要重画的范围"（脏区），
        #   非滚动面板那一帧的脏区是**整窗**（NA-2 实测 [-20,-68,800,632]，面板只有
        #   760×528），所以不用它
        # - 滚动面板：取 areaView 的 visibleRect（= clip view 在内容坐标里的范围：
        #   origin 是滚动偏移、size 是**不含滚动条**的真实视口）。为什么不用 Clip*：
        #   Clip* 就是 drawRect 的脏区（libui-ng darwin/area.m：`dp.ClipX = r.origin.x`），
        #   滚动帧里它只是"新露出来的那条"条带（NA-2 实测 [0,900,743,100]、
        #   [0,1000,743,300]）——拿它当可见区会漏画（或画到滚动条下面）。
        #   读不到（非 macOS / 视图还没布局 / 首帧瞬态）时退回 Clip* 并夹进内容尺寸。
        def area_clip(record, params, width, height)
          return [0.0, 0.0, width, height] unless record[:scroll]

          visible = visible_area_rect(record)
          return visible if visible

          x = params.ClipX.to_f.clamp(0.0, width)
          y = params.ClipY.to_f.clamp(0.0, height)
          [x, y, params.ClipWidth.to_f.clamp(0.0, width - x), params.ClipHeight.to_f.clamp(0.0, height - y)]
        end

        # areaView 的 visibleRect 原值（内容坐标系，不夹取、不过滤）
        #
        # ⚠️ 首帧瞬态（NA-2 实测，4 次跑里 2 次）：滚动面板**第一次**绘制时这里可能
        # 报到 NSScrollView 自己的尺寸（760×560，含滚动条位）而不是视口（743×543）——
        # libui 在同一次 Draw 里才把 document view 的 frame 设上去，而这次读在它之前。
        # 稳态逐帧 0 误差。只影响"首帧就按 clip_rect 裁剪并缓存"的应用。
        def raw_visible_rect(record)
          view = record[:area_view] ||= objc.scrolling_document_view(
            ::LibUI.control_handle(record[:control])
          )
          return nil if view.nil?

          objc.rect_of(view, "visibleRect")
        end

        # 可见区（夹进声明的内容尺寸；x/y/w/h 任一非正 → nil，由调用方退回 Clip*）
        def visible_area_rect(record)
          rect = raw_visible_rect(record)
          return nil if rect.nil?

          x, y, w, h = rect
          return nil unless w.positive? && h.positive?

          size = record[:size] || [0.0, 0.0]
          [x.clamp(0.0, size[0].to_f), y.clamp(0.0, size[1].to_f),
           w.clamp(0.0, size[0].to_f - x), h.clamp(0.0, size[1].to_f - y)]
        end

        # libui 的按钮编号：1 左 / 2 中 / 3 右；Down/Up 都为 0 是移动
        def pointer_area(addr, event_ptr)
          event = ::LibUI::FFI::AreaMouseEvent.new(event_ptr)
          down = event.Down.to_i
          up = event.Up.to_i
          kind = if down.positive? then :down
                 elsif up.positive? then :up
                 else :move
                 end
          dispatch_area(addr, :pointer, kind: kind, x: event.X.to_f, y: event.Y.to_f,
                                       button: down.positive? ? down : up, count: event.Count.to_i,
                                       delta_y: 0.0, modifiers: modifiers_of(event.Modifiers))
        end

        # 面板按键：归一键名后交给订阅者（渲染器），返回值 = "要不要抑制系统默认处理"。
        # **⌘ 组合键的不吞规则不在这里做**：策略单点在 `Renderer#dispatch_area_key`
        # （桩后端与真后端同口径，也才有测试锁得住）——这一层只如实转达订阅者的答复。
        # 背景：libui 的 KeyEvent 回调先于菜单快捷键，认领 ⌘ 会让 ⌘H/⌘⌥H（以及应用自己用
        # uiNewMenu 建的菜单项）在焦点落到面板时失效；回调本身照常触发（⌘Z 不受影响）。
        def key_area(addr, event_ptr)
          event = ::LibUI::FFI::AreaKeyEvent.new(event_ptr)
          key = key_name(event.Key, event.ExtKey)
          # Key 与 ExtKey 都是 0 = 修饰键自身的按下/抬起（flagsChanged），不投递给应用
          return false if key.nil?

          dispatch_area(addr, :key, key: key, up: event.Up != 0,
                                    modifiers: modifiers_of(event.Modifiers))
        end

        # 平台按键归一（DOM 风格键名）：ExtKey 优先，否则用字符。
        # macOS 下 libui 给的是**与 Shift 无关的等位字符**（keycode 表：'\n' Enter、
        # '\t' Tab、'\b' Backspace、' ' 空格、其余小写字母/数字），Shift 走 modifiers，
        # 所以应用里判断大写请用 shift?（与 DOM 的 ev.key 不同，见 README 限制）。
        def key_name(char_code, ext_key)
          named = ext_key_names[ext_key.to_i]
          return named if named

          code = char_code.to_i
          # libui 的 Key 是 ASCII 等位字符（表里只有 ASCII），非 ASCII 字节不猜
          return nil unless code.positive? && code < 128

          case (char = code.chr(Encoding::UTF_8))
          when "\n" then "Enter"
          when "\t" then "Tab"
          when "\b" then "Backspace"
          else char
          end
        end

        def ext_key_names
          @ext_key_names ||= {
            ::LibUI::ExtKeyEscape => "Escape",
            ::LibUI::ExtKeyInsert => "Insert",
            ::LibUI::ExtKeyDelete => "Delete",
            ::LibUI::ExtKeyHome => "Home",
            ::LibUI::ExtKeyEnd => "End",
            ::LibUI::ExtKeyPageUp => "PageUp",
            ::LibUI::ExtKeyPageDown => "PageDown",
            ::LibUI::ExtKeyUp => "ArrowUp",
            ::LibUI::ExtKeyDown => "ArrowDown",
            ::LibUI::ExtKeyLeft => "ArrowLeft",
            ::LibUI::ExtKeyRight => "ArrowRight",
            ::LibUI::ExtKeyF1 => "F1", ::LibUI::ExtKeyF2 => "F2",
            ::LibUI::ExtKeyF3 => "F3", ::LibUI::ExtKeyF4 => "F4",
            ::LibUI::ExtKeyF5 => "F5", ::LibUI::ExtKeyF6 => "F6",
            ::LibUI::ExtKeyF7 => "F7", ::LibUI::ExtKeyF8 => "F8",
            ::LibUI::ExtKeyF9 => "F9", ::LibUI::ExtKeyF10 => "F10",
            ::LibUI::ExtKeyF11 => "F11", ::LibUI::ExtKeyF12 => "F12",
            # 小键盘：数字与小数点按 DOM 的取值（'0'..'9'/'.'），运算符同理
            ::LibUI::ExtKeyN0 => "0", ::LibUI::ExtKeyN1 => "1",
            ::LibUI::ExtKeyN2 => "2", ::LibUI::ExtKeyN3 => "3",
            ::LibUI::ExtKeyN4 => "4", ::LibUI::ExtKeyN5 => "5",
            ::LibUI::ExtKeyN6 => "6", ::LibUI::ExtKeyN7 => "7",
            ::LibUI::ExtKeyN8 => "8", ::LibUI::ExtKeyN9 => "9",
            ::LibUI::ExtKeyNDot => ".", ::LibUI::ExtKeyNEnter => "Enter",
            ::LibUI::ExtKeyNAdd => "+", ::LibUI::ExtKeyNSubtract => "-",
            ::LibUI::ExtKeyNMultiply => "*", ::LibUI::ExtKeyNDivide => "/"
          }.freeze
        end

        def modifiers_of(mask)
          bits = mask.to_i
          {
            shift: (bits & ::LibUI::ModifierShift) != 0,
            ctrl: (bits & ::LibUI::ModifierCtrl) != 0,
            alt: (bits & ::LibUI::ModifierAlt) != 0,
            meta: (bits & ::LibUI::ModifierSuper) != 0
          }
        end

        # 多路分发（与控件订阅同一套）：任一订阅者返回真值即视为"已处理"
        def dispatch_area(addr, event, *args)
          subscribers = @subscribers[[addr, event]]
          return false if subscribers.nil? || subscribers.empty?

          handled = false
          subscribers.dup.each { |block| handled = true if block.call(*args) }
          handled
        end

        def area_record(area) = @areas[key(area)] ||
          raise(ArgumentError, "#{describe(area)} 不是本后端的自绘面板（或已销毁）")

        # 诊断用：直接调用结构体里那个回调闭包（调用的方式与 libui 调它一致）
        def call_area_slot(area, slot, event)
          pointer = area_record(area)[:handler].public_send(slot)
          if pointer.nil? || pointer.to_i.zero?
            raise Error, "#{describe(area)} 的 #{slot} 回调槽没装上"
          end

          return_type = slot == :KeyEvent ? Fiddle::TYPE_INT : Fiddle::TYPE_VOID
          function = Fiddle::Function.new(pointer.to_i, [Fiddle::TYPE_VOIDP] * 3, return_type)
          function.call(0, area, event)
        end

        # 回调拿到的 area 是 Fiddle::Pointer（或地址），记账键统一用地址
        def key_of(area) = area.to_i

        # macOS 直通桥（懒建：非 macOS 上 dlopen 失败 → available? 为 false）
        def objc
          @objc ||= ObjcBridge.new
        end

        # ── macOS/Cocoa 直通（libui 公开 API 的能力缺口）────────
        # 设计 2.3 的实测结论：`uiControlShow` 之后窗口**不是 key window**
        # （[NSApp keyWindow] 为 nil、firstResponder 为 nil）→ 一个键也收不到；
        # `[NSApp activateIgnoringOtherApps:YES]` 之后窗口变 key、area 自动成为
        # first responder，键盘事件实测可达。libui 没有暴露这条能力，只能自己调。
        # 非 macOS（或 libobjc 不可用）时 available? 为 false，调用方返回 false 如实上报。
        class ObjcBridge
          def initialize
            lib = Fiddle.dlopen("/usr/lib/libobjc.A.dylib")
            @sel = Fiddle::Function.new(lib["sel_registerName"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
            @get_class = Fiddle::Function.new(lib["objc_getClass"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
            @msg = Fiddle::Function.new(lib["objc_msgSend"],
                                        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
            @msg_int = Fiddle::Function.new(lib["objc_msgSend"],
                                            [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
                                            Fiddle::TYPE_VOIDP)
            @msg_ptr = Fiddle::Function.new(lib["objc_msgSend"],
                                            [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                                            Fiddle::TYPE_VOIDP)
            @msg_void = Fiddle::Function.new(lib["objc_msgSend"],
                                             [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                                              Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
                                             Fiddle::TYPE_VOID)
            # 返回 BOOL 的方法（makeFirstResponder:）必须用 char 返回类型读——
            # 用 TYPE_VOIDP 读小整数返回值在 AArch64 上拿到的是寄存器残值，不是 0/1
            @msg_bool = Fiddle::Function.new(lib["objc_msgSend"],
                                             [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                                             Fiddle::TYPE_CHAR)
            @rect_keys = {}
            @available = true
          rescue StandardError
            @available = false
          end

          def available? = @available

          def activate
            return false unless available?

            app = shared_application
            return false if app.to_i.zero?

            @msg_int.call(app, selector("activateIgnoringOtherApps:"), 1)
            true
          end

          # 把 first responder 交给 view，**如实转达结果**（NA-2 P3 的必修项；NA-1d 加强）。
          # 旧写法只要"窗口是 key window"就 return true——应用侧按契约检查返回值也察觉不到
          # AppKit 拒绝。现在返回**两层判据的合取**：
          #   ① `[NSWindow makeFirstResponder:]` 的 BOOL（用 char 返回类型读）**受理**了请求；
          #   ② 窗口此刻的 `firstResponder` **真的是这个视图**（或它的后代——滚动面板的
          #      first responder 是 document view/areaView，不是 NSScrollView 本身）。
          #
          # 为什么不能只报 ①（NA-1d 探针 5 实测，macOS 26 / arm64）：只要窗口是 key window，
          # 这个 BOOL 对**接受与不接受** first responder 的目标**都返回 YES**——目标没拿到
          # 焦点时 AppKit 把**窗口自己**设成 first responder，返回值却是 YES（实测目标：
          # 游离 areaView、不可编辑的 NSTextField、普通 boxView/NSView 全是 YES）。只报 ①
          # 就是"转达了一个不诚实的答复"；加上 ② 之后，返回值 ⇔ "焦点真的落到目标上"。
          def focus(view)
            return false unless available?
            return false if view.to_i.zero?

            window = @msg.call(shared_application, selector("keyWindow"))
            return false if window.to_i.zero?

            return false if @msg_bool.call(window, selector("makeFirstResponder:"), view).zero?

            responder = @msg.call(window, selector("firstResponder"))
            descendant_or_self?(responder, view)
          end

          # responder 是 view 本身或它的后代？（`isDescendantOf:`，都返回 BOOL）
          # 先 `isKindOfClass:NSView` 再问：窗口自己（uiprivNSWindow）也会成为 first
          # responder，而它不是 NSView——直接发 `isDescendantOf:` 会抛 ObjC 异常，
          # **那是不可捕获的**（进程直接终止，见 rect_of 的限制一）。
          def descendant_or_self?(responder, view)
            return false if responder.to_i.zero?
            return true if responder.to_i == view.to_i

            ns_view = @get_class.call("NSView")
            return false if @msg_bool.call(responder, selector("isKindOfClass:"), ns_view).zero?

            !@msg_bool.call(responder, selector("isDescendantOf:"), view).zero?
          end

          # 某个窗口此刻的 firstResponder（诊断用：冒烟拿它和 focus 的返回值对拍）。
          # 走**给定的窗口**而不是 [NSApp keyWindow]，这样窗口不是 key 时也能读
          # （AppKit 会保留已设的 first responder）。没有 first responder 时返回 nil。
          def first_responder_of(window)
            return nil unless available?
            return nil if window.to_i.zero?

            responder = @msg.call(window, selector("firstResponder"))
            responder.to_i.zero? ? nil : responder
          end

          # [NSApp keyWindow] 非 nil？（键盘投递的前提；返回指针类型，读返回值是安全的）
          def window_key?
            return false unless available?

            !@msg.call(shared_application, selector("keyWindow")).to_i.zero?
          end

          # NSScrollView → 它的 document view（= libui 的 areaView：内容坐标系的原点
          # 与 Painter 的坐标同一套）。不是滚动视图 / 还没建好时返回 nil。
          def scrolling_document_view(scroll_view)
            return nil unless available? && !scroll_view.to_i.zero?

            document = @msg.call(scroll_view, selector("documentView"))
            document.to_i.zero? ? nil : document
          rescue StandardError
            nil
          end

          # 读一个 NSRect 属性（visibleRect / bounds / frame…）。
          # Fiddle 拿不到 32 字节的结构体返回值，所以绕一步：KVC 把 struct 属性包成
          # NSValue，再用 `getValue:size:`（参数全是指针）拷进我们自己的 buffer。
          # 失败（键不存在 / 不是 NSValue）返回 nil，调用方自己兜底。
          #
          # ⚠️ 限制一（NA-2 实测，**会带走整个进程**）：KVC 键不存在、或对非滚动视图发
          # `documentView` 会抛 **Objective-C 异常**——它不是 Ruby 异常，`rescue
          # StandardError` 抓不住，进程直接终止（`NSInvalidArgumentException`）。
          # 所以调用方必须保证键存在且句柄类型对：框架只对 record[:scroll] 的面板读
          # `visibleRect`，而那时句柄确实是 NSScrollView（改这里前先复核这条前提）。
          #
          # ⚠️ 限制二（野读不崩、静默给陈旧值）：面板销毁后拿缓存下来的视图指针再读
          # 不会崩，而是返回"看着像真的"的旧值（实测 [0,0,543,343]）——靠"销毁后不读"
          # 的不变量兜住（draw_area 查 @areas、flush_deferred_redraws 查记账、
          # forget 里 cache.clear!），不是靠这里报错。
          def rect_of(view, key)
            return nil unless available? && !view.to_i.zero?

            value = @msg_ptr.call(view, selector("valueForKey:"), rect_key(key))
            return nil if value.to_i.zero?

            buffer = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE * 4, Fiddle::RUBY_FREE)
            @msg_void.call(value, selector("getValue:size:"), buffer, Fiddle::SIZEOF_DOUBLE * 4)
            buffer[0, Fiddle::SIZEOF_DOUBLE * 4].unpack("d4")
          rescue StandardError
            nil
          end

          private

          # KVC 的键字符串：创建后 retain 一份常驻（`stringWithUTF8String:` 返回的是
          # autorelease 对象，缓存里不 retain 就会在自动释放池排干后变野指针）。
          # 每个键只建一次（绘制每帧都会用到，不能每帧建 NSString）。
          #
          # ⚠️ 这条 retain 对**短键是 no-op、对长键是保命**（NA-2 实测，边界在 11/12 字符）：
          # - 长度 ≤ 11 的键（当前唯一用到的 `"visibleRect"` 就是 11）拿到的是 tagged pointer /
          #   `__NSCFConstantString`，retainCount = -1（immortal）；消融掉这行行为完全一样。
          # - 长度 ≥ 12 的键拿到的是真 `__NSCFString`（autorelease 对象）：池排干后再读
          #   **进程 exit 133（SIGTRAP）崩溃**（NA-2 用 15 字符键复现）。
          # `rect_of` 的契约写着支持 visibleRect / bounds / frame…，所以 retain 作为通用
          # 防御保留——别按"当前这个键的现状"删掉它。
          def rect_key(key)
            @rect_keys[key] ||= begin
              name = @msg_ptr.call(@get_class.call("NSString"),
                                   selector("stringWithUTF8String:"), key)
              @msg.call(name, selector("retain"))
            end
          end

          def shared_application
            @msg.call(@get_class.call("NSApplication"), selector("sharedApplication"))
          end

          def selector(name) = @sel.call(name)
        end

        # ── 记账（libui 没有 child-at 查询，顺序只能自己记）────────

        def remember(handle, kind)
          @kinds[key(handle)] = kind
          @handles[key(handle)] = handle # 常驻引用：句柄被 GC 会连带回收它的回调闭包
          handle
        end

        def forget(addr)
          @kinds.delete(addr)
          @children.delete(addr)
          @stretchy.delete(addr)
          @handles.delete(addr)
          # 面板：布局缓存必须在 uiUninit 之前释放（libui 的 text layout / attributed
          # string / 字体描述符不归 Ruby GC 管）；结构体与闭包随记账一起作废
          @areas.delete(addr)&.fetch(:cache)&.clear!
          @subscribers.delete_if { |(sub_addr, _event), _| sub_addr == addr }
        end

        # 容器销毁会连坐子控件（实测），记账要跟着整棵作废
        def forget_tree(addr)
          children_of_addr(addr).each { |child| forget_tree(key(child)) }
          forget(addr)
        end

        def children_of_addr(addr)
          (@children[addr] || []).dup
        end

        def children_of(box)
          @children[key(box)] ||= []
        end

        # libui 返回的字符串是库自己分配的（*_text / *_title），读完必须 free_text，
        # 否则每次读取都漏一段 C 内存（适配层的读路径在事件回调里）。
        # Fiddle 的 Pointer#to_s 不做编码推断，拿到的 String 是 ASCII-8BIT——
        # 中文文本直接比较/拼接都会错，这里统一按 UTF-8 解释。
        def read_text(pointer)
          return "" if pointer.nil? || pointer.null?

          text = pointer.to_s.dup.force_encoding(Encoding::UTF_8)
          ::LibUI.free_text(pointer)
          text
        end

        def append_child(box, list, child)
          ::LibUI.box_append(box, child, @stretchy.fetch(key(child), false) ? 1 : 0)
          list << child
        end

        def detach_from_parent(child)
          parent = parent_of(child)
          return false unless parent
          # 父子关系以本层记账为准（libui 的 uiBoxDelete 需要索引，而它不提供 child-at 查询）；
          # 只有 box 支持"摘除"——窗口虽然也记了一笔，但它没有摘除 API
          return box_remove(parent, child) if @children.key?(key(parent)) && @kinds[key(parent)] == :box

          # 父容器是窗口（根容器）：窗口只有一个 child，没有摘除 API——
          # 这条路径不该出现（根容器由 App 连窗口一起销毁）
          raise ArgumentError, "#{describe(child)} 的父容器是窗口，不能单独摘除" \
                               "（窗口与其内容同生命周期）"
        end

        def parent_of(control)
          pointer = ::LibUI.control_parent(control)
          return nil if pointer.nil? || pointer.to_i.zero?

          pointer
        end

        def index_of(list, child)
          addr = key(child)
          list.index { |candidate| key(candidate) == addr }
        end

        def key(handle)
          handle.to_i
        end

        def raw(handle)
          format("0x%x", key(handle))
        end

        # ── 事件分发 ────────────────────────────────────────────

        def subscribe(control, event, &block)
          raise ArgumentError, "事件订阅需要块（#{describe(control)} #{event}）" unless block

          subs = (@subscribers[[key(control), event]] ||= [])
          subs << block
          register_native_callback(control, event) if subs.size == 1
          block
        end

        # libui 的每个控件每种事件只有一个回调位 → 只装一次，内部再分发。
        # 面板（area）的五个槽在 create_area 时就装满了（libui 调它们前不检查 NULL），
        # 这里只登记订阅者、不再装回调。
        def register_native_callback(control, event)
          return if kind(control) == :area

          handler = ->(*) { dispatch(control, event) }
          @closures << handler
          case [kind(control), event]
          when [:button, :click]     then ::LibUI.button_on_clicked(control, handler)
          when [:entry, :change]     then ::LibUI.entry_on_changed(control, handler)
          when [:checkbox, :change]  then ::LibUI.checkbox_on_toggled(control, handler)
          else raise ArgumentError, "#{describe(control)} 不支持事件 #{event.inspect}"
          end
        end

        def dispatch(control, event)
          subs = @subscribers[[key(control), event]]
          return if subs.nil? || subs.empty?

          subs.dup.each do |block|
            safe("#{describe(control)} 的 #{event} 回调") { block.call }
          end
        end

        # 回调体一律不把异常抛回 C/Objective-C 栈（Fiddle 闭包里抛出会走未定义路径，
        # 轻则丢事件重则崩进程）；代价是这里"只报不抛"：事件处理器里的异常打到
        # stderr 并继续跑主循环，而不是把整个 GUI 带走。
        def safe(context)
          yield
        rescue StandardError => e
          warn "[citrine-native] #{context} 抛出 #{e.class}: #{e.message}"
          warn(e.backtrace.first(8).map { |line| "    #{line}" }.join("\n"))
          nil
        end
      end
    end
  end
end
