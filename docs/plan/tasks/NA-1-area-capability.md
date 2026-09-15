# NA-1 原生自绘面板能力（area）

```yaml
id: NA-1
package: citrine-native
module: native/area
status: in-progress
depends-on: []
```

## objective

citrine-native 具备**原生自绘面板**能力，足以支撑两个 dogfooding demo 的数据密集区：

- `element(:area, …)` 元素在真 libui 后端可用（`uiArea` / `uiNewScrollingArea`）
- `Citrine::Native::Painter`：矩形/线/折线/多边形/富文本/度量/裁剪图元（文档 2.2）
- 鼠标事件（click/down/up/move/wheel，本地坐标）与键盘事件（DOM 风格键名 + 修饰键）
- `window_key` 声明的全局快捷键由聚焦面板转发（文档 2.3）
- 重绘调度：`watch:` 依赖 + 最外层 settle 兜底（文档 2.4）
- 定时器：`Citrine::Native.every/after` + `Timer#stop`（文档 2.6）

## context

- 设计（接口冻结）：[docs/design/native-area.md](../../design/native-area.md)
- 既有适配层与约束：`lib/citrine/native/widgets.rb`、`widgets/libui.rb`（类注释里的三条 libui 硬约束）、
  `renderer.rb`、`native.rb`；GOALS.md 风险 7
- 参考实现思路：`citrine/lib/citrine/canvas.rb`（最外层 settle 重绘 + 命中测试）

## path

- `citrine-native/lib/citrine/native/**`
- `citrine-native/test/**`（含 `test/support/libui_scenario.rb`）
- `citrine-native/{README.md,GOALS.md,docs/**}`

## verification

- `bundle exec rake` 全绿（既有 44 项不回归 + 新增 area/定时器项）
- 真控件冒烟（子进程）：绘制 + 中文富文本 + 度量合理 + 拆解后 `uiUninit` 无泄漏、退出码 0
- 键/鼠标**投递**需人手点一次（无人值守无法产生 OS 输入）——结果记在本文件
- 消融实验：删减抽象后重跑验收，记录删除项与保留理由
