# frozen_string_literal: true

# Citrine::Native — Citrine 组件的 CRuby 原生运行时（Shoes 式：ruby app.rb 直接起窗口）。
#
# 设计与计划见 GOALS.md。当前为 N0 骨架：仅建立命名空间与版本号，
# NativeRenderer / 控件适配层 / 应用入口均未实现（Roadmap N1 起）。
#
# 本 gem 只依赖 citrine 的平台无关核心（signal / component / renderer），
# 不引入 Opal；组件代码同样只能使用平台无关 API。

require "citrine"
require_relative "native/version"

module Citrine
  module Native
    # 应用入口（N1 实现）：创建窗口、以 NativeRenderer 挂载组件、进入主循环。
    #
    #   Citrine::Native.run(Counter, title: "计数器", width: 400, height: 300)
    def self.run(_component, **_options)
      raise NotImplementedError, "citrine-native 尚未实现（N0 骨架，见 GOALS.md Roadmap）"
    end
  end
end
