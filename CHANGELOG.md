# CHANGELOG

## [Unreleased]

### Added

- **事件层错误边界 `Citrine::Native::EventGuard`**（统一契约）：应用的事件处理器
  抛出的异常一律不抛回平台事件栈——Renderer 各 dispatch 入口（on_click / on_change /
  on_enter / 指针三态 / click 合成 / on_draw / on_key / window_key 转发）统一包
  guard，异常打 stderr（上下文 + 首 8 帧栈）后主循环继续。libui 的 `safe` 改为
  委托同一实现（输出格式两后端同口径）；GTK 绘制订阅块同步接入。
- `text_input` 的 `on_enter`（回车提交）进入核心事件面：接线先写回 Signal 再派发
  （与 on_change 同口径）。能力按后端声明：GTK 绑 entry 的 `activate` ✅；
  libui 的 entry 不暴露按键 → 适配层 warn-once 后忽略（跨后端应用不炸）。
- `area` 的 `on_wheel` 回归核心事件面（设计 2.1 v3）：载荷 `{delta_x:, delta_y:,
  modifiers:}`（beryl L1 同口径），不抑制平台默认滚动。GTK 后端走 `scroll-event`
  归一并过滤滚轮键 4-7（修复滚轮伪装成 `mouse_down button=4/5` 混进指针事件）；
  libui 的 uiArea 不投递滚轮 → 适配层 warn-once 后忽略。Widgets::Base 协议新增
  `on_enter` / `on_area_wheel`（缺省 NotImplementedError，不支持的后端实现为
  warn-once 空操作）；Memory 桩补 `fire_enter` / `fire_wheel` 触发助手。

## [0.2.0] - 2026-09-16

### Changed

- **架构拆分**：原 monolith 拆为「核心 + 后端包」。本包此后只含后端无关核心
  （Renderer / App / StyleMatrix / Painter 协议 / Widgets 协议 + Memory 桩 / Timer），
  控件实现移入 `citrine-native-libui`（libui 后端，原 monolith 的全部控件代码）与
  `citrine-native-gtk`（GTK3 试验后端）。选择后端：`Citrine::Native.run(..., backend: :名字)`，
  或直接 require 后端 gem（自设默认）。
- 版本从 0.2.0 起算：rubygems.org 上的 `citrine-native 0.1.0` 是拆分**前**的
  libui monolith（2026-09-15 发布），保留不撤。

### Added

- `Citrine::Native.register_backend` / `resolve_backend` / `default_backend`：
  后端注册与按名解析（约定 gem 名 citrine-native-<名字>、类 Widgets::<Camel>）。
- `run` / `start` 增加 `backend:` 关键字；不传时用 default_backend，都没设则抛
  `BackendNotSelectedError`（带可操作的提示）。
- 守卫：核心包不得依赖/require 任何 UI 工具包（机器校验）。

## [0.1.0] - 2026-09-15

libui 后端 monolith 的首个发布（拆分前）。能力与已知限制见
citrine-native-libui 的 CHANGELOG——该版本保留在 rubygems.org 不再更新。
