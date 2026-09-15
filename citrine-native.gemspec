# frozen_string_literal: true

require_relative "lib/citrine/native/version"

Gem::Specification.new do |spec|
  spec.name = "citrine-native"
  spec.version = Citrine::Native::VERSION
  spec.authors = ["ShiningRay"]
  spec.email = ["shiningray@users.noreply.github.com"]

  spec.summary = "CRuby native runtime for Citrine components (Shoes-style desktop apps)"
  spec.description = "citrine-native：Citrine 组件的 CRuby 原生运行时。不经 Opal/JS，" \
    "同一份信号式组件代码直接用 ruby 启动为桌面窗口应用（Shoes 精神）。" \
    "实现 Citrine::Renderer 协议，首版后端为 libui（原生控件）。"
  spec.homepage = "https://github.com/ShiningRay/citrine-native"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir["lib/**/*.rb"] + %w[README.md LICENSE GOALS.md]
  spec.require_paths = ["lib"]

  # 平台无关核心（signal / component / renderer 协议）由 citrine gem 提供
  spec.add_dependency "citrine", ">= 0.2"

  # 首个渲染后端（决策 N-1，见 GOALS.md 第三节）；适配层预留第二后端（GTK）余地
  spec.add_dependency "libui", ">= 0.1"

  # 过渡依赖：citrine 0.2.0 的 sourcemap.rb 用了 base64，Ruby ≥ 3.4 起它不再是
  # 默认 gem 而 citrine gemspec 未声明——消费端在 Ruby 4.x 下会 LoadError。
  # 上游修复（citrine gemspec 补声明）发布后移除本行。
  spec.add_dependency "base64", ">= 0.2"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
