# frozen_string_literal: true

module Citrine
  module Native
    # 样式能力矩阵（机器可读；文档见 docs/design/style-matrix.md）：
    # 把 citrine 的样式 IR（`Style.normalize` 之后的 snake_case 键）逐个登记"在本后端
    # 落到哪里"。三档状态：
    #
    #   :mapped   自动映射到 libui 的既有语义（容器内边距、追加时的 stretchy…）
    #   :painted  只能自绘：`element(:area)` 会自动消费其中**视觉底板**那几个
    #             （background / border* / border_radius，见 Entry#area?），
    #             文字类的键要在 on_draw 里用 Painter 表达
    #   :ignored  原生控件没有对应概念（阴影、动画、溢出…），dev_mode 提醒后忽略
    #
    # 为什么要有这张表（而不是把判断散在提醒代码里）：应用的样式是"一份代码、多个
    # 渲染目标"，没有单一出处时"这条样式到底生效了没有"就只能靠人肉记忆——两个 demo
    # 的移植期反复踩过（2026-09-15 的 Windows 实测又踩了一次）。提醒文案、文档与测试
    # 都从这一份表读，改一处就够。
    module StyleMatrix
      MAPPED = :mapped
      PAINTED = :painted
      IGNORED = :ignored
      STATUSES = [MAPPED, PAINTED, IGNORED].freeze

      Entry = Struct.new(:status, :mapping, :note, :area, keyword_init: true) do
        # area 元素是否**自动消费**这个键（是 :painted 里的视觉底板子集）
        def area? = area == true
      end

      # 分组登记（同组共享文案；键清单来自两个 demo 的实际 CSS 普查 +
      # citrine 核心的样式词表，见文档附表）
      GROUPS = [
        # ── 布局：能落到 box 的既有语义 ──────────────────────────
        { keys: %i[display], status: MAPPED,
          mapping: "box 的方向（stack / row 已表达）",
          note: "只有 flex 布局有对应；grid 等 display 值无对应" },
        { keys: %i[flex_direction], status: MAPPED,
          mapping: "uiNewVerticalBox / uiNewHorizontalBox（由 stack / row 合成）",
          note: "用户不必手写；换方向要换控件，运行期改无效" },
        { keys: %i[gap], status: MAPPED,
          mapping: "uiBoxSetPadded（0 / 非 0 两档）",
          note: "像素级间距给不了：libui 的 padded 是开关" },
        { keys: %i[padding padding_top padding_right padding_bottom padding_left],
          status: MAPPED, mapping: "同 gap（容器内边距 → uiBoxSetPadded）",
          note: "只有两档；单边的 padding_* 不细分" },
        { keys: %i[flex_grow], status: MAPPED, mapping: "追加时的 stretchy",
          note: "libui 是布尔不是权重：多个 stretchy 子控件等分剩余空间" },
        { keys: %i[flex], status: MAPPED,
          mapping: "同 flex_grow（CSS 简写：数值 > 0 才算拉伸）",
          note: "flex-basis / flex-shrink 无对应" },

        # ── 视觉底板：area 自动消费（L2）────────────────────────
        { keys: %i[background], status: PAINTED, area: true,
          mapping: "area 的底板填充（框架在 on_draw 之前画）",
          note: "原生控件无法着色：放在 box / label 上不生效" },
        { keys: %i[border], status: PAINTED, area: true,
          mapping: "area 的描边（接受 \"1px solid #rrggbb\" 或纯颜色串）",
          note: "只画实线；dashed / dotted 按实线画并提醒" },
        { keys: %i[border_color border_width], status: PAINTED, area: true,
          mapping: "area 的描边颜色 / 宽度（border 简写的展开形式）",
          note: "分边（border_top…）无对应" },
        { keys: %i[border_radius], status: PAINTED, area: true,
          mapping: "area 底板的圆角（uiDrawPath 圆弧）",
          note: "超过短边一半会被夹取并提醒；四角不同半径无对应" },

        # ── 文字：只能自绘（Painter 能力）───────────────────────
        { keys: %i[color font_size font_weight font_family letter_spacing],
          status: PAINTED,
          mapping: "painter.text(…, color: / size: / weight: / family:)",
          note: "原生 label / button 的字体与颜色没有公开 API" },
        { keys: %i[text_align line_height font_variant_numeric],
          status: PAINTED,
          mapping: "自绘时手工排（Painter 的 align: / 行距 / 等宽数字要自己算）",
          note: "Painter#text 的 align: 需要同时给 width:" },

        # ── 无对应概念 ─────────────────────────────────────────
        { keys: %i[width height min_width max_width min_height max_height],
          status: IGNORED, mapping: nil,
          note: "libui 是拉伸式布局，没有尺寸来源；area 用 size: prop（仅滚动面板）" },
        { keys: %i[margin margin_top margin_right margin_bottom margin_left],
          status: IGNORED, mapping: nil, note: "靠容器 gap 近似" },
        { keys: %i[align_items justify_content align_self order],
          status: IGNORED, mapping: nil, note: "libui 的 box 没有对齐 / 分布能力" },
        { keys: %i[position inset top right bottom left z_index],
          status: IGNORED, mapping: nil, note: "原生控件没有定位与层叠（box 顺序即层序）" },
        { keys: %i[box_shadow opacity outline outline_width outline_offset transform filter],
          status: IGNORED, mapping: nil, note: "原生控件无法绘制这些效果" },
        { keys: %i[transition animation],
          status: IGNORED, mapping: nil, note: "原生控件自己管绘制时机，没有补间动画" },
        { keys: %i[overflow overflow_x overflow_y white_space text_overflow word_break],
          status: IGNORED, mapping: nil,
          note: "溢出 / 省略号要自绘（Painter 里手工截断，两个 demo 都已这么做）" },
        { keys: %i[cursor user_select pointer_events],
          status: IGNORED, mapping: nil, note: "原生控件自己管指针外观" },
        { keys: %i[border_style border_top border_right border_bottom border_left box_sizing],
          status: IGNORED, mapping: nil, note: "只支持整体描边（border / border_color / border_width）" },
        { keys: %i[visibility float clear],
          status: IGNORED, mapping: nil, note: "要隐藏元素请在组件里条件渲染（透明容器语义）" }
      ].freeze

      TABLE = GROUPS.each_with_object({}) do |group, table|
        group[:keys].each do |key|
          table[key] = Entry.new(status: group[:status], mapping: group[:mapping],
                                 note: group[:note], area: group[:area])
        end
      end.freeze

      UNKNOWN = Entry.new(status: IGNORED, mapping: nil,
                          note: "未在矩阵中登记，按无对应概念处理").freeze

      module_function

      # 未登记的键 → UNKNOWN（提醒时也会说"未登记"，别让应用以为登记过）
      def entry(key) = TABLE[key] || UNKNOWN

      def status(key) = entry(key).status

      def registered?(key) = TABLE.key?(key)

      # area 会自动消费的键（渲染器的底板绘制用它，测试也用它做覆盖断言）
      def area_keys = TABLE.select { |_key, value| value.area? }.keys.freeze

      # 自动映射的键（提醒时要静音；实际落地在 renderer 的 apply_padding / stretchy?）
      def mapped_keys = TABLE.select { |_key, value| value.status == MAPPED }.keys.freeze
    end
  end
end
