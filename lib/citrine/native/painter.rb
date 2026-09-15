# frozen_string_literal: true

module Citrine
  module Native
    # 自绘面板的绘制协议（冻结接口见 docs/design/native-area.md 2.2，文档在后端包）。
    #
    # 三个部分各司其职，参数归一只有一份，各后端实现不会漂移：
    #   Primitives —— 图元签名 + 颜色/字重/对齐/圆角归一 + "未支持用法"的提醒收集（纯 Ruby）
    #   Recording  —— 只记录图元调用序列的桩实现（Memory 后端与"画了什么"的断言用）
    #   各后端     —— 真绘制实现（libui 包：ctx 版 Painter + TextCache；
    #                 GTK 包：GtkDrawingArea + Cairo，规划中）
    #
    # 生命周期：**一个面板一次 on_draw 一个 painter 实例，不跨帧复用**。
    # 跨帧复用的只有文本布局（libui 包的 TextCache 按面板持有、随面板销毁释放——
    # text layout / attributed string 不归 Ruby GC 管，漏 free 就是每帧漏 C 内存）。
    module Painter
      # ── "未支持用法/无效值"的提醒收集 ────────────────────────
      # painter 每帧新建（见上），自己 warn 会每帧刷屏；这里只按 key 收集，
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

        # 各后端的约定：宽度为负 = 不换行（libui：Width < 0 → CGFLOAT_MAX）
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

        # 块内裁剪（后端的 save/clip/restore）：块里照常画，矩形外的部分被裁掉
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
                         "（对齐是在给定宽度内对齐），本次按左对齐绘制")
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
        # 各后端实现：libui 包（ctx 调用）/ GTK 包（Cairo，规划中）/ Recording（记录）。

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

      # 一条文本布局缓存项：绘制对象 + 度量结果 + 释放所需的平台对象。
      # 不是冻结接口的一部分（应用只拿到绘制方法，拿不到它）。
      TextEntry = Struct.new(:text, :size, :weight, :family, :color, :wrap_width, :align,
                             :layout, :attr_string, :font, :measured_width, :measured_height,
                             keyword_init: true)

      # 记录图元调用序列（Memory 后端与 demo 的绘制断言用；不画任何东西）。
      # 与各后端的真实现共用同一份 Primitives：归一后的参数进 @calls。
      #
      # 度量是**桩**：没有平台字体度量，measure_text 按字符数粗估
      # （CJK 按两个字符宽），只保证"量出来是正数、随字号变大"这类弱断言。
      # 需要真度量的测试跑真控件冒烟（后端包的冒烟脚本）。
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
    end
  end
end
