# frozen_string_literal: true

require_relative "lib/citrine/native/version"

Gem::Specification.new do |spec|
  spec.name = "citrine-native"
  spec.version = Citrine::Native::VERSION
  spec.authors = ["ShiningRay"]
  spec.email = ["tsowly@hotmail.com"]

  spec.summary = "Backend-agnostic native runtime core for Citrine components"
  spec.description = "citrine-native：Citrine 组件的 CRuby 原生运行时**核心**（后端无关）。"                      "Renderer / App / StyleMatrix / Painter 协议 / Widgets 协议 + Memory 桩。"                      "控件实现按 backend: 选择：citrine-native-libui（libui）、"                      "citrine-native-gtk（GTK3）、以及未来的其它后端。"
  spec.homepage = "https://github.com/ShiningRay/citrine-native"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.glob("lib/**/*.rb") + %w[README.md CHANGELOG.md GOALS.md LICENSE]
  spec.require_paths = ["lib"]

  # 平台无关核心（signal / component / renderer 协议）由 citrine gem 提供
  spec.add_dependency "citrine", ">= 0.2"

  # 过渡依赖：citrine 0.2.0 的 sourcemap.rb 用了 base64，Ruby ≥ 3.4 起它不再是
  # 默认 gem 而 citrine gemspec 未声明——消费端在 Ruby 4.x 下会 LoadError。
  # 上游修复（citrine gemspec 补声明）发布后移除本行。
  spec.add_dependency "base64", ">= 0.2"
end
