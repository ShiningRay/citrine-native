# citrine-native

Citrine 组件的 CRuby 原生运行时：不经 Opal/JS，`ruby app.rb` 直接把信号式
组件跑成原生控件桌面应用（Shoes 精神）。

**定位**：citrine 主仓（平台无关核心 + 渲染器协议）的一个外部 Port。
同一份组件代码可跑在浏览器 DOM（Opal）/ Canvas / SSR / **原生控件（本 gem）**。

**状态**：N0 骨架——仓库与命名空间已建立，渲染器未实现。
设计、UI 库选型（决策 N-1：v0 后端 = libui）与 Roadmap（N1–N5）见 [GOALS.md](GOALS.md)。

## 目标形态（N1 验收标准）

```ruby
require "citrine-native"

class Counter < Citrine::Component
  state :count, 0

  def view
    stack(gap: 8) do
      label { "计数：#{count}" }
      button("点我 +1", on_click: -> { self.count += 1 })
    end
  end
end

Citrine::Native.run(Counter, title: "计数器", width: 400, height: 300)
```

## 开发

```bash
bundle install    # citrine 依赖开发期指向 ../citrine（path）
```

## 仓库结构

```
lib/citrine-native.rb     # gem 入口
lib/citrine/native.rb     # Citrine::Native 命名空间 + 应用入口（未实现）
lib/citrine/native/       # 版本号；后续：renderer / widgets 适配层 / app
examples/                 # 示例（N1 起）
test/                     # CRuby 单测（N3 起，widget 适配层打桩，CI 无需真窗口）
GOALS.md                  # 设计与计划主文档
```

## 约束

- 只依赖 citrine 的平台无关核心，**禁止引入 Opal/JS**
- 组件代码可移植约束、样式子集、元素词表支持范围见 GOALS.md 第五节
- 打包壳本期不做（非目标，见 GOALS.md 第二节）
