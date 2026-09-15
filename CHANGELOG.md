# CHANGELOG

本项目的所有重要变更记录于此。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

过程记录（每个里程碑的实测结论、被否证的结论、平台差异）在 [GOALS.md](GOALS.md) 的变更日志里，
本文件只列面向使用者的版本化变更。

## [Unreleased]

## [0.1.0] - 2026-09-15

首个发布版本：Citrine 组件的 CRuby 原生运行时（libui 后端），Roadmap N0–N4 全部完成。

### 加入

- **渲染器**：`Citrine::Native::Renderer` 实现 `Citrine::Renderer` 的平台钩子（控件树 = 节点树），
  复用核心的 Effect / keyed 复用 / 块级重建 / 透明容器 / 错误边界——这几项由核心保证，
  本 gem 只负责控件层（语义覆盖清单见 `docs/design/semantics-coverage.md`）
- **应用入口**：`Citrine::Native.run` / `.start`、`App#trap_quit!`（按 `Signal.list` 过滤平台
  信号，Ctrl+C 走有序拆解）、`Citrine::Native.every` / `.after` 定时器
- **元素**：`box` / `stack` / `row` / `label` / `button` / `text_input` / `check_box` /
  `element(:area)`（自绘面板）；未支持元素（textarea/select/table/img/…）**报错并给出替代建议**
- **自绘面板（area）**：绘制图元（rect / line / polyline / polygon / text / clip /
  measure_text）、鼠标与键盘事件（键名归一为 DOM 风格）、重绘调度、面板句柄
  （`repaint` / `scroll_to` / `focus`）、滚动面板
- **样式**：能力矩阵（`docs/design/style-matrix.md`，72 个键分 `:mapped` / `:painted` /
  `:ignored` 三档）；容器内边距与 stretchy 自动映射；**area 自动消费视觉底板**
  （`background` / `border` / `border_color` / `border_width` / `border_radius`，含圆角）
- **开发期提醒（dev_mode）**：未映射的样式键、没有对应概念的属性、未支持的事件、
  被压扁的面板——都按能力矩阵分档说明"为什么 / 怎么办 / 去哪看"，绝不静默丢弃
- **平台覆盖**：macOS（Cocoa）与 Windows（Win32）两种 libui 实现均已实测跑通
  （差异清单见 `docs/design/platform-matrix.md`）；CI 覆盖两个平台

### 已知限制

- 原生控件本身**无法着色**（字体/颜色/背景没有公开 API），自定义视觉要走 `element(:area)` 自绘；
  `css_class` 整块忽略（`docs/design/style-matrix.md` 第九节）
- `on_enter`（entry 回车）、`on_key_up`、`on_focus` / `on_blur`、`on_wheel` 等在原生不可用
  （逐条见 `docs/design/element-event-matrix.md`）
- Windows 上 `AreaHandle#focus` 与窗口最小尺寸不可用（如实返回 `false`，见平台能力矩阵）
- 过渡依赖 `base64`：上游 citrine 0.2.0 的 gemspec 未声明它（Ruby ≥ 3.4 起不是默认 gem），
  上游修复发布后本 gem 会移除该依赖

[Unreleased]: https://github.com/ShiningRay/citrine-native/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ShiningRay/citrine-native/releases/tag/v0.1.0
