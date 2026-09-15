# docs 索引（citrine-native）

本目录放"改动框架/跨应用交付"相关的文档；主文档仍是仓库根的 [GOALS.md](../GOALS.md)。

| 区域 | 内容 |
|---|---|
| `design/` | 专题设计（接口与验收依据） |
| `plan/analysis/` | 交付分析：任务划分、依赖、调度记录 |
| `plan/tasks/` | 任务文件（objective / context / path / verification） |
| `plan/acceptance-0.1.0.md` | **0.1.0 验收证据**：Roadmap N0–N5 每条验收口径 ↔ 当前证据（命令 + 结果），附"未验证/边界"清单与验证方法论 |
| `plan/backlog.md` | 不阻塞本次交付的剩余问题 |

## 当前

- [design/native-area.md](design/native-area.md) —— 原生自绘面板（area）能力：接口冻结，实现中
- [design/style-matrix.md](design/style-matrix.md) —— **样式能力矩阵**：citrine 的样式键在原生
  后端的落点（`:mapped` / `:painted` / `:ignored` 三档；代码侧唯一事实来源是
  `lib/citrine/native/style_matrix.rb`，L1 + L2 已实现）
- [design/platform-matrix.md](design/platform-matrix.md) —— **平台能力矩阵**：macOS 与 Windows
  两种原生实现的差异（窗口与焦点 / 布局与几何 / 运行时与生命周期），图例区分"一致 /
  如实降级 / 未实现 / 不适用"，是平台降级行为的唯一出处
- [design/semantics-coverage.md](design/semantics-coverage.md) —— **语义覆盖清单**（N3）：
  主仓 `test/` 的渲染语义断言逐条给出承担方（核心 / native / N/A）与 native 侧对应用例
- [design/element-event-matrix.md](design/element-event-matrix.md) —— **元素/事件支持矩阵**（N4）：
  18 个核心元素标签与 23 个事件词条的处置（支持 / 报错 / 提醒），机器校验在
  `test/element_event_matrix_test.rb`
- [plan/acceptance-0.1.0.md](plan/acceptance-0.1.0.md) —— **0.1.0 验收证据**（N0–N5 逐条口径 ↔
  证据；含"未验证/边界"清单与 Windows 无视觉模型时的验证方法论）。
  **N0–N5 全部 ✅**：0.1.0 已于 2026-09-15 发布到 rubygems.org（Trusted Publishing）
- [plan/analysis/demos-native.md](plan/analysis/demos-native.md) —— 让 citrine-sheets 与
  citrine-market-terminal 跑在原生窗口的交付分析
- 任务：NA-1（框架能力）、SHEETS-1 / MARKET-1（两个 demo 的移植）、NA-2 / SHEETS-2 / MARKET-2（独立验收）
