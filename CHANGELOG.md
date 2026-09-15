# CHANGELOG

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
