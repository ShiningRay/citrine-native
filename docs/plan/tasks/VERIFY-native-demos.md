# 独立验收任务（NA-2 / SHEETS-2 / MARKET-2）

三个验收任务共用一套要求，逐条对应被审任务的 objective 与设计文档验收场景。
**验收者不得修改被审实现**（发现问题只记录并交回开发者修复）。

```yaml
id: NA-2
package: citrine-native
module: native/area
status: pending
depends-on: [NA-1]
```

```yaml
id: SHEETS-2
package: citrine-sheets
module: native
status: pending
depends-on: [SHEETS-1]
```

```yaml
id: MARKET-2
package: citrine-market-terminal
module: native
status: pending
depends-on: [MARKET-1]
```

## 共同要求

- 结论只有 `pass` 或 `blocked`；问题写清位置（file:line）、触发条件、证据（命令 + 实际输出）、
  为什么影响本次交付。
- 以实际代码与运行证据为准，开发者的完成报告只作线索。
- 复现环境：`export PATH="$HOME/.asdf/shims:$PATH"`；框架侧 `cd citrine-native && bundle exec rake`；
  demo 侧用显式 `-I` 路径（本仓库无 Gemfile）。
- 验收记录写到临时目录（如 `/tmp/citrine-reviews/{id}.md`），结论与证据同时回写对应任务文件。

## 各自要点

### NA-2（框架能力）

1. 逐条核对设计文档 2.1–2.6 的接口契约是否按冻结语义实现（元素 props、Painter 图元与
   `clip_rect`/`content_size`、事件视图与键名归一、面板句柄三方法、`every/after` 语义）。
2. 独立写**最小复现**（不抄开发者测试）：桩后端下断言 area 创建/事件分发/Hash 键表/
   `window_key` 转发/重绘调度/定时器停止/卸载无残留；`Painter::Recording` 的图元断言是否可信。
3. 真控件子进程冒烟：绘制 + 中文富文本 + 度量 + 拆解无泄漏 + 退出码 0；**人为触发一次**
   激活与键盘投递（`activate` 之后 keyWindow 是否非 nil、area 是否 first responder、按键是否到达）。
4. 反例检查：未支持 prop 是否 dev_mode 提醒、是否能与既有元素混用（label/button/entry 同树）、
   复用路径（keyed/组件重跑）下 area 是否仍正确重绘与销毁、`scroll:` 面板的 `clip_rect` 是否合理。
5. 消融实验结论是否可信（删了什么、为什么保留）。

### SHEETS-2（sheets 移植）

1. 浏览器路径不回归：`rake test`（CRuby 单测）通过；`rake build`/`rake stubs` 在环境允许时通过。
2. 无窗口测试真实覆盖：自己写一条**新**的断言（不抄开发者用例）——例如方向键移动后
   选区信号与绘制内容同时变化、编辑提交后依赖重算结果出现在绘制内容里。
3. 真窗口验收：`bin/native` 起来后，方向键/直接打字/Enter/Esc/⌘Z/⌘B/Delete 逐个实测
   （需要人手按键时记录为"人手确认"），改 B2 后毛利与毛利率在 1 秒内更新。
4. 逻辑复用审计：确认没有复制 `Sheets::Application` 的逻辑（重复代码要指出），
   且对 `app/` 的既有改动是"最小平台适配"而非行为改变。

### MARKET-2（market-terminal 移植）

1. 浏览器路径不回归：`rake test` 通过；`rake build`/`rake stubs` 环境允许时通过。
2. 无窗口测试真实覆盖：自己写一条**新**的断言——例如固定 seed 下推进一档后
   自选面板绘制内容里的最新价变化、下单后持仓/成交绘制内容变化。
3. 真窗口验收：`bin/native` 起来后行情每秒内跳动；暂停/1x/2x/4x 生效；点自选行切换标的
   （图表随之变化）；点表头排序；市价与限价下单、撤单；平仓按钮生效。
4. 心跳审计：确认 `beat` 在主线程执行（不经后台线程碰控件）、`on_unmount` 停表、
   与浏览器 `setInterval` 语义差异已记录。
