# frozen_string_literal: true

# gem 入口（RubyGems 命名惯例：require "citrine-native"）。
# 核心 = 后端无关：Renderer / App / StyleMatrix / Painter 协议 / Widgets 协议 +
# Memory 桩 + 定时器。控件实现按 backend: 选择（libui / gtk / …），
# 见 lib/citrine/native.rb 头部的说明。
require_relative "citrine/native"

# 后端 gem（citrine-native-libui / citrine-native-gtk / …）各自提供：
#   Citrine::Native.register_backend(:名字, widgets: "Citrine::Native::Widgets::类名")
#   Citrine::Native.default_backend = :名字   # 可选：require 即默认
