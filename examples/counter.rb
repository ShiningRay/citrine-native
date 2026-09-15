# frozen_string_literal: true

# N1 验收示例：Counter —— 组件代码只用平台无关 API（同一份定义可原样搬到
# 浏览器 DOM / Canvas / SSR），这里由原生控件后端渲染成真窗口。
#
#   bundle exec ruby examples/counter.rb
#
# 验收口径：点击按钮，计数**精确 +1**（对齐主仓 M0 Spike A 的口径）。
# 注意按钮文本走 block（与主仓 DSL 一致）：`button(on_click: ...) { "点我 +1" }`。

begin
  require "citrine-native-libui"
rescue LoadError
  require_relative "../lib/citrine-native"
end

class Counter < Citrine::Component
  state :count, default: 0

  def view
    stack(gap: 8) do
      label { "计数：#{count}" }
      button(on_click: -> { self.count += 1 }) { "点我 +1" }
    end
  end
end

Citrine::Native.run(Counter, title: "计数器", width: 400, height: 300)
