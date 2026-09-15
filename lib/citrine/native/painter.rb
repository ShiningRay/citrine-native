# frozen_string_literal: true

module Citrine
  module Native
    # 自绘面板的绘制薄层（冻结接口见 docs/design/native-area.md 2.2）。
    #
    # 三个部分各司其职，参数归一只有一份，两个实现不会漂移：
    #   Primitives —— 图元签名 + 颜色/字重/对齐/圆角归一 + "未支持用法"的提醒收集（纯 Ruby）
    #   Painter    —— 真 libui 绘制（Primitives 的平台实现；坐标是面板本地像素，左上角原点）
    #   Recording  —— 只记录图元调用序列的桩实现（Memory 后端与"画了什么"的断言用）
    #
    # 生命周期：**一个面板一次 on_draw 一个 Painter 实例，不跨帧复用**。
    # 跨帧复用的只有文本布局（TextCache）：它由适配层按面板持有、随面板销毁释放——
    # libui 的 text layout / attributed string / font descriptor 不归 Ruby GC 管，
    # 漏 free 就是每帧漏一段 C 内存（每帧每格新建 layout 还会明显掉帧）。
    class Painter
      # ── "未支持用法/无效值"的提醒收集 ────────────────────────
      # Painter 每帧新建（见上），自己 warn 会每帧刷屏；这里只按 key 收集，
      # 交给渲染器按 dev_mode 去重后输出（Renderer#report_painter_warnings）。
      module Warnings
        # key => message（同一 key 只留第一条）
        def warnings
          @warnings ||= {}
        end

        private

        def note_warning(key, message)
          (@warnings ||= {})[key] ||= message
        end
      end

      # ── 图元（冻结签名，见设计 2.2）──────────────────────────
      # 只做"归一 + 调用平台实现"：真正的绘制由 emit_* 钩子落在各自实现上。
      #
      # 坐标/尺寸一律 to_f（应用传整数或字符串都不该炸）；颜色接受
      # "#rgb" / "#rrggbb" / "#rrggbbaa" / [r,g,b(,a)]（0..1 浮点）/ :none。
      module Primitives
        include Warnings

        DEFAULT_TEXT_COLOR = "#000000"
        DEFAULT_LINE_COLOR = "#000000"
        DEFAULT_TEXT_SIZE = 13

        # libui 的约定：宽度为负 = 不换行（uiDrawNewTextLayout 里 Width < 0 → CGFLOAT_MAX）
        NO_WRAP = -1.0

        # 对齐只在给定宽度内生效（布局的 Width 决定外接矩形），没有 width 时按左对齐
        # 处理并提醒——"以为右对齐了"这种静默偏差最难查。
        ALIGN_KEYS = { left: :left, center: :center, right: :right }.freeze

        def rect(x, y, w, h, fill: :none, stroke: :none, line_width: 1, radius: 0)
          fill = color_of(fill)
          stroke = color_of(stroke)
          return self if fill.nil? && stroke.nil?

          w = num(w)
          h = num(h)
          return self unless w.positive? && h.positive?

          emit_rect(num(x), num(y), w, h, fill, stroke, num(line_width), radius_of(radius, w, h))
        end

        def line(x1, y1, x2, y2, color: DEFAULT_LINE_COLOR, width: 1)
          color = color_of(color)
          return self if color.nil?

          emit_line(num(x1), num(y1), num(x2), num(y2), color, num(width))
        end

        # points = [[x, y], …]（至少两个点）
        def polyline(points, color: DEFAULT_LINE_COLOR, width: 1)
          color = color_of(color)
          return self if color.nil?

          emit_polyline(points_of(points), color, num(width))
        end

        # 面积图（权益曲线）：至少三个点才有面积
        def polygon(points, fill: :none, stroke: :none, line_width: 1)
          fill = color_of(fill)
          stroke = color_of(stroke)
          return self if fill.nil? && stroke.nil?

          emit_polygon(points_of(points), fill, stroke, num(line_width))
        end

        def text(string, x:, y:, color: DEFAULT_TEXT_COLOR, size: DEFAULT_TEXT_SIZE,
                 weight: :normal, family: nil, align: :left, width: nil)
          entry = text_entry(string.to_s, size: size_of(size), weight: weight_of(weight),
                                          family: family_of(family), color: color_of(color),
                                          wrap_width: width.nil? ? NO_WRAP : num(width),
                                          align: align_of(align, width))
          emit_text(entry, num(x), num(y))
        end

        # → [宽, 高]（像素）。与 text 走同一份布局参数（同字体/字号/字重/字体族）。
        def measure_text(string, size: DEFAULT_TEXT_SIZE, weight: :normal, family: nil)
          entry = text_entry(string.to_s, size: size_of(size), weight: weight_of(weight),
                                          family: family_of(family), color: nil,
                                          wrap_width: NO_WRAP, align: :left)
          [entry.measured_width, entry.measured_height]
        end

        # 块内裁剪（libui 的 save/clip/restore）：块里照常画，矩形外的部分被裁掉
        def clip(x, y, w, h, &block)
          raise ArgumentError, "clip 需要块：p.clip(x, y, w, h) { … }" unless block

          emit_clip_begin(num(x), num(y), num(w), num(h))
          begin
            block.arity.zero? ? block.call : block.call(self)
          ensure
            emit_clip_end
          end
          self
        end

        # 面板内容尺寸 [w, h]（设计 2.2）：非滚动面板 = 布局尺寸，滚动面板 = 声明的内容尺寸
        # （macOS 下滚动面板的 Draw 不报尺寸，见 2.2 的实测）
        def content_size = [@width, @height]

        # 当前可见区 [x, y, w, h]，内容坐标系（设计 2.2）。
        # 应用拿它做"只画看得见的部分"的省算：滚动面板下它随滚动位置变化。
        def clip_rect = @clip

        private

        # ── 参数归一 ──────────────────────────────────────────

        def num(value) = value.to_f

        def size_of(size)
          value = num(size)
          value.positive? ? value : DEFAULT_TEXT_SIZE.to_f
        end

        def points_of(points)
          list = Array(points)
          raise ArgumentError, "图元至少需要两个点，收到 #{points.inspect}" if list.size < 2

          list.map { |point| Array(point).map { |coordinate| num(coordinate) } }
        end

        def color_of(value)
          case value
          when nil, :none then nil
          when Array then channel_color(value)
          when String then hex_color(value)
          else invalid_color(value)
          end
        end

        def hex_color(text)
          hex = text.strip
          return nil if hex.empty? || hex.casecmp("none").zero? || hex.casecmp("transparent").zero?
          return invalid_color(text) unless hex.start_with?("#") && hex[1..].match?(/\A\h+\z/)

          digits = hex[1..]
          case digits.length
          when 3
            r, g, b = digits.chars.map { |d| d.to_i(16) * 17 }
            [r / 255.0, g / 255.0, b / 255.0, 1.0]
          when 6, 8 then hex_bytes(digits)
          else invalid_color(text)
          end
        end

        def hex_bytes(digits)
          bytes = digits.scan(/../).map { |pair| pair.to_i(16) }
          [bytes[0] / 255.0, bytes[1] / 255.0, bytes[2] / 255.0, bytes[3] ? bytes[3] / 255.0 : 1.0]
        end

        def channel_color(values)
          unless values.size.between?(3, 4) && values.all? { |v| v.is_a?(Numeric) }
            return invalid_color(values)
          end

          if values.any? { |v| v.negative? || v > 1.0 }
            note_warning([:color_range, values.to_s],
                         "[citrine-native] 颜色数组按 0..1 浮点解释（#{values.inspect}），" \
                         "超出范围的分量已夹到 [0, 1]——0..255 的写法请先除以 255")
          end
          r, g, b, a = values
          [clamp01(r), clamp01(g), clamp01(b), a.nil? ? 1.0 : clamp01(a)]
        end

        def clamp01(value) = [[value.to_f, 0.0].max, 1.0].min

        def invalid_color(value)
          note_warning([:color, value.to_s],
                       "[citrine-native] 颜色 #{value.inspect} 不是支持的写法" \
                       "（#rgb / #rrggbb / #rrggbbaa / [r,g,b] / :none），已忽略这次绘制")
          nil
        end

        def weight_of(weight)
          case weight
          when nil, :normal, "normal" then 400
          when :bold, "bold" then 700
          when Numeric then weight.to_i.clamp(0, 1000)
          else
            note_warning([:weight, weight.to_s],
                         "[citrine-native] 字重 #{weight.inspect} 不是支持的写法" \
                         "（:normal / :bold / 100..900），已按 :normal 绘制")
            400
          end
        end

        def family_of(family)
          case family
          when nil, "" then nil
          when String then family
          else
            note_warning([:family, family.class],
                         "[citrine-native] 字体族 #{family.inspect} 不是字符串，已用系统默认字体")
            nil
          end
        end

        def align_of(align, width)
          key = align.to_s.to_sym
          unless ALIGN_KEYS.key?(key)
            note_warning([:align, align.to_s],
                         "[citrine-native] align #{align.inspect} 不是支持的写法" \
                         "（:left / :center / :right），已按左对齐绘制")
            return :left
          end

          if key != :left && width.nil?
            note_warning(:align_without_width,
                         "[citrine-native] text 的 align: #{key.inspect} 需要同时给 width:" \
                         "（libui 的对齐是在给定宽度内对齐），本次按左对齐绘制")
            return :left
          end
          key
        end

        def radius_of(radius, w, h)
          value = num(radius)
          return 0.0 unless value.positive?

          limit = [w, h].min / 2.0
          return value if value <= limit

          note_warning([:radius, value],
                       "[citrine-native] 圆角半径 #{value} 超过矩形短边的一半（#{limit}），" \
                       "已按最大圆角绘制")
          limit
        end

        # ── 平台实现（emit_*）与文本布局入口 ──────────────────
        # 两个实现：Painter（libui 调用）/ Recording（记录调用序列）。

        def emit_rect(_x, _y, _w, _h, _fill, _stroke, _line_width, _radius)
          raise NotImplementedError, "#{self.class}#emit_rect 未实现"
        end

        def emit_line(_x1, _y1, _x2, _y2, _color, _width)
          raise NotImplementedError, "#{self.class}#emit_line 未实现"
        end

        def emit_polyline(_points, _color, _width)
          raise NotImplementedError, "#{self.class}#emit_polyline 未实现"
        end

        def emit_polygon(_points, _fill, _stroke, _line_width)
          raise NotImplementedError, "#{self.class}#emit_polygon 未实现"
        end

        def emit_text(_entry, _x, _y)
          raise NotImplementedError, "#{self.class}#emit_text 未实现"
        end

        def emit_clip_begin(_x, _y, _w, _h)
          raise NotImplementedError, "#{self.class}#emit_clip_begin 未实现"
        end

        def emit_clip_end
          raise NotImplementedError, "#{self.class}#emit_clip_end 未实现"
        end

        def text_entry(_text, **_kwargs)
          raise NotImplementedError, "#{self.class}#text_entry 未实现"
        end
      end

      # 一条文本布局缓存项：绘制对象 + 度量结果 + 释放所需的 libui 对象。
      # 不是冻结接口的一部分（应用只拿到绘制方法，拿不到它）。
      TextEntry = Struct.new(:text, :size, :weight, :family, :color, :wrap_width, :align,
                             :layout, :attr_string, :font, :measured_width, :measured_height,
                             keyword_init: true)

      include Primitives

      attr_reader :width, :height

      # @param ctx   [Fiddle::Pointer] uiDrawContext（只在本次 Draw 回调内有效）
      # @param cache [TextCache] 文本布局缓存：跨帧复用，由适配层按面板持有（随面板销毁 clear!）
      # @param clip  [Array, nil] 当前可见区 [x, y, w, h]（内容坐标；nil = 整块面板可见）
      def initialize(ctx:, width:, height:, cache:, clip: nil)
        self.class.libui!
        @ctx = ctx
        @width = width.to_f
        @height = height.to_f
        @cache = cache
        @clip = clip || [0.0, 0.0, @width, @height]
        @brush = ::LibUI::FFI::DrawBrush.malloc
        @brush.Type = ::LibUI::DrawBrushTypeSolid
        @stroke = ::LibUI::FFI::DrawStrokeParams.malloc
        @stroke.Cap = ::LibUI::DrawLineCapFlat
        @stroke.Join = ::LibUI::DrawLineJoinMiter
        @stroke.MiterLimit = ::LibUI::DrawDefaultMiterLimit
      end

      private

      # ── 平台实现：真 libui 调用 ──────────────────────────────
      # 路径（uiDrawPath）是"一次性"对象：画完立刻 uiDrawFreePath，不能跨图元复用
      # （libui 没有 reset API，且路径不归 Ruby GC 管——漏 free 就是每帧漏一段 C 内存）。

      def emit_rect(x, y, w, h, fill, stroke, line_width, radius)
        with_path do |path|
          if radius.positive?
            round_rect(path, x, y, w, h, radius)
          else
            ::LibUI.draw_path_add_rectangle(path, x, y, w, h)
          end
          ::LibUI.draw_path_end(path)
          fill_path(path, fill)
          stroke_path(path, stroke, line_width)
        end
      end

      def emit_line(x1, y1, x2, y2, color, width)
        with_path do |path|
          ::LibUI.draw_path_new_figure(path, x1, y1)
          ::LibUI.draw_path_line_to(path, x2, y2)
          ::LibUI.draw_path_end(path)
          stroke_path(path, color, width)
        end
      end

      def emit_polyline(points, color, width)
        with_path do |path|
          trace(path, points)
          ::LibUI.draw_path_end(path)
          stroke_path(path, color, width)
        end
      end

      def emit_polygon(points, fill, stroke, line_width)
        with_path do |path|
          trace(path, points)
          ::LibUI.draw_path_close_figure(path)
          ::LibUI.draw_path_end(path)
          fill_path(path, fill)
          stroke_path(path, stroke, line_width)
        end
      end

      def emit_text(entry, x, y)
        # (x, y) 是整段文本外接矩形的**左上角**（libui 的语义），不是基线
        ::LibUI.draw_text(@ctx, entry.layout, x, y)
        self
      end

      def emit_clip_begin(x, y, w, h)
        ::LibUI.draw_save(@ctx)
        with_path do |path|
          ::LibUI.draw_path_add_rectangle(path, x, y, w, h)
          ::LibUI.draw_path_end(path)
          ::LibUI.draw_clip(@ctx, path)
        end
      end

      def emit_clip_end
        ::LibUI.draw_restore(@ctx)
        self
      end

      def text_entry(text, size:, weight:, family:, color:, wrap_width:, align:)
        @cache.entry(string: text, size: size, weight: weight, family: family, color: color,
                     wrap_width: wrap_width, align: align)
      end

      def with_path
        path = ::LibUI.draw_new_path(::LibUI::DrawFillModeWinding)
        begin
          yield path
        ensure
          ::LibUI.draw_free_path(path)
        end
        self
      end

      def trace(path, points)
        points.each_with_index do |(x, y), index|
          index.zero? ? ::LibUI.draw_path_new_figure(path, x, y)
                      : ::LibUI.draw_path_line_to(path, x, y)
        end
      end

      # 圆角矩形：四角各一段 90° 圆弧（y 轴向下，角度从 +x 往 +y 增长即顺时针）
      def round_rect(path, x, y, w, h, radius)
        half_pi = Math::PI / 2
        ::LibUI.draw_path_new_figure_with_arc(path, x + radius, y + radius, radius, Math::PI, half_pi, 0)
        ::LibUI.draw_path_line_to(path, x + w - radius, y)
        ::LibUI.draw_path_arc_to(path, x + w - radius, y + radius, radius, -half_pi, half_pi, 0)
        ::LibUI.draw_path_line_to(path, x + w, y + h - radius)
        ::LibUI.draw_path_arc_to(path, x + w - radius, y + h - radius, radius, 0.0, half_pi, 0)
        ::LibUI.draw_path_line_to(path, x + radius, y + h)
        ::LibUI.draw_path_arc_to(path, x + radius, y + h - radius, radius, half_pi, half_pi, 0)
        ::LibUI.draw_path_close_figure(path)
      end

      def fill_path(path, color)
        return if color.nil?

        @brush.R = color[0]
        @brush.G = color[1]
        @brush.B = color[2]
        @brush.A = color[3]
        ::LibUI.draw_fill(@ctx, path, @brush)
      end

      def stroke_path(path, color, width)
        return if color.nil? || width <= 0

        @brush.R = color[0]
        @brush.G = color[1]
        @brush.B = color[2]
        @brush.A = color[3]
        @stroke.Thickness = width
        ::LibUI.draw_stroke(@ctx, path, @brush, @stroke)
      end

      # 文本布局缓存（每个面板一份，见类注释）。面板销毁时必须 clear!。
      #
      # 键除设计里写的 (string, size, weight, family) 还带上 color / wrap_width / align：
      # 颜色是烘进 attributed string 的属性（涨跌红绿靠它），宽度与对齐决定换行与外接
      # 矩形——少任何一项，缓存命中都会拿到"另一段文本"的布局。
      class TextCache
        ALIGN_CODES = { left: :DrawTextAlignLeft, center: :DrawTextAlignCenter,
                        right: :DrawTextAlignRight }.freeze

        def initialize
          Painter.libui!
          @entries = {}
          @fonts = {}
        end

        # 取（或建）一条布局缓存
        def entry(string:, size:, weight:, family:, color:, wrap_width:, align:)
          @entries[[string, size, weight, family, color, wrap_width, align]] ||=
            build(string, size, weight, family, color, wrap_width, align)
        end

        # 释放全部 libui 对象（顺序：layout → 它引用的 attributed string / 字体描述符）
        def clear!
          @entries.each_value do |cached|
            ::LibUI.draw_free_text_layout(cached.layout)
            ::LibUI.free_attributed_string(cached.attr_string)
          end
          @entries.clear
          @fonts.each_value do |font|
            # 只有 uiLoadControlFont 填过的描述符能交给 uiFreeFontDescriptor；
            # 自建 family 的（Family 指向我们自己的 buffer）交给它会被 free 掉
            # 不该 free 的内存——实测直接 abort 进程（GOALS 变更日志 NA-1）
            ::LibUI.free_font_descriptor(font[:descriptor]) if font[:libui_owned]
          end
          @fonts.clear
          self
        end

        # 缓存条目数（测试断言"布局真的被复用"用：画 100 帧，条目数不该跟着涨）
        def entry_count = @entries.size

        def font_count = @fonts.size

        private

        def build(string, size, weight, family, color, wrap_width, align)
          font = font_for(size, weight, family)
          attr_string = attributed_string(string, color)
          params = ::LibUI::FFI::DrawTextLayoutParams.malloc
          params.String = attr_string
          params.DefaultFont = font[:descriptor]
          params.Width = wrap_width
          params.Align = ::LibUI.const_get(ALIGN_CODES.fetch(align))
          layout = ::LibUI.draw_new_text_layout(params)

          width_ptr = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE, Fiddle::RUBY_FREE)
          height_ptr = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE, Fiddle::RUBY_FREE)
          ::LibUI.draw_text_layout_extents(layout, width_ptr, height_ptr)
          TextEntry.new(text: string, size: size, weight: weight, family: family, color: color,
                        wrap_width: wrap_width, align: align, layout: layout,
                        attr_string: attr_string, font: font,
                        measured_width: double_at(width_ptr), measured_height: double_at(height_ptr))
        end

        # 字号与字重都写在**字体描述符**上（libui 用 params.DefaultFont 铺满整段文本），
        # 颜色作为属性烘进 attributed string（涨跌红绿）
        def attributed_string(string, color)
          attr_string = ::LibUI.new_attributed_string(string)
          bytes = string.bytesize
          return attr_string if bytes.zero? || color.nil?

          # uiAttributedStringSetAttribute 接管属性所有权（uiFreeAttributedString 连它们一起释放），
          # 因此这里**不能**再 uiFreeAttribute——那是 double free
          ::LibUI.attributed_string_set_attribute(attr_string, ::LibUI.new_color_attribute(*color), 0, bytes)
          attr_string
        end

        # 字体描述符缓存：默认走 uiLoadControlFont（系统控制字体，Family 由 libui 分配），
        # 显式给了 family 就自己填——那条路的 Family 指向我们 malloc 的 buffer，
        # 结构体与 buffer 都交给 Fiddle 的 RUBY_FREE 释放（见 clear! 的说明）
        def font_for(size, weight, family)
          @fonts[[size, weight, family]] ||= if family.nil?
                                               descriptor = ::LibUI::FFI::FontDescriptor.malloc
                                               ::LibUI.load_control_font(descriptor)
                                               descriptor.Size = size
                                               descriptor.Weight = weight
                                               { descriptor: descriptor, buffer: nil, libui_owned: true }
                                             else
                                               buffer = Fiddle::Pointer.malloc(family.bytesize + 1, Fiddle::RUBY_FREE)
                                               buffer[0, family.bytesize + 1] = "#{family}\0"
                                               descriptor = ::LibUI::FFI::FontDescriptor.malloc
                                               descriptor.Family = buffer
                                               descriptor.Size = size
                                               descriptor.Weight = weight
                                               descriptor.Italic = ::LibUI::TextItalicNormal
                                               descriptor.Stretch = ::LibUI::TextStretchNormal
                                               { descriptor: descriptor, buffer: buffer, libui_owned: false }
                                             end
        end

        def double_at(pointer) = pointer[0, Fiddle::SIZEOF_DOUBLE].unpack1("d")
      end

      # 记录图元调用序列（Memory 后端与 demo 的绘制断言用；不画任何东西）。
      # 与真 Painter 共用同一份 Primitives：归一后的参数进 @calls。
      #
      # 度量是**桩**：没有 libui 就没有真字体度量，measure_text 按字符数粗估
      # （CJK 按两个字符宽），只保证"量出来是正数、随字号变大"这类弱断言。
      # 需要真度量的测试跑真控件冒烟（test/support/libui_scenario.rb）。
      class Recording
        include Primitives

        attr_reader :width, :height, :calls

        def initialize(width: 0, height: 0, clip: nil)
          @width = width.to_f
          @height = height.to_f
          @clip = clip || [0.0, 0.0, @width, @height]
          @calls = []
        end

        # 图元类型序列：[:rect, :text, :clip_begin, :clip_end]
        def types = @calls.map(&:first)

        # 某一类图元的参数：rec.calls_of(:text).first[:color]
        def calls_of(type) = @calls.select { |(name, _)| name == type }.map(&:last)

        def to_s = "#<Citrine::Native::Painter::Recording #{types.inspect}>"

        private

        def record(type, **args)
          @calls << [type, args]
          self
        end

        def emit_rect(x, y, w, h, fill, stroke, line_width, radius)
          record(:rect, x: x, y: y, w: w, h: h, fill: fill, stroke: stroke,
                        line_width: line_width, radius: radius)
        end

        def emit_line(x1, y1, x2, y2, color, width)
          record(:line, x1: x1, y1: y1, x2: x2, y2: y2, color: color, width: width)
        end

        def emit_polyline(points, color, width)
          record(:polyline, points: points, color: color, width: width)
        end

        def emit_polygon(points, fill, stroke, line_width)
          record(:polygon, points: points, fill: fill, stroke: stroke, line_width: line_width)
        end

        def emit_text(entry, x, y)
          record(:text, text: entry.text, x: x, y: y, size: entry.size, weight: entry.weight,
                        family: entry.family, color: entry.color, align: entry.align,
                        width: entry.wrap_width)
        end

        def emit_clip_begin(x, y, w, h)
          record(:clip_begin, x: x, y: y, w: w, h: h)
        end

        def emit_clip_end = record(:clip_end)

        def text_entry(text, size:, weight:, family:, color:, wrap_width:, align:)
          TextEntry.new(text: text, size: size, weight: weight, family: family, color: color,
                        wrap_width: wrap_width, align: align,
                        measured_width: estimate_width(text, size), measured_height: size * 1.25)
        end

        def estimate_width(text, size)
          units = text.each_char.sum { |char| char.bytesize > 1 ? 2 : 1 }
          units * size * 0.55
        end
      end

      class << self
        # libui 只在真要用它时加载：Memory 后端下的单测不碰动态库
        def libui!
          require "libui"
        rescue LoadError => e
          raise Citrine::Native::ToolkitUnavailableError,
                "自绘面板需要 libui（#{e.message}）：纯逻辑测试请用 Memory 后端"
        end
      end
    end
  end
end
