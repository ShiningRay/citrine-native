# MARKET-1 citrine-market-terminal 原生移植

```yaml
id: MARKET-1
package: citrine-market-terminal
module: native
status: in-progress
depends-on: [NA-1]
```

## objective

`bin/native` 在真窗口里跑起行情终端：行情按档跳动（暂停 / 1x / 2x / 4x 生效）、
蜡烛图与分时图随档位重绘、点自选行切换标的、点表头排序、市价/限价下单与撤单成功、
持仓/成交/账户统计随撮合更新。心跳由浏览器 `setInterval` 换成 `Citrine::Native.every`。

## context

- 接口（冻结）：[native-area.md](../../design/native-area.md)；调度见
  [demos-native.md](../analysis/demos-native.md)
- citrine-market-terminal 现有代码：`app/terminal.rb`（根组件：state/computed/动作/心跳/`window_key`）、
  `app/views/*.rb`（8 个面板视图，浏览器版仅作参考）、`app/market.rb`（模拟行情引擎）、
  `app/account.rb`（账户与撮合）、`app/indicators.rb`、`app/market.html`（配色令牌来源）
- 环境：`export PATH="$HOME/.asdf/shims:$PATH"`；显式 `-I app -I ../citrine/lib -I ../citrine-native/lib`

## path

- `citrine-market-terminal/native/**`（原生视图层 + 测试）
- `citrine-market-terminal/bin/native`（启动器）

## verification

- 无窗口（Memory 桩后端 + `Painter::Recording`）：自绘内容断言（表头、行情行、涨跌颜色属性、
  蜡烛/分时重绘、权益曲线）+ 交互断言（选行、排序、暂停、下单/撤单）
- 真窗口：`bin/native` 起窗后行情在一秒内跳动、图表随档重绘（键鼠需人手一次）
- 浏览器路径不回归：`rake test` 必须通过；`rake build`/`rake stubs`（环境允许时）
- 消融实验记录
