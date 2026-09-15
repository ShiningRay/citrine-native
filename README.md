# citrine-native

Citrine 组件的 CRuby 原生运行时**核心**（后端无关）。用纯 Ruby 写信号式组件
（[citrine](https://github.com/ShiningRay/citrine) 框架），不经 Opal/JS，直接在
桌面窗口里渲染——**控件实现按后端选择**：

| 后端 gem | 工具包 | `backend:` | 状态 |
|---|---|---|---|
| [citrine-native-libui](https://github.com/ShiningRay/citrine-native-libui) | [libui](https://github.com/libui-ruby/libui) | `:libui` | ✅ 可用（Windows/macOS 实测；控件外观受 libui 限制，见其样式矩阵） |
| [citrine-native-gtk](https://github.com/ShiningRay/citrine-native-gtk) | GTK3（原生 CSS 主题） | `:gtk` | 🧪 试验（样式天花板问题的答案：原生控件可直接着色） |
| citrine-native-qt | Qt | `:qt` | 规划中（同样的协议接口） |

## 用法

```ruby
require "citrine-native"

class Counter < Citrine::Component
  state :count, default: 0

  def view
    stack(gap: 8) do
      label { "计数：#{count}" }
      button(on_click: -> { self.count += 1 }) { "点我 +1" }
    end
  end
end

Citrine::Native.run(Counter, backend: :libui, title: "计数器", width: 400, height: 300)
```

组件代码与渲染目标完全解耦：同一份组件可以跑浏览器 DOM（Opal）、SSR 与任何
原生后端。约定：后端 gem 名 = `citrine-native-<名字>`，控件适配类 =
`Citrine::Native::Widgets::<Camel>(名字)`；非常规命名用
`Citrine::Native.register_backend` 注册。

## 本包含什么

| 部分 | 说明 |
|---|---|
| `Renderer` | 节点树 → 控件树翻译（keyed 复用、块级重建、错误边界、透明容器） |
| `App` | 窗口生命周期、主循环、信号处理（`signals: :default`） |
| `StyleMatrix` | 样式键的三档落点（`:mapped` / `:painted` / `:ignored`） |
| `Painter` 协议 | 自绘面板图元签名 + 参数归一 + `Recording` 桩 |
| `Widgets::Base` | 控件适配协议（后端实现它）+ `Widgets::Memory` 桩 |
| `Timer` | `Citrine::Native.every / after` |

**本包不含任何控件实现**，也不依赖任何 UI 工具包——那在后端 gem 里。
后端能力差异（哪些能做/哪些降级）由后端包的文档给出。
