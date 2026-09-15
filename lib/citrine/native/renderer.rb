# frozen_string_literal: true

require "citrine"
require "citrine/renderer"
require_relative "widgets"

module Citrine
  module Native
    # 原生控件渲染器：`Citrine::Renderer` 的平台钩子实现（GOALS 4.2 的映射表）。
    #
    # 节点树管理、Effect 装配、块级重建、keyed 复用、透明容器全部由基类负责——
    # 本类只做"节点 → 控件"的翻译，并且**不直接调 libui API**（一律经 Widgets 适配层，
    # 换 GTK 后端时本文件不动）。
    #
    # 与 DOM 渲染器的两处语义差异（GOALS 第五节，实测结论见变更日志 N1）：
    # - `node.dom` 是控件句柄（Fiddle::Pointer），`ref:` 拿到的是控件而非元素
    # - 没有 CSS：样式只映射 gap（→ 容器内边距）与 flex_grow（→ 追加时的 stretchy），
    #   其余样式键在 dev_mode 下提醒；键盘事件不支持（libui 的 entry 不暴露按键）
    class Renderer < Citrine::Renderer
      # DSL 元素 → 控件（GOALS 4.3 的元素词表；area 见 docs/design/native-area.md）
      ELEMENTS = { box: :box, label: :label, button: :button,
                   text_input: :entry, check_box: :checkbox, area: :area }.freeze

      # 样式键的落点登记在 StyleMatrix（docs/design/style-matrix.md 是同一份表的散文版）：
      # 本类只实现 :mapped 的落地（apply_padding / stretchy?）与 :painted 里 area 的
      # 视觉底板（paint_area_style），其余由 warn_unsupported_style 按矩阵提醒。

      # 每个元素支持的事件 prop（其余 on_* 在 dev_mode 下提醒）
      SUPPORTED_EVENTS = {
        box: [].freeze, label: [].freeze, button: %i[on_click].freeze,
        text_input: %i[on_change].freeze, check_box: %i[on_change].freeze,
        area: %i[on_draw on_click on_mouse_down on_mouse_up on_mouse_move on_key].freeze
      }.freeze

      # 适配层的指针事件 → 应用声明的处理器（设计 2.1/2.3）
      POINTER_PROPS = { down: :on_mouse_down, up: :on_mouse_up, move: :on_mouse_move }.freeze

      # 适配层的指针事件 → PointerEvent#type
      POINTER_TYPES = { down: "mouse_down", up: "mouse_up", move: "mouse_move" }.freeze

      # 本后端**自己消费**的 prop（不是"原样透传给平台"的）。
      # 走基类的 passthrough_prop? 钩子一次性生效于两处：基类的"Proc 不会被求值"
      # 提醒（watch: 就是故意收 Proc）、本类的"属性没有对应概念"提醒与 passthrough_props。
      CONSUMED_PROPS = { area: %i[size scroll watch].freeze }.freeze
      NO_CONSUMED_PROPS = [].freeze

      # 未支持元素/属性的替代建议（报错与提醒里带上，别让用户自己猜）。
      # 覆盖度由 test/element_event_matrix_test.rb 锁住：核心元素词表
      # （Citrine::Component::ELEMENT_TAGS）里每个不在 ELEMENTS 的标签都必须在这里有条目，
      # 否则用户拿到的是一个没有出路的报错。
      ELEMENT_HINTS = {
        textarea: "多行输入对应 libui 的 uiNewMultilineEntry，v0 未接（见 GOALS Roadmap N4）",
        select: "下拉选择对应 uiNewCombobox/uiNewRadioButtons，v0 未接（见 GOALS Roadmap N4）",
        option: "选项属于下拉选择（select）：uiNewCombobox 的条目在创建时定死，v0 未接",
        table: "表格对应 uiNewTable，能力有限，v0 未接（见 GOALS Roadmap N4）",
        thead: "表头属于表格：原生没有表格分区，整张表请用 element(:area, on_draw: …) 自绘",
        tbody: "表体属于表格：同上，整张表自绘（Painter 画网格与单元格）",
        tr: "表格行属于表格：同上，自绘（Painter 里按行距铺）",
        td: "表格单元格属于表格：同上，自绘（参考 citrine-market-terminal 的表格画法）",
        th: "表头单元格属于表格：同上，自绘",
        img: "原生控件没有图片元素，可用 element(:area, on_draw: …) 自绘",
        a: "原生控件没有超链接，改用 button + on_click",
        ul: "列表请用 stack { } + label { } 组合",
        ol: "有序列表同 ul：stack { } + label { }，序号写在文案里",
        li: "列表项请用 label { }",
        form: "表单请用 stack { } 组合",
        span: "行内文本请并入相邻 label 的字符串",
        video: "原生控件没有视频元素",
        audio: "原生控件没有音频元素"
      }.freeze

      attr_reader :widgets, :window

      def initialize(widgets: nil)
        @widgets = widgets || Widgets.default
        @window = nil
        @warned = {}
        @areas = []      # 活着的自绘面板句柄（收敛时兜底重绘用）
        @pressed = {}    # 面板节点的 object_id => 按下的键号（合成 click 用）
        @window_keys = {} # 组件 => [window_key 处理器]（面板转发全局键盘，见 register_window_key）
        # 活动后端（Timer 的跨线程通道，与核心"活动渲染器 = 最近挂载的那个"同口径）
        Citrine::Native.active_widgets = @widgets
        super()
      end

      private

      # 响应式渲染：信号驱动的原地更新正是本运行时的存在意义
      def reactive? = true

      # element 语义重定义为窗口描述：创建窗口 + 根容器（GOALS 4.2）
      def setup_root(root, element)
        @tree_root = root # 挂载期提醒要遍历整棵树（见 warn_strict_stretch_chain）
        options = element || {}
        @window = @widgets.create_window(
          title: options.fetch(:title, "Citrine"),
          width: options.fetch(:width, 640),
          height: options.fetch(:height, 480),
          margined: options.fetch(:margined, true)
        )
        @root_container = @widgets.create_box(:column)
        @widgets.window_set_child(@window, @root_container)
        root.dom = @root_container
      end

      def create_dom(node)
        case node.type
        when :box        then @widgets.create_box(box_direction(node))
        when :label      then @widgets.create_label("")
        when :button     then @widgets.create_button("")
        when :text_input then @widgets.create_entry(password: node.props[:type].to_s == "password")
        when :check_box  then @widgets.create_checkbox("")
        when :area       then create_area(node)
        else unsupported_element!(node)
        end
      end

      # 自绘面板（设计 2.1）：size:/scroll: 只在创建时生效（libui 的面板种类与内容
      # 尺寸定了就不能改）。size: 的两条实测约束（GOALS 变更日志 NA-1）：
      #   scroll: true  → uiNewScrollingArea 的内容尺寸，**必需**（且滚动面板下
      #                   Draw 报的 AreaWidth/Height 恒为 0，Painter 尺寸只能来自它）
      #   scroll: false → 面板尺寸由外层容器布局决定；uiAreaSetSize 只对滚动面板可用，
      #                   对非滚动面板调用会让 libui 直接 abort 进程，所以只能提醒并忽略
      def create_area(node)
        scroll = node.props[:scroll] == true
        size = area_size(node)
        if scroll && size.nil?
          raise Error, "[citrine-native] area 的 scroll: true 需要同时给 size: [宽, 高]：" \
                       "libui 的滚动内容尺寸在创建时定死（uiNewScrollingArea），" \
                       "而滚动面板下 Draw 不报尺寸（ui.h: only defined for nonscrolling areas）"
        end
        warn_ignored_area_size if !scroll && size && Citrine.dev_mode?

        area = @widgets.create_area(size: scroll ? size : nil, scroll: scroll)
        @areas << area
        area
      end

      def warn_ignored_area_size
        warn_once(:area_size, "[citrine-native] area 的 size: 在 scroll: false 时不生效" \
                              "（libui 的 uiAreaSetSize 只对滚动面板可用，对非滚动面板调用会终止进程），" \
                              "面板尺寸由外层容器布局决定——要固定尺寸请用 scroll: true")
      end

      def area_size(node)
        size = node.props[:size]
        return nil if size.nil?

        if size.is_a?(Proc)
          return nil unless Citrine.dev_mode?

          warn_once(:area_size_proc, "[citrine-native] area 的 size 传了 Proc：面板尺寸与种类在创建时定死，" \
                                     "不能随信号变化，已忽略——请用静态 [宽, 高]")
          return nil
        end

        values = Array(size)
        unless values.size == 2 && values.all? { |value| value.is_a?(Numeric) }
          raise Error, "[citrine-native] area 的 size 应为 [宽, 高]（数字像素），收到 #{size.inspect}"
        end
        values
      end

      def attach(node, parent)
        # 容器是窗口的唯一直系子控件；其余一律追加到父容器的末尾（基类约定）
        @widgets.box_append(parent.dom, node.dom, stretchy: stretchy?(node))
      end

      # S1-2：子组件 view 重跑的落位。libui 的 box 没有 insert-at，但
      # `uiBoxDelete` 只摘除不销毁（实测），因此适配层能无损重排——
      # 结论：**不需要容器级重建**，"细粒度更新"的卖点在本后端成立。
      # anchor 可能是透明容器（fragment/portal/suspense，自己没有控件）→ 取它的首个控件。
      def attach_before(node, parent, anchor)
        child = widget_of(node)
        return unless child

        @widgets.box_move_before(parent.dom, child, widget_of(anchor))
      end

      # 摘除 + 销毁（适配层负责先摘后销毁：libui 的 destroy 要求控件不带父容器）
      def detach(node)
        @areas.delete(node.dom)
        @pressed.delete(node.object_id)
        @widgets.destroy(node.dom)
      end

      # ── 面板重绘（设计 2.4）────────────────────────────────
      # 两条一起用：
      #   1. watch:（可选）跑在该节点的 Effect 里（见 setup_area）——依赖变化即排该面板
      #   2. 粗粒度兜底：每次响应式收敛（最外层）把所有活着的面板排一次
      # uiAreaQueueRedrawAll 本身就是"标脏 + 合并进下一帧"（macOS 下是 setNeedsDisplay），
      # 同一轮里重复排不会多画一帧，所以兜底不需要更细的脏标记。
      # 窗口尺寸变化不用管：libui 的 areaView 在 setFrameSize 里已自己标脏（darwin/area.m）。
      def repaint_areas
        @areas.each { |area| @widgets.area_queue_redraw(area) }
      end

      # 幂等：响应式属性/样式重跑会再次调用
      def apply_props(node)
        apply_padding(node) if node.type == :box
        apply_enabled(node)
        warn_unsupported_style(node)
        warn_unsupported_props(node)
      end

      # ── 响应式收敛的三个收尾点（设计 2.4）──────────────────
      # @parents.empty? = 最外层收敛：嵌套挂载/重跑期间不排重绘，整棵树落定后一次排完
      # （与 canvas 后端"最外层 settle 才重绘"同思路）。

      def finalize(_node)
        return unless @parents.empty?

        repaint_areas
        warn_strict_stretch_chain
      end

      # 块级重建（信号驱动）也发生在最外层 Effect 里：收尾补一次兜底重绘
      def run_block(node)
        super
      ensure
        repaint_areas if @parents.empty?
      end

      # 子组件 view 重跑（S1-2）同理：重跑完把面板刷新，否则"信号变了但画面没变"
      def rerun_component_view(child, parent)
        super
      ensure
        repaint_areas if @parents.empty?
      end

      # 挂载时绑一次；闭包在**派发时**从 node.props 现取处理器，因此 keyed 复用后
      # 换上的新处理器自然生效（与 DOM 渲染器同口径，复用时不需要重绑）
      def bind_events(node)
        case node.type
        when :button
          @widgets.on_click(node.dom) { dispatch_event(node, :on_click, Citrine::Event.new("click", raw: node.dom)) }
        when :text_input
          @widgets.on_change(node.dom) do
            # 受控语义：先把控件值写回 Signal，处理器读到的是新值（与 DOM 侧 check_box 同口径）
            write_back_value(node)
            dispatch_event(node, :on_change, @widgets.get_value(node.dom))
          end
        when :check_box
          @widgets.on_change(node.dom) do
            checked = @widgets.checked?(node.dom)
            write_back_checked(node, checked)
            dispatch_event(node, :on_change, checked)
          end
        when :area
          bind_area_events(node)
        end
      end

      # 面板事件（设计 2.3）：适配层给的是平台无关的形态（绘制器 / 指针事件 Hash /
      # 已归一键名的键盘事件 Hash），这里变成 Citrine 的事件视图交给组件。
      def bind_area_events(node)
        @widgets.on_area_draw(node.dom) do |painter|
          paint_area_style(node, painter)
          handler = node.props[:on_draw]
          node.owner.handle_event(handler, painter) if handler
          # 绘制期的提醒（颜色写错、align 缺 width…）按 dev_mode 去重输出：画一次说一次
          report_painter_warnings(painter)
          warn_starved_area(node, painter) if Citrine.dev_mode?
        end
        @widgets.on_area_pointer(node.dom) { |event| dispatch_pointer(node, event) }
        @widgets.on_area_key(node.dom) { |event| dispatch_area_key(node, event) }
      end

      # ── 面板的视觉底板（L2：样式的 :painted 组里 area 自动消费的那几个键）──────
      #
      # 应用给 area 写 style: { background: …, border: …, border_radius: … } 时，框架在
      # **on_draw 之前**画一次底板，应用只管内容——两个 demo 里手写的
      # `painter.rect(0, 0, w, h, fill: Theme::PANEL, stroke: Theme::LINE)` 由此收进框架。
      #
      # 每帧现读 node.props[:style]（经 resolve_style）：样式是 Proc 时也跟着重画，
      # 与响应式属性同口径。原生控件没有这项能力（libui 的 box/label 无法着色），
      # 所以非 area 元素上的这些键仍由 warn_unsupported_style 提醒。
      def paint_area_style(node, painter)
        style = resolve_style(node)
        fill = style[:background]
        width, stroke = border_of(style)
        radius = style[:border_radius]

        fill = :none if fill.nil?
        stroke = :none if stroke.nil?
        return if fill == :none && stroke == :none && radius.nil?

        painter.rect(0, 0, painter.width, painter.height,
                     fill: fill, stroke: stroke,
                     line_width: width || 1, radius: radius || 0)
      end

      # border 的三种写法（够用即止，不做 CSS 解析器）：
      #   border: "1px solid #1e2c48"   简写（只画实线，dashed/dotted 提醒后按实线）
      #   border: "#1e2c48"             只有颜色 → 1px
      #   border: { width: 2, color: … } 或 border_color / border_width 分开写
      def border_of(style)
        width = positive_number(style[:border_width])
        color = normalize_border_color(style[:border_color])
        shorthand = style[:border]

        case shorthand
        when Hash
          width ||= positive_number(shorthand[:width])
          color ||= normalize_border_color(shorthand[:color])
        when String
          width, color = parse_border_shorthand(shorthand, width, color)
        end

        return [nil, nil] if color.nil?

        [width || 1.0, color]
      end

      def parse_border_shorthand(text, width, color)
        stripped = text.strip
        return [width, color] if stripped.empty? || stripped == "none"

        if (match = /\A(\d+(?:\.\d+)?)px\b(.*)\z/.match(stripped))
          width ||= match[1].to_f
          rest = match[2]
          warn_dashed_border(rest)
          color ||= normalize_border_color(rest.sub(/\A\s*(solid|dashed|dotted)\b/, "").strip)
        else
          color ||= normalize_border_color(stripped) # 只有颜色
        end
        [width, color]
      end

      def warn_dashed_border(rest)
        return unless Citrine.dev_mode?
        return unless rest.match?(/\b(dashed|dotted)\b/)

        warn_once(:border_style, "[citrine-native] border 只画实线（solid）：dashed / dotted " \
                                 "没有对应，按实线画（见 docs/design/style-matrix.md）")
      end

      def normalize_border_color(value)
        return nil if value.nil?

        text = value.to_s.strip
        return nil if text.empty? || text == "none" || value == :none

        value
      end

      def positive_number(value)
        number = value.to_f
        number.positive? ? number : nil
      end

      # 指针事件归一：适配层给 :down/:up/:move，这里映射成 PointerEvent 的
      # mouse_down/mouse_up/mouse_move；click 由"在本面板按下又抬起"合成
      # （libui 没有 DOM 的 click，只有 Down/Up 与 Count）。
      def dispatch_pointer(node, event)
        kind = event[:kind]
        button = event[:button].to_i
        pressed = kind == :up ? @pressed.delete(node.object_id) : @pressed[node.object_id]
        @pressed[node.object_id] = button if kind == :down

        prop = POINTER_PROPS[kind]
        dispatch_pointer_event(node, prop, pointer_event(node, event, POINTER_TYPES.fetch(kind, kind.to_s))) if prop

        return unless kind == :up && pressed == button

        # DOM 顺序：mouseup 之后才 click；拖动后仍在同面板抬起照样算 click（DOM 同语义）
        dispatch_pointer_event(node, :on_click, pointer_event(node, event, "click"))
      end

      def pointer_event(node, event, type)
        PointerEvent.new(type, x: event[:x], y: event[:y],
                               button: event[:button], modifiers: event[:modifiers], raw: event)
      end

      def dispatch_pointer_event(node, prop, event)
        handler = node.props[prop]
        return unless handler

        node.owner.handle_event(handler, event)
      end

      # 键盘（设计 2.3）：键名已由适配层归一成 DOM 风格（"ArrowUp"/"Enter"/"a"…），
      # 这里包成核心既有的 Citrine::KeyEvent。抬起不投递（v0 没有 on_key_up）。
      # 顺序与 DOM 冒泡一致：先本面板的 on_key，再转发给 window_key 的全局处理器。
      # 返回值 = "有处理器认领了这次按键"（libui 据此决定要不要走系统默认处理）。
      #
      # **⌘ 组合键一律回报"未处理"**——回调照常触发（应用自己处理的 ⌘Z/⌘B 不受影响），
      # 只是不抑制系统默认处理：libui 的 KeyEvent 回调**先于**菜单快捷键执行，认领它
      # 会让 ⌘H（Hide）这类有绑定的菜单项在焦点落到面板时失效（NA-2 的真 OS 投递对照实验：
      # 声明 on_key 的面板把 ⌘H 吃掉了；NA-1c 修复 + 真 OS 复验）。
      # 策略**单点在这里**：适配层只如实转达本方法的答复（桩后端与真后端因此同口径，
      # 也才有测试锁得住）。见 design 2.3 / 5.3 与变更日志 NA-1c。
      def dispatch_area_key(node, event)
        return false if event[:up]

        # 适配层的契约就是 {shift:, ctrl:, alt:, meta:} 四个键（见 widgets.rb 的协议说明）：
        # KeyEvent 的默认值负责缺省，所以这里直接把哈希铺开，不再自己造一遍
        key_event = KeyEvent.new(event[:key], **(event[:modifiers] || {}), raw: event)
        handler = node.props[:on_key]
        handled = false
        if handler
          node.owner.handle_key(handler, key_event)
          handled = true
        end
        handled = forward_window_key(node, key_event) || handled
        handled && !key_event.meta?
      end

      # window_key（G-9 / 设计 2.3）：原生没有 window 级 keydown，唯一拿得到按键的
      # 控件是自绘面板——所以全局快捷键的语义是"焦点在某个面板上时可用"，由收到按键
      # 的那个面板转发。scope: :focused 时要求面板在该组件的子树里（DOM 侧是
      # activeElement 落在组件 root 内）。
      def forward_window_key(node, key_event)
        return false if @window_keys.empty?

        handled = false
        @window_keys.dup.each do |component, handlers|
          handlers.dup.each do |handler|
            scoped = handler.is_a?(Component::WindowKey)
            next if scoped && !focused_in?(component, node)

            component.handle_key(scoped ? handler.handler : handler, key_event)
            handled = true
          end
        end
        handled
      end

      # "焦点"在原生侧没有查询 API（libui-ng 没有 uiControlSetFocus，见 GOALS 变更日志
      # NA-1）：焦点就是"哪个面板收到了按键"，因此这里判的是节点树的归属
      def focused_in?(component, node)
        root = component.respond_to?(:root) ? component.root : nil
        root ? subtree_includes?(root, node) : false
      end

      def subtree_includes?(root, node)
        return true if root.equal?(node)

        root.children.any? { |child| subtree_includes?(child, node) }
      end

      # 绘制期提醒：Painter 每帧新建（自己 warn 会刷屏），按 key 在渲染器这边去重
      def report_painter_warnings(painter)
        return unless Citrine.dev_mode?

        painter.warnings.each { |key, message| warn_once([:painter, key], message) }
      end

      # 比一行 14pt 文本还矮/还窄的面板几乎不可能是有意设计（Painter 的文本外接矩形
      # 就已经 ~17pt 高）。启发式阈值，见 warn_starved_area 的说明。
      MIN_USABLE_PANEL = 24.0

      # 面板被压扁的 dev_mode 提醒（P2.1 / SHEETS D2 的坑；NA-1d 扩了判据与提示文本，
      # NA-1e 把判据 ② 限定到非滚动面板）。
      #
      # libui 的 box 布局里拿不到空间的控件会被 Auto Layout 解成 0×0——**不报错**，
      # 应用只看到"面板不见了"（实测：`stack { label; area; area }` 里两个面板互相抢，
      # 被压的那个 0 高，还会把兄弟挤扁）。三条判据分开报，因为可操作建议不同：
      # ① Painter 拿到的尺寸是 0/负（就是上面那个 0×0；滚动面板声明 size: [0, x] 也在此列）；
      # ② **非滚动**面板的 Painter 尺寸非 0 但**小到画不出东西**（非滚动面板下 Painter
      #    尺寸就是控件的真实 frame：NA-2 实测被兄弟挤成 753×16 的面板，旧口径一言不发）；
      # ③ 滚动面板的**真实可见视口**小到画不出东西——滚动面板下 Painter 拿到的是声明的
      #    **内容**尺寸（2000×2000），视口塌成 736×16 时旧口径同样一言不发，而这是
      #    SHEETS-2 现场最像的形状。视口由后端给（libui 读 clip view 的真实边界），
      #    后端说"没有额外几何"（nil）时这条跳过。
      #
      # ⚠️ 判据 ② **只对非滚动面板**（NA-1e）：滚动面板下 Painter 的宽高是**声明的内容
      # 尺寸**，一个健康的面板只要声明了 size: [2000, 20]（横向缩略图条）就会被 ② 误报
      # "控件被挤成一条：2000.0×20.0"（真 GUI 里它实到 760×544、视口 743×527）。滚动面板的
      # "小"只有视口说了算，也就是判据 ③；后端不给几何时**宁可不报也不误报**（盲区见 §5.1）。
      #
      # ②③ 共用阈值 MIN_USABLE_PANEL：它是**启发式**——"比一行 14pt 文本还矮的面板
      # 几乎不可能是有意设计"。真要做细条就把 dev_mode 关掉（提醒只服务开发期）。
      # 剩余的盲区如实写在文档 §5.1：拿不到真实几何的后端（非 macOS）下，滚动面板的
      # 视口塌陷报不出来；判据 ③ 的数字取自**当帧**（首帧可能是瞬态读数）。
      #
      # 判据 ③ 的视口数字是后端在**当帧**读到的原始值：滚动面板**首帧**可能还没布局完
      # （libui 在同一次 Draw 里才设 document view 的 frame，而这次读在它之前），此时
      # `visibleRect` 报的是 NSScrollView 自己的尺寸——含滚动条位。本机当场复现（NA-1e
      # 真 GUI 探针）：提示里打 712.5×16，0.8 秒后的稳态可见区是 695.5×16（差 17pt =
      # 滚动条宽；NA-1d 记录的首帧 `clip_rect` 瞬态是同一件事，见 §5.7.6-6）。触发与去重
      # 不受影响（每帧都查、按节点去重），**只有消息里的数字可能偏大**——如实标注，不假装
      # 它是稳态值。NA-1e 在"取稳态值 / 标注瞬态"里选了后者：延迟一帧再报会让"只画一帧"
      # 的形状漏报（桩测与真冒烟都是单帧断言），而拿"读数 == NSScrollView 的 frame"猜瞬态
      # 在 overlay 滚动条下会把正常视口也判成瞬态。
      def warn_starved_area(node, painter)
        width = painter.width
        height = painter.height
        scrolling = @widgets.area_scrollable?(node.dom)
        if !(width.positive? && height.positive?)
          warn_once([:area_starved, node.object_id], squeezed_area_message("拿到了 0 尺寸", [width, height]))
        elsif !scrolling && [width, height].min < MIN_USABLE_PANEL
          warn_once([:area_squeezed, node.object_id], squeezed_area_message("控件被挤成一条", [width, height]))
        end

        viewport = @widgets.area_visible_size(node.dom)
        return if viewport.nil?

        return if [viewport[0], viewport[1]].min >= MIN_USABLE_PANEL

        warn_once([:area_viewport_squeezed, node.object_id],
                  squeezed_area_message("真实可见视口", viewport,
                                        "（Painter 拿到的是声明的内容尺寸 #{format_size([width, height])}；" \
                                        "视口是当帧原始读数，滚动面板首帧可能报成 NSScrollView 的尺寸（偏大））"))
      end

      # 提示必须对"已经给了 flex_grow 还是被压"的形状也可操作（NA-2 实测的那个形状里
      # 面板自己有 flex_grow 却被压成 0 宽，旧提示让它"给 flex_grow"是空转）。
      # 正确判据（NA-2 用两个反例否证了"每个嵌套 box 都要有一个 stretchy 子控件"）：
      # **参与拉伸的 box 自己在父容器里要有 stretchy 尺寸**，逐层往上都成立才撑得开。
      def squeezed_area_message(what, size, extra = nil)
        "[citrine-native] 这个面板被压扁了（#{what}：#{format_size(size)}#{extra}），" \
          "这么小画不出可见内容。面板能不能撑开，取决于**它所在的每一层容器在各自父容器里" \
          "有没有 stretchy 尺寸**：只给面板自己 style: { flex_grow: 1 } 不够——外层那个" \
          "嵌套 box 也要有（或者别嵌套，把面板直接放进要拉伸的那一层）。`flex_grow` 在 " \
          "libui 里是**布尔**\"吃掉剩余空间\"、不是权重（同一层里两个 stretchy 兄弟等分）。" \
          "滚动面板还要给 size:（内容尺寸）。判据与实测反例见 docs/design/native-area.md §5.7.2"
      end

      def format_size(size)
        "#{size[0]}×#{size[1]}"
      end

      # ── 挂载期的"严格后端上会塌"提醒（backlog F24；判据同 F11 / §5.7.2）──────
      #
      # 为什么另开一条（draw 期的 warn_starved_area 不够）：Windows 的 libui 对
      # stretchy 链断开的 area 是**完全**的 0×0，`WM_PAINT` 不会来 → Draw 不跑 →
      # 那条提醒永远不会亮（macOS 上 0×0 面板仍有 Draw，所以只在 Windows 上看得见）。
      # 这里做的是**静态判据**（不看几何、不求几何）：面板自己能 stretchy，且从组件根
      # 往下的每一层 box 在各自父容器里都 stretchy，逐层成立才能真正拿到剩余空间。
      # 因此措辞说"在严格后端上会塌"，不假装量到了尺寸；只在 dev_mode 下提醒、按节点去重。
      def warn_strict_stretch_chain
        return unless Citrine.dev_mode?
        return unless @tree_root

        @tree_root.children.each { |child| check_stretch_chain(child, true, nil, 1) }
      end

      # chain_ready：从组件根到这里的 box 链是否**每层**都 stretchy
      # breaker / depth：第一个断掉的 box（`[节点, 层号]`，层号从组件根数起、1 基）——
      # 用于把"链在哪断了"说清楚，而不是让应用自己去猜哪一层
      def check_stretch_chain(node, chain_ready, breaker, depth)
        case node.type
        when :area
          return if chain_ready && stretchy?(node)

          warn_once([:area_strict_chain, node.object_id], strict_chain_message(breaker))
        when :box
          if chain_ready && !stretchy?(node)
            chain_ready = false
            breaker ||= [node, depth]
          end
          node.children.each { |child| check_stretch_chain(child, chain_ready, breaker, depth + 1) }
        else
          # 透明容器（fragment / portal / suspense）不占控件层，层号不加
          (node.children || []).each { |child| check_stretch_chain(child, chain_ready, breaker, depth) }
        end
      end

      def strict_chain_message(breaker)
        where = if breaker.nil?
                  "**面板自己**没有 stretchy 尺寸（style: { flex_grow: 1 }）"
                else
                  node, depth = breaker
                  "**祖先里第 #{depth} 层那个 #{node.type}** 没有 stretchy 尺寸（style: { flex_grow: 1 }）"
                end
        "[citrine-native] 这个面板撑不开：#{where}。\n" \
          "  为什么现在才知道：严格后端（Windows）下它会是 0×0 且**一次都不绘制**，" \
          "绘制期的\"面板被压扁\"提醒因此永远不会亮；macOS 对窗口直系子元素宽容，" \
          "同一棵树在那里可能看不出问题（跨平台差异见 docs/design/platform-matrix.md）。\n" \
          "  修法：从组件根到面板，**参与拉伸的每一层 box** 都要自己声明 `style: { flex_grow: 1 }`，" \
          "逐层成立才撑得开（`flex_grow` 是布尔不是权重；判据与反例见 docs/design/native-area.md §5.7.2）。\n" \
          "  这个提醒只在 dev_mode 下出现（`dev_mode: false` 可关）。"
      end

      # ref: :grid → refs[:grid] 拿到的是**面板句柄**（AreaHandle，设计 2.5），不是 libui 裸指针
      def register_ref(node)
        return super unless node.type == :area

        name = node.props[:ref]
        return unless name && node.owner.respond_to?(:refs)

        node.owner.refs[name] = AreaHandle.new(widgets: @widgets, handle: node.dom)
      end

      def set_text(node, text)
        if container?(node)
          return if text.to_s.empty?

          warn_once(:container_text, "[citrine-native] #{node.type} 的内容 block 返回了字符串" \
                                     "（#{text.inspect}），但原生容器没有文本位，已忽略：" \
                                     "#{node.type == :area ? '面板内容请在 on_draw 里画' : '请用 label { ... } 包一层'}")
          return
        end

        @widgets.set_text(node.dom, text)
        # 镜像进 node.text（与 DOM/SSR 同口径）：基类靠它判定"上一轮写过文本"，
        # 本轮没内容时才能显式清空（renderer.rb 的 C3 逻辑）
        node.text = text
      end

      # 受控控件的初值与"信号 → 控件"方向（控件 → 信号在 bind_events）
      def setup_widget(node)
        case node.type
        when :text_input then setup_entry(node)
        when :check_box  then setup_checkbox(node)
        when :area       then setup_area(node)
        end
      end

      # 面板：on_draw 必填（面板必须知道怎么画）；watch:（设计 2.4）在该节点自己的
      # Effect 里跑——应用在里面读它绘制所依赖的信号，依赖变化就排这个面板重绘。
      # 注意方向：绘制回调（on_draw）在 libui 的 Draw 回调里执行、**不在 Effect 内**，
      # 因此那里的信号读取不建立订阅（否则每帧都会重排订阅）。
      def setup_area(node)
        unless node.props[:on_draw]
          raise Error, "[citrine-native] area 必须提供 on_draw:（自绘面板的绘制回调，" \
                       "参数是 Painter）：element(:area, on_draw: ->(p) { … })"
        end

        watch = node.props[:watch]
        return if watch.nil?

        node.owned_effects << Effect.create do
          Citrine.dispatch_callable(watch, node.owner, nil, bind: true)
          @widgets.area_queue_redraw(node.dom)
        end
      end

      # portal 宿主（S1-5）：原生没有 DOM body，语义取"根容器"——
      # 逃出父容器的嵌套布局，落到窗口内容区末尾
      def resolve_portal_host(target)
        return @root_container if target.nil? || target == "" || target == :root

        raise ArgumentError, "[citrine-native] portal 的 target #{target.inspect} 无法解析：" \
                             "原生后端只有根容器一个宿主，请用 target: :root（或省略）"
      end

      # 全局键盘（G-9 / 设计 2.3）：原生没有 window 级 keydown，唯一能拿到按键的控件
      # 是自绘面板——因此这里只登记，分发由收到按键的面板转发（forward_window_key）。
      def register_window_key(component, handler)
        handlers = (@window_keys[component] ||= [])
        handlers << handler unless handlers.include?(handler)
        nil
      end

      def unregister_window_keys(component)
        @window_keys.delete(component)
        nil
      end

      # ── 受控控件 ────────────────────────────────────────────

      def setup_entry(node)
        value = node.props[:value]
        if value.is_a?(Signal)
          node.owned_effects << Effect.create { push_value(node, value.get) }
        elsif !value.nil?
          @widgets.set_value(node.dom, value.to_s)
        end
      end

      def setup_checkbox(node)
        checked = node.props[:checked]
        if checked.is_a?(Signal)
          node.owned_effects << Effect.create { @widgets.set_checked(node.dom, checked.get ? true : false) }
        else
          @widgets.set_checked(node.dom, checked ? true : false)
        end
      end

      def push_value(node, value)
        text = value.to_s
        # 值没变就不写控件：libui 每次 setText 都会重置光标位置（正打字时最刺眼）
        @widgets.set_value(node.dom, text) unless @widgets.get_value(node.dom) == text
      end

      def write_back_value(node)
        value = node.props[:value]
        value.set(@widgets.get_value(node.dom)) if value.is_a?(Signal)
      end

      def write_back_checked(node, checked)
        signal = node.props[:checked]
        signal.set(checked) if signal.is_a?(Signal)
      end

      # 事件视图是平台无关的：button 收 Citrine::Event，check_box 收布尔勾选态
      # （与 DOM 侧同口径），text_input 收新文本（原生侧专属，见 GOALS 第五节的差异清单）
      def dispatch_event(node, prop, payload)
        handler = node.props[prop]
        return unless handler

        node.owner.handle_event(handler, payload)
      end

      # 覆盖基类钩子：本后端消费掉的 prop（area 的 size/scroll/watch）不算透传属性，
      # 否则它们会被"没有对应概念"和"Proc 不会被求值"两处提醒误报
      def passthrough_prop?(name, node)
        return false if CONSUMED_PROPS.fetch(node&.type, NO_CONSUMED_PROPS).include?(name)

        super
      end

      # ── 布局与样式 ──────────────────────────────────────────

      def box_direction(node)
        direction = node.props[:direction]
        if direction.is_a?(Proc)
          warn_once(:proc_direction, "[citrine-native] box 的 direction 传了 Proc：原生控件的方向在创建时定死，" \
                                     "不能随信号切换，已按默认 row 处理；请用静态方向")
          return :row
        end

        direction == :column ? :column : :row
      end

      # 追加时的 stretchy ← 静态 flex_grow / flex（flex-grow 的语义就是"吃掉剩余空间"，
      # 与 libui box 的 stretchy 同构）。响应式样式不参与：那会在挂载期读到信号、
      # 把订阅落到外层块上（正是 G-2 要消除的隐性外扩）。键的登记见 StyleMatrix。
      def stretchy?(node)
        style = node.props[:style]
        return false if style.is_a?(Proc)

        normalized = Style.normalize(style)
        return true if normalized[:flex_grow].to_f.positive?

        # CSS 的 flex 简写："1" / "1 1 auto" / "0 1 auto"——取首段数值
        flex = normalized[:flex].to_s.strip
        flex.match?(/\A\d/) && flex.to_f.positive?
      end

      # 容器内边距 ← gap / padding*（StyleMatrix 的 :mapped 组）。
      # libui 的 box 只有 padded 开关，所以数值按是否 > 0 判定
      def apply_padding(node)
        style = resolve_style(node)
        candidates = [style[:padding], style[:padding_top], style[:padding_right],
                      style[:padding_bottom], style[:padding_left], style[:gap]].compact
        return if candidates.empty? # 一个都没声明 → 不动容器默认值

        @widgets.set_padding(node.dom, candidates.any? { |value| spacing?(value) })
      end

      # gap / padding 只有"有间距/无间距"两档可映射（libui 的 box 只有 padded 开关）；
      # 数值按是否 > 0 判定，非数值（主题 token 等）视为"有间距"
      def spacing?(gap)
        value = gap.to_s
        return true unless value.match?(/\A[\d.]+\s*(px|pt|em|rem)?\z/)

        value.to_f.positive?
      end

      # disabled 是 citrine 的透传属性（DOM 侧变成 disabled 属性），原生侧映射到控件禁用态
      def apply_enabled(node)
        return unless node.props.key?(:disabled)

        @widgets.set_enabled(node.dom, !node.props[:disabled])
      end

      # 样式键的提醒按 StyleMatrix 的三档状态说话（绝不静默丢弃；GOALS 4.5）：
      #   :mapped  静音（由 stretchy? / apply_padding 落地）
      #   :painted area 上的视觉底板静音（L2 会自动画）；其余说清"怎么自绘"
      #   :ignored 说清"没有对应概念 + 为什么"
      def warn_unsupported_style(node)
        return unless Citrine.dev_mode?

        resolve_style(node).each_key do |key|
          next if StyleMatrix.status(key) == StyleMatrix::MAPPED
          next if node.type == :area && StyleMatrix.entry(key).area?

          warn_once([:style, key], style_warning(key, node))
        end

        warn_non_flex_display(node)
      end

      def style_warning(key, node)
        entry = StyleMatrix.entry(key)
        if entry.status == StyleMatrix::PAINTED
          if entry.area?
            "[citrine-native] 样式键 #{key.inspect} 不能映射到 #{node.type}（原生控件无法着色）：" \
              "把它移到 element(:area) 上（自绘面板会把它画成底板），或在 on_draw 里自绘。" \
              "见 docs/design/style-matrix.md"
          else
            "[citrine-native] 样式键 #{key.inspect} 在原生后端不支持自动映射（需要自绘）：" \
              "在 element(:area) 的 on_draw 里用 #{entry.mapping}。见 docs/design/style-matrix.md"
          end
        else
          "#{"[citrine-native] 样式键 #{key.inspect} 在原生后端没有对应概念（libui 无 CSS），已忽略"}" \
            "#{StyleMatrix.registered?(key) ? "（#{entry.note}）" : "（未在矩阵中登记）"}。" \
            "见 docs/design/style-matrix.md"
        end
      end

      # display 只有 flex 有对应：基类给 box 合成的 display: "flex" 静音，
      # 用户显式写的 grid 等值要提醒（否则"以为布局生效了"）
      def warn_non_flex_display(node)
        display = resolve_style(node)[:display]
        return if display.nil? || display.to_s == "flex"

        warn_once([:style, :display_value],
                  "[citrine-native] display: #{display.inspect} 在原生后端没有对应概念" \
                  "（只支持 flex 布局，stack / row 就是它的两种方向）。见 docs/design/style-matrix.md")
      end

      def warn_unsupported_props(node)
        return unless Citrine.dev_mode?

        passthrough_props(node).each do |(name, _value)|
          next if name == "disabled"

          warn_once([:prop, name], "[citrine-native] 属性 #{name.inspect}（#{node.type}）在原生后端没有对应概念，已忽略")
        end

        warn_unsupported_events(node)
        warn_placeholder(node)
        warn_css_class(node)
      end

      # css_class 是"给 CSS 用的名字"：原生没有 CSS，落不到控件上。
      # 它是被框架消费的属性（不进 passthrough），不提醒就是静默丢弃——
      # 而布局意图（哪些格子/面板该拉伸）经常就藏在 class 背后。
      def warn_css_class(node)
        return if node.props[:css_class].nil?

        warn_once(:css_class, "[citrine-native] css_class 在原生后端没有对应概念（没有 CSS），已忽略：" \
                              "布局意图请改用 gap（间距）与 style: { flex_grow: 1 }（吃掉剩余空间）")
      end

      def warn_unsupported_events(node)
        supported = SUPPORTED_EVENTS.fetch(node.type, [])
        node.props.each_key do |name|
          next unless name.to_s.start_with?("on_")
          next if supported.include?(name)

          warn_once([:event, node.type, name],
                    "[citrine-native] #{node.type} 的 #{name} 在原生后端不支持" \
                    "（v0 支持：#{supported.empty? ? '无' : supported.map(&:inspect).join(' / ')}），已忽略")
        end
      end

      def warn_placeholder(node)
        return unless node.type == :text_input && node.props[:placeholder]

        warn_once([:placeholder], "[citrine-native] text_input 的 placeholder 在原生后端不支持" \
                                  "（libui 的 entry 没有占位文本），已忽略：可用相邻 label 说明")
      end

      def warn_once(key, message)
        return if @warned[key]

        @warned[key] = true
        warn message
      end

      # ── 控件定位 ────────────────────────────────────────────

      # 透明容器（fragment/portal/suspense）自己没有控件（dom 借的是父容器的），
      # 落位锚点要用它的首个真控件（与 DomRenderer 处理 fragment 锚点同思路）
      def widget_of(node)
        return nil if node.nil?
        return node.dom unless TRANSPARENT_TYPES.include?(node.type)

        node.children.each do |child|
          found = widget_of(child)
          return found if found
        end
        nil
      end

      def container?(node)
        node.type == :box || node.type == :area
      end

      def unsupported_element!(node)
        hint = ELEMENT_HINTS[node.type]
        raise UnsupportedElementError,
              "[citrine-native] 元素 #{node.type} 在原生后端没有对应控件：" \
              "v0 支持 #{ELEMENTS.keys.map(&:to_s).join(' / ')}" \
              "#{hint ? "。#{hint}" : '。可用元素见 GOALS 4.3'}"
      end
    end
  end
end
