# 剩余问题（不阻塞本次交付）

状态：随交付推进更新。阻塞项不写在这里，走对应任务的修复派发。

## 待修（影响体验，但不阻塞"能跑"）

| id | 问题 | 位置 | 处理 |
|---|---|---|---|
| D1 | 原生终端窗口内容**横向溢出**：三列布局的自然宽度超过窗口宽度，最右列（交易下单/成交与挂单表头）被窗口右缘裁掉。协调者截图核对（/tmp/market_view.png）确认 | `citrine-market-terminal/native/app.rb`（`WINDOW = 1440×860`）与各面板的固定尺寸 | 待 MARKET-2 验收确认后派给 MARKET-1 开发者：调大默认窗口（本机屏幕 2855×1195 点，1560×950 可容）或收窄右列 |
| D2 | ~~`citrine-sheets/native/README.md:45,63` 仍写"`clip_rect` 对滚动面板**偏大 ~18px**（596×684 vs 可见 579×667）"~~ → **NA-1e 只读复核（2026-09-15）：sheets 侧已改到位**（第 45 行"现在报的是精确可见区…唯一的例外是首帧瞬态"、第 63 行表格"曾偏大、现已精确"） | citrine-sheets 仓（**不在本仓**：NA-1d 只上报、NA-1e 只读复核） | ✅ 关闭：不需要再派发 |

## 框架侧打磨

| id | 问题 | 说明 | 状态 |
|---|---|---|---|
| F1 | **area 拿不到空间就静默变 0×0 / 细条**（判据是"它**在容器链逐层**有没有 stretchy 尺寸"；**单个**面板在 stack 里不给 `flex_grow` 也有剩余空间——"没有尺寸来源就 0×0"是过度概括，NA-1e 改）——两个移植都踩过 | dev_mode 提醒"这个面板被压扁了（拿到了 0 尺寸 / 控件被挤成一条 / 滚动面板真实可见视口被挤扁）"已落地（`Renderer#warn_starved_area`，绘制回调里按节点去重）。**NA-1d 扩充**：非滚动面板的"挤成细条"（实测 753×16）与滚动面板的**视口塌陷**（Painter 只看到声明的内容尺寸 2000×2000，实测视口 736×16）旧口径都不报，现在并入（阈值 24pt，启发式）。**NA-1e**：判据 ② 只对**非滚动**面板（滚动面板的 Painter 尺寸是声明的内容尺寸，"内容矮、视口正常"是健康形状，旧口径误报"控件被挤成一条：2000.0×20.0"），滚动面板只由判据 ③ 说话；判据 ③ 的视口数字取自**当帧**（首帧可能偏大 ~17pt），提示文本里已如实标注；盲区 ①–⑤（阈值是启发式、后端拿不到几何、不看容器占比、滚动面板只剩判据 ③、判据 ③ 的数字是当帧读数）写在 §5.1 最后一条 | ✅ NA-1d + NA-1e 完成 |
| F2 | `watch:` prop 会触发核心的「Proc 不是响应式属性」提醒（噪声） | 渲染器可覆盖 `warn_unreactive_proc`，对自身消费的 prop（`:watch`）静音 | 待修 |
| F3 | `Painter#text` 的 `y` 语义（外接矩形左上角，**不是基线**）与 `align:` 依赖 `width:` 未进冻结文档 | 已补进 `native-area.md` 2.2 | ✅ NA-1c 完成 |
| F4 | `ref:` 登记在**产出该元素的组件**上（area 的 `refs[:panel]` 在面板组件，根组件看不到） | 已补文档 + 取法示例（面板自己暴露 `area_handle`）到 2.5 | ✅ NA-1c 完成 |
| F5 | `KeyEvent#raw` 当前是 `{kind: :key, …}` Hash；应用会读 `raw[:target][:tagName]` 这类路径 | 保持 Hash 或 nil（换成对象会让 `window_key` 应用当场崩），补文档 | 待修 |
| F6 | `Widgets::Memory#find_all` 必须传句柄 | 测试 API 说明写进 `widgets/memory.rb` 注释或 README | 待修 |
| F10 | `Citrine::Native.active_widgets` 是全局单值 → 同进程多窗口时定时器排到"最后建的"后端 | 文档已写明"一进程一 App"假设（`native-area.md` 2.6）；要真支持多窗口需 `every(ms, backend:)` 显式绑定 | 文档 ✅ / 绑定待做 |
| F11 | **box 会被内容钉死**（libui 的 box 布局）：放进"在父容器里没有 stretchy 尺寸"的 box 里的控件会被内容钉在最小尺寸（与 area/滚动无关，纯 label 同样复现） | 这是 SHEETS D2 的真因（不是"滚动面板不吃 flex_grow"）。正确判据（**NA-1d 改写**，NA-1c 的"每个嵌套 box 至少一个 `flex_grow` 子控件"被两个反例否证）：**参与拉伸的 box 自己要在父容器里有 stretchy 尺寸**，逐层成立才撑得开。`flex_grow` 在 libui 里只是"stretchy 布尔"、不是权重（两个 stretchy 子控件等分） | 记录在 `native-area.md` §5.7.2（含自己的复现数据与完整树）✅ NA-1d；框架不擅自改默认布局语义 |
| F12 | **绘制不裁剪到面板矩形**（AppKit `NSView` 默认 `clipsToBounds=NO`）：面板外的内容会显示，`clip_rect` 只是提示 | 记录在 §5.2/§5.7.5。要不要在适配层强制裁到面板矩形是**语义决策**（会改变现有应用的可见行为），未做 | 待决策 |
| F13 | `Recording#measure_text` 按字符数估算的偏差（`"+2.60%"`@14 估算 46.2 vs 真 50.46，偏窄 8%；CJK 偏宽 ~11%） | 已写进 2.2：桩测别断言"宽度刚好放得下"，贴合断言放真控件冒烟 | ✅ NA-1c 文档完成 |
| F17 | "面板被压扁"提醒的阈值（24pt ≈ 一行文本）是**启发式**，且只看面板自己多大、**不看容器占比** | 真要做 20pt 高的细条面板会被提醒（dev_mode: false 可关）；"面板占容器极小比例"这种形状框架读不到容器几何，只能应用自己量。写在 §5.1 最后一条的"已知盲区" | 待决策（要不要给应用一个 opt-in 的阈值/开关） |
| F18 | 滚动面板**首帧** `clip_rect` 偶发报成 NSScrollView 自己的尺寸（NA-1d 复跑：首帧 `[0,0,760,528]` vs 稳态 `[0,0,743,511]`；NA-2 4 次跑命中 2 次） | libui 在同一次 Draw 里才设 document view 的 frame，而框架的 `visibleRect` 读在它之前。只影响"首帧就按 `clip_rect` 裁剪并缓存"的应用 | 已写明（§5.7.6-6），不修 |
| F19 | 两条**不可捕获/静默**的脆弱面：① KVC 未知键 / 对非滚动视图发 `documentView` 抛 **ObjC 异常**，`rescue StandardError` 抓不住 → 进程终止；② 面板销毁后拿缓存视图指针再读**不崩、给陈旧值**（实测 `[0,0,543,343]`） | 框架当前路径不可达，靠不变量兜住（只对 `record[:scroll]` 读 `visibleRect`、`draw_area` 查 `@areas`、`forget` 清 cache）；已写进 `ObjcBridge#rect_of` 注释与 §5.7.6-7 | 已写明，不修 |
| F24 | **"面板被压扁"提醒在 Windows 的 0×0 情形永远不会亮**：提醒挂在 Draw 回调里（`warn_starved_area`），而 Windows 的 libui 对 stretchy 链断开的 area 是真的 0×0、`WM_PAINT` 不会来 → Draw 不跑 = 提醒不跑（macOS 上 0×0 面板仍有 Draw 所以能看到）。链断的静默失败与 F11 同根，且 Windows 更严格：框架 `setup_root` 的根容器那一层也算（2026-09-15 四象限探针：根/area 必须全 stretchy 才有高度） | 可能的修法是在 attach 时按"area 非 stretchy 且祖先链有非 stretchy box"提前提醒，但要对容器链做推断（误报风险），待决策 | 待决策 |

## 已确认不需要处理

| id | 说明 |
|---|---|
| F7 | `window_key` 转发走 `Component#handle_key`：组件自己定义同名方法会签名冲突（sheets 的 `Application#handle_key(ev)`）。DOM 渲染器同一入口，浏览器侧同理 → 属"别覆盖核心方法名"的既有约定，已在 sheets 原生 README 记明 |
| F8 | `uiAreaSetSize` 对非滚动面板会 abort（exit 134）→ 适配层已改成"只在滚动面板落地 + dev_mode 提醒"，并进 GOALS 风险清单 |
| F9 | `AreaHandle#scroll_to` 在 sheets 未使用：键盘导航时"是否只在跑出视口才滚"需要真人键盘验收后才能定策略 |
| F14 | ~~⌘ 键会被面板吞掉（菜单快捷键失效）~~ → NA-1c 已修（meta 一律返回 0，回调照常触发），真 OS ⌘H 对照实验见 `native-area.md` §5.7.1 |
| F15 | ~~滚动面板的 `clip_rect` 多报一个滚动条~~ → NA-1c 改成取 AppKit `visibleRect`（精确可见区），冒烟与 AppKit 对拍 |
| F16 | ~~`on_draw` 里 `repaint` 不出下一帧~~ → NA-1c 改成"绘制期请求延后到下一轮"，自排队动画验证能持续出帧 |
| F20 | ~~定时器每个 tick 漏一个常驻闭包（`@closures` 无界增长）~~ → NA-1d 改走 `queue_main_once`（执行后释放引用）；桩测锁"只用一次性槽"，真控件冒烟锁"~12 tick 后常驻闭包新增 ≤ 2" |
| F21 | ~~`AreaHandle#focus` 不校验 `makeFirstResponder:` 的 BOOL（只要窗口是 key 就返回 true）~~ → NA-1d 改成"BOOL 受理 ∧ 窗口的 `firstResponder` 真的是目标或其后代"：实测 macOS 26 上该 BOOL 对"不接受"的目标也是 YES，只转达它依然不诚实（游离视图判别用例进冒烟），语义写进设计 2.3/§5.3 |
| F22 | ~~`Clip*` 旧口径的理由写错（"含滚动条占位、比视口大"）~~ → NA-1d 改成可复现的两条（非滚动面板脏区是整窗、滚动帧是条带），结论不变（§5.7.3） |
| F23 | ~~`GOALS.md` 说 ⌘ 策略"渲染器与适配层两处同策略"~~ → 与设计 §5.7.1/代码矛盾（实为**单点**在渲染器，适配层只转达）；NA-1d 改成事实 |
