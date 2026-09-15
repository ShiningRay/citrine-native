# SHEETS-1 citrine-sheets 原生移植

```yaml
id: SHEETS-1
package: citrine-sheets
module: native
status: in-progress
depends-on: [NA-1]
```

## objective

`bin/native` 在真窗口里跑起迷你电子表格：方向键移动选区、直接打字进入编辑、
Enter 提交、Esc 取消、⌘Z/⌘⇧Z 撤销重做、⌘B 加粗、Delete 清空、点格选中；
改一格数字后依赖重算结果与检查器同步更新。公式栏编辑走原生 `text_input` + 确认/取消按钮
（原生 entry 拿不到 Enter，见设计文档 2.3）。

## context

- 接口（冻结）：[native-area.md](../../design/native-area.md)；调度见
  [demos-native.md](../analysis/demos-native.md)
- citrine-sheets 现有代码：`app/application.rb`（**全部逻辑**：选区/编辑/撤销/格式/键盘）、
  `app/panels/*.rb`（浏览器视图，仅作参考）、`app/workbook.rb`+`formula.rb`+`evaluator.rb`+`functions.rb`
  （引擎，CRuby 可直接跑）、`app/sheets.html`（配色令牌来源）
- 环境：`export PATH="$HOME/.asdf/shims:$PATH"`；显式 `-I app -I ../citrine/lib -I ../citrine-native/lib`
  （本仓库无 Gemfile）

## path

- `citrine-sheets/app/panels/grid.rb`（去掉 CRuby 下无法加载的 Opal 专有 require，最小改动）
- `citrine-sheets/native/**`（原生视图层 + 测试）
- `citrine-sheets/bin/native`（启动器）

## verification

- 无窗口（Memory 桩后端 + `Painter::Recording`）：绘制内容断言 + 事件路径断言（点击选格、
  方向键移动、编辑提交后依赖重算与检查器同步）
- 真窗口：`bin/native` 起窗后可交互（键鼠需人手一次）
- 浏览器路径不回归：`rake test` 必须通过；`rake build`/`rake stubs`（环境允许时）
- 消融实验记录
