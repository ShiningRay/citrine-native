# frozen_string_literal: true

require_relative "../widgets"
require_relative "../painter"

module Citrine
  module Native
    module Widgets
      # 内存打桩后端：控件树只有结构、文本与回调，不做任何真实绘制——
      # 供 CRuby 单测断言渲染器语义（GOALS 风险 3：CI 不能开真窗口）。
      # 与主仓"Node 桩验收"同一思路：同一份组件代码，桩控件树上断言结构等价。
      #
      #   backend = Widgets::Memory.new
      #   renderer = Renderer.new(widgets: backend)
      #   root = renderer.mount_component(Counter, {})
      #   backend.fire(backend.find(root.dom, kind: :button), :click)
      #   assert_equal "计数：1", backend.text_of(...)
      class Memory < Base
        # 桩控件句柄：渲染器只当作不透明对象用（与 Fiddle::Pointer 同地位）
        class Widget
          attr_reader :kind, :children, :events
          attr_accessor :text, :value, :checked, :enabled, :padded, :direction, :parent

          def initialize(kind, text: "", value: "", checked: false, direction: nil)
            @kind = kind
            @text = text
            @value = value
            @checked = checked
            @direction = direction
            @enabled = true
            @padded = false
            @children = []
            @events = Hash.new { |hash, key| hash[key] = [] }
            @destroyed = false
            @callback_count = {}
          end

          def container? = kind == :box
          def destroyed? = @destroyed
          def destroyed! = @destroyed = true

          # 测试用：模拟用户操作（点击 / 输入变更 / 勾选变更）
          def fire(event, *)
            raise ArgumentError, "#{kind} 已被销毁，不能再触发事件" if @destroyed

            @events[event].dup.each(&:call)
            self
          end

          def subscribers(event) = @events[event]

          # 诊断：桩后端如实记录"装了几个原生回调"——libui 每个控件每种事件只有
          # 一个回调位，多订阅必须复用它（测试可断言不重复安装）
          def callback_count(event) = @callback_count[event].to_i

          def install_callback(event)
            @callback_count[event] = @callback_count[event].to_i + 1
          end

          def describe
            "#<memory #{kind}#{@destroyed ? ' 已销毁' : ''}>"
          end
        end

        def initialize
          @created = []
          @loop_hook = nil
          @quit = false
        end

        # 测试挂钩：main_loop 里执行一次（模拟"用户操作 → 关窗"），再回到调用方
        def on_main_loop(&block)
          @loop_hook = block
          self
        end

        def init = self
        def shutdown = self

        def main_loop
          @quit = false
          @loop_hook&.call(self)
          self
        end

        def quit
          @quit = true
          self
        end

        def quit? = @quit

        # 测试用：本后端创建的窗口（`run` 之前只有一个）
        def window = @created.find { |widget| widget.kind == :window }

        # 桩后端没有主线程概念：直接执行（渲染器语义不依赖线程模型）。
        # 排队记账（见 queue_log）是为了让"这条路径不许排常驻闭包"这类断言在桩上就锁得住。
        def queue_main(&block)
          queue_log << :resident
          block.call
          self
        end

        # 桩后端不持有闭包，所以这里只记一笔"一次性排队"（真后端由 libui.rb 覆写成
        # 执行后释放引用的版本）。定时器/延后重绘必须走这条。
        def queue_main_once(&block)
          queue_log << :transient
          block.call
          self
        end

        # 排队记账（诊断/测试断言用）：每次 queue_main / queue_main_once 追加一个
        # :resident / :transient。常驻闭包在 libui 后端是真内存泄漏（Fiddle 闭包不能被 GC），
        # 桩后端没有这个问题，但"哪条路径用了哪个槽"是后端无关的语义
        def queue_log = (@queue_log ||= [])

        # ── 窗口 ────────────────────────────────────────────────

        def create_window(title: "Citrine", width: 640, height: 480, margined: true)
          track(Widget.new(:window, text: title).tap { |w| w.instance_variable_set(:@meta, { title:, width:, height:, margined: }) })
        end

        # 桩后端没有"应用激活"这回事：只记账，供测试断言 App 调过它
        def window_activate(window)
          window.instance_variable_set(:@activated, true)
          true
        end

        def activated?(window) = window.instance_variable_get(:@activated) == true

        def window_options(window) = window.instance_variable_get(:@meta)

        def window_set_child(window, child)
          adopt(window, child)
          child
        end

        def window_on_closing(window, &block)
          # 与 libui 后端同契约：允许关闭 → 由适配层 quit（窗口销毁顺序留给 App）
          window.events[:closing] << proc do
            allowed = block.call != false
            quit if allowed
            allowed
          end
          self
        end

        # 测试用：模拟用户关窗（返回 false 表示被应用阻止）
        def fire_closing(window)
          allowed = true
          window.events[:closing].each { |handler| allowed = false if handler.call == false }
          allowed
        end

        def window_show(window)
          window.instance_variable_set(:@shown, true)
          self
        end

        def shown?(window) = window.instance_variable_get(:@shown) == true

        def window_destroy(window)
          window.children.dup.each { |child| destroy(child) }
          window.children.clear
          window.destroyed!
          window
        end

        # ── 容器 ────────────────────────────────────────────────

        def create_box(direction)
          track(Widget.new(:box, direction: direction))
        end

        def box_append(box, child, stretchy: false)
          detach_from_parent(child)
          box.children << child
          child.parent = box
          child.instance_variable_set(:@stretchy, stretchy)
          child
        end

        def box_remove(box, child)
          index = box.children.index(child)
          return false unless index

          box.children.delete_at(index)
          child.parent = nil
          true
        end

        def box_children(box) = box.children.dup

        def box_move_before(box, child, target)
          raise ArgumentError, "box_move_before：控件不在目标容器里" unless box.children.include?(child)

          box.children.delete(child)
          index = target ? box.children.index(target) : nil
          index ? box.children.insert(index, child) : box.children.push(child)
          child
        end

        def set_padding(box, padded)
          box.padded = padded ? true : false
          self
        end

        # ── 叶子控件 ────────────────────────────────────────────

        def create_label(text = "") = track(Widget.new(:label, text: text.to_s))
        def create_button(text = "") = track(Widget.new(:button, text: text.to_s))

        def create_entry(password: false)
          track(Widget.new(:entry).tap { |w| w.instance_variable_set(:@password, password) })
        end

        def password?(entry) = entry.instance_variable_get(:@password) == true

        def create_checkbox(text = "", checked: false)
          track(Widget.new(:checkbox, text: text.to_s, checked: checked))
        end

        def set_text(control, text)
          control.text = text.to_s
          self
        end

        def get_text(control) = control.text.to_s

        def set_value(control, value)
          control.value = value.to_s
          self
        end

        def get_value(control) = control.value.to_s

        def set_checked(control, checked)
          control.checked = checked ? true : false
          self
        end

        def checked?(control) = control.checked == true

        def set_enabled(control, enabled)
          control.enabled = enabled ? true : false
          self
        end

        def enabled?(control) = control.enabled == true

        # 桩后端不模拟销毁连坐（真实后端会）：测试要断言"渲染器逐个销毁了控件"
        def destroy(control)
          detach_from_parent(control)
          control.children.dup.each { |child| destroy(child) }
          control.children.clear
          control.destroyed!
          control
        end

        # ── 事件（与 libui 后端同口径：on_change 按控件种类落位）──
        # 测试模拟用户操作：button fire(:click)、entry fire(:change)、checkbox fire(:toggle)

        def on_click(control, &block)
          subscribe(control, :click, &block)
        end

        def on_change(control, &block)
          subscribe(control, control.kind == :checkbox ? :toggle : :change, &block)
        end

        # ── 自绘面板（area）────────────────────────────────────
        # 桩后端不做真绘制：draw 交给 Painter::Recording（记录图元序列），
        # 指针/键盘事件由测试用 fire_* 合成（形状与 libui 后端一致）。

        # 真实可见视口：桩后端没有布局引擎，只有测试显式给的值（set_visible_size）。
        # 默认 nil = "这个后端没有额外几何信息"（提醒逻辑据此只看 Painter 尺寸）
        def area_visible_size(area) = area.instance_variable_get(:@visible_size)

        # 测试模拟"视口塌了"（真后端上读的是 clip view 的真实边界）
        def set_visible_size(area, width, height)
          area.instance_variable_set(:@visible_size, [width.to_f, height.to_f])
          self
        end

        # 默认视口：桩后端没有布局引擎，"撑满父容器"无从得知——测试要别的尺寸
        # 就传 width:/height:（真后端这里是 libui 报的布局尺寸）
        DEFAULT_AREA_VIEWPORT = [200, 100].freeze

        def create_area(size: nil, scroll: false)
          track(Widget.new(:area).tap do |area|
            area.instance_variable_set(:@size, size && Array(size).map(&:to_f))
            area.instance_variable_set(:@scroll, scroll == true)
            area.instance_variable_set(:@redraws, 0)
          end)
        end

        def area_queue_redraw(area)
          # 绘制期间发出的重绘请求要**延后到这次绘制结束**（真后端是排到下一轮主循环）：
          # darwin 的 AppKit 在 drawRect 里忽略 setNeedsDisplay，直接排会被静默丢掉，
          # "在 on_draw 末尾再排一帧"的自排队动画就冻在第一帧（NA-2 P2.2）。
          if @drawing&.include?(area)
            (@deferred_redraws ||= []) << area
            return self
          end

          bump_redraw(area)
          self
        end

        def on_area_draw(area, &block) = subscribe(area, :draw, &block)
        def on_area_pointer(area, &block) = subscribe(area, :pointer, &block)
        def on_area_key(area, &block) = subscribe(area, :key, &block)
        def on_area_crossed(area, &block) = subscribe(area, :crossed, &block)
        def on_area_drag_broken(area, &block) = subscribe(area, :drag_broken, &block)

        # 仅滚动面板（与 libui 后端同一口径：非滚动面板 fail fast，
        # libui 那边真调下去会终止进程）
        def area_scroll_to(area, x, y, w, h)
          raise ArgumentError,
                "非滚动面板没有滚动条，scroll_to 无从生效：请把元素改成 scroll: true（并给 size:）" \
                unless area_scrollable?(area)

          area.instance_variable_set(:@scroll_to, [x.to_f, y.to_f, w.to_f, h.to_f])
          self
        end

        def area_scrollable?(area) = area.instance_variable_get(:@scroll) == true

        # 桩后端没有焦点：只记账（测试断言"应用/App 要过焦点"）
        def area_focus(area)
          area.instance_variable_set(:@focused, true)
          true
        end

        def focused?(area) = area.instance_variable_get(:@focused) == true

        # 最近一次滚动请求（测试断言）
        def scrolled_to(area) = area.instance_variable_get(:@scroll_to)

        # ── 面板诊断与测试模拟（真后端由 libui 的 OS 事件驱动）──

        # 声明的内容尺寸（create_area 时给的 size:），滚动面板下也是绘制视口
        def area_size(area) = area.instance_variable_get(:@size)
        def scrolling?(area) = area.instance_variable_get(:@scroll) == true

        # 队列重绘被调用了几次（渲染器去重后应恰好一次/收敛）
        def redraw_count(area) = area.instance_variable_get(:@redraws).to_i

        # 绘制期间攒下的重绘请求：这次绘制收尾后各补一次（同一面板一轮只补一次）
        def flush_deferred_redraws
          pending = @deferred_redraws
          return if pending.nil? || pending.empty?

          @deferred_redraws = nil
          pending.uniq.each { |area| bump_redraw(area) }
          self
        end

        # 诊断：是不是正在绘制这个面板（测试断言"绘制期不递归重绘"用）
        def drawing?(area) = @drawing&.include?(area) == true

        # 最近一次绘制的记录器（"画了什么"的断言入口）
        def painting(area) = area.instance_variable_get(:@painting)

        # 跑一次绘制：把 Painter::Recording（记录图元，不画）交给 on_draw 的订阅者。
        # 绘制期间的重绘请求延后到收尾（与真后端同契约，见 area_queue_redraw）。
        def fire_draw(area, width: nil, height: nil)
          ensure_live!(area, "绘制")
          size = area_size(area) || DEFAULT_AREA_VIEWPORT
          painter = Painter::Recording.new(width: width || size[0], height: height || size[1])
          @drawing = (@drawing || []) << area
          begin
            area.events[:draw].dup.each { |handler| handler.call(painter) }
          ensure
            @drawing.delete(area)
            flush_deferred_redraws
          end
          area.instance_variable_set(:@painting, painter)
          painter
        end

        # 点击 = 按下 + 抬起（渲染器负责配对成 "click"，与 libui 的 Down/Up 一致）
        def fire_click(area, x = 0, y = 0, button: 1, modifiers: {}, count: 1)
          fire_mouse_down(area, x, y, button: button, count: count, modifiers: modifiers)
          fire_mouse_up(area, x, y, button: button, modifiers: modifiers)
        end

        def fire_mouse_down(area, x = 0, y = 0, button: 1, count: 1, modifiers: {})
          fire_pointer(area, kind: :down, x: x, y: y, button: button, count: count, modifiers: modifiers)
        end

        def fire_mouse_up(area, x = 0, y = 0, button: 1, modifiers: {})
          fire_pointer(area, kind: :up, x: x, y: y, button: button, count: 0, modifiers: modifiers)
        end

        def fire_mouse_move(area, x = 0, y = 0, button: 0, modifiers: {})
          fire_pointer(area, kind: :move, x: x, y: y, button: button, count: 0, modifiers: modifiers)
        end

        def fire_pointer(area, kind:, x: 0, y: 0, button: 1, count: 1, modifiers: {})
          ensure_live!(area, "指针事件")
          dispatch_area(area, :pointer, kind: kind, x: x.to_f, y: y.to_f, button: button,
                                        count: count, modifiers: modifiers)
        end

        # 键盘：key 用 DOM 风格键名（真后端由适配层把 libui 的按键归一成它）
        # 返回 true 表示有订阅者认领了这次按键（真后端据此抑制系统提示音）
        def fire_key(area, key, modifiers: {}, up: false)
          ensure_live!(area, "键盘事件")
          dispatch_area(area, :key, key: key, up: up, modifiers: modifiers)
        end

        def fire_crossed(area, left: false)
          ensure_live!(area, "鼠标进出")
          dispatch_area(area, :crossed, left)
        end

        def fire_drag_broken(area)
          ensure_live!(area, "拖拽打断")
          dispatch_area(area, :drag_broken)
        end

        # ── 诊断 ────────────────────────────────────────────────

        def kind(handle) = handle.kind
        def describe(handle) = handle.describe

        def created = @created.dup
        def live_widgets = @created.reject(&:destroyed?)
        def destroyed_widgets = @created.select(&:destroyed?)

        # 测试用：在子树里按种类找控件
        # 测试用：在子树里按种类找控件。
        # ⚠️ 两个方法都**必须传句柄**（子树根，通常是 `container` 或某个 box 句柄）——
        # 桩后端没有"全局控件表"可查，句柄是唯一入口（backlog F6）。便捷写法：
        # NativeTest 的 `find(kind:)` / `find_all(kind:)` 已经带上了 `container`。
        def find(handle, kind: nil, text: nil)
          return handle if matches?(handle, kind, text)

          handle.children.each do |child|
            found = find(child, kind: kind, text: text)
            return found if found
          end
          nil
        end

        def find_all(handle, kind: nil)
          out = matches?(handle, kind, nil) ? [handle] : []
          handle.children.each { |child| out.concat(find_all(child, kind: kind)) }
          out
        end

        # 测试用：控件树快照（结构断言的可读形式）
        #   ["box column", ["label", "计数：0"], ["button", "点我 +1"]]
        def tree(handle)
          label = case handle.kind
                  when :box then "box #{handle.direction}"
                  when :window then "window #{handle.text.inspect}"
                  else handle.kind.to_s
                  end
          if handle.container? || handle.kind == :window
            [label, *handle.children.map { |child| tree(child) }]
          else
            [label, handle.text.to_s]
          end
        end

        private

        def bump_redraw(area)
          area.instance_variable_set(:@redraws, redraw_count(area) + 1)
        end

        def dispatch_area(area, event, *args)
          handled = false
          area.events[event].dup.each { |handler| handled = true if handler.call(*args) }
          handled
        end

        def ensure_live!(area, action)
          return if area && !area.destroyed?

          raise ArgumentError, "面板已被销毁（#{area&.describe}），不能再模拟#{action}：" \
                               "未卸载的组件才有活着的面板"
        end

        def track(widget)
          @created << widget
          widget
        end

        # 与 libui 后端同一语义：append 到新容器前先从旧容器摘除（DOM appendChild 的搬运语义）
        def detach_from_parent(child)
          parent = child.parent
          return false unless parent

          parent.children.delete(child)
          child.parent = nil
          true
        end

        def adopt(parent, child)
          detach_from_parent(child)
          parent.children << child
          child.parent = parent
          child
        end

        def subscribe(control, event, &block)
          raise ArgumentError, "事件订阅需要块" unless block

          control.install_callback(event) if control.subscribers(event).empty?
          control.events[event] << block
          block
        end

        def matches?(handle, kind, text)
          return false if kind && handle.kind != kind
          return false if text && handle.text.to_s != text

          true
        end
      end
    end
  end
end
