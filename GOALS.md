# GOALS —— citrine-native（核心）

## 定位

Citrine 组件的 CRuby 原生渲染**核心**：把「组件树 → 原生控件树」的翻译
（Renderer）、窗口生命周期（App）、样式落点（StyleMatrix）、自绘面板协议
（Painter）与控件适配协议（Widgets::Base）收在一个后端无关的包里；
**控件实现全部在独立的后端包**。

## 决策

1. **后端按名选择**（2026-09-16）：`run(..., backend: :libui)` 按约定
   `require "citrine-native-<名字>"` 并实例化 `Widgets::<Camel>`；后端包被
   require 时自登记并可设 `default_backend`。选 libui/gtk 还是别的，
   是应用侧的 gem 依赖选择，核心不感知。
2. **核心零工具包依赖**（2026-09-16）：核心连 `require "libui"` 都不许出现
   （机器守卫）；Memory 桩让全部渲染语义测试在无 GUI 的 ubuntu CI 上可跑。
3. **命名沿革**：rubygems 的 citrine-native 0.1.0 是拆分前的 libui monolith；
   核心从 0.2.0 起算，0.1.0 保留不撤。

## 后端契约（新增后端照此实现）

- `Widgets::Base` 的全部协议方法（见 lib/citrine/native/widgets.rb 注释）。
- 自绘面板：实现 `create_area / area_queue_redraw / on_area_*`，绘制对象
  include `Painter::Primitives` 并落 `emit_*`。
- 命名：gem `citrine-native-<名字>`；入口 `require` 时
  `register_backend(:名字, widgets: "Citrine::Native::Widgets::<Camel>")`。
- 已知后端：citrine-native-libui（✅）、citrine-native-gtk（🧪）。
