# 剩余问题（不阻塞本次交付）

状态：随交付推进更新。阻塞项不写在这里，走对应任务的修复派发。

## 决策清单（一眼选完）

这一节是给**你**看的：把散在下面（以及两个 demo 文档里）的"待决策"合成一张表。
每行的"建议"都基于已经做过的实测或分析，不是拍脑袋；"不决定的后果"用来排序优先级。
你只要回一行编号 + 选项，我就能接着做。

| # | 决定什么 | 不决定的后果 | 选项 | 我的建议（理由） | 代价 / 风险 |
|---|---|---|---|---|---|
| D-1 | **提交并推送**（citrine-native 累积 34 个未提交条目；两个 demo 仓库另有 8 个：market 7 个视图/README、sheets 1 个 `native/app.rb`） | 工作只在本机：CI 的"待首次运行"永远悬着、发布无从谈起、你我也无法用 PR 审阅 | ① 分批提交并推 main（框架 / 文档 / 测试 / 发布四批，demo 仓库各一批）② 只提交部分 ③ 继续不提交 | **①**——CI 首跑本身就是我们要的信息（红也是收获），且发布前必须落地 | 无改动风险；CI 首次跑可能红（那正是要拿到的反馈） ✅ **2026-09-15 已按 ① 执行**：native 四批提交（de84d36/cc4cc5d/a6bd83a/4b83fe0）+ 后续两轮发布修复；sheets 3e1bff5、market 05ec301；CI 首跑矩阵全绿 |
| D-2 | **发 0.1.0** | gem 不落地 → 消费端路径（`gem install` 与依赖闭包）永远验不了，N5 只能停在"准备完成" | ① 你在 rubygems.org 注册 Trusted Publisher（字段见 RELEASING §一），我打并推 `v0.1.0` ② 先不发 | **①**——一次性 5 分钟人工，之后每次发版零凭据；发布后我按 RELEASING §三 逐条验收 | 需要你的账号操作；发布不可逆（撤回要 yank） ✅ **2026-09-15 已发布**：Trusted Publisher 注册后标签触发的 Release 工作流全绿（红了两轮、各自暴露一处工作流结构问题，复盘见 [acceptance-0.1.0.md](acceptance-0.1.0.md) N5 行），rubygems.org 已上架 0.1.0，GitHub Release 附产物，下载的发布产物本机装包 + require + 渲染冒烟全过 |
| D-3 | **F25：根容器的 stretchy 链透明化** | 每个应用都要手写"根元素自己声明 `flex_grow: 1`"——两个 demo 都栽过，Windows（严格后端）会直接塌成 0×0 | ① 让框架根容器对链透明（组件根元素要拉伸就一起标）② 维持现状，靠 F24 挂载期提醒兜 | **② 现在**（现状能跑、提醒已挡住坑）；**① 排在下一轮有独立验收窗口时做** | ①会静默改变多根组件（fragment/portal）下的布局分配 → 必须单独一轮验收 |
| D-4 | **F12：绘制是否强制裁剪到面板矩形** | 面板外的内容会画出来（AppKit `clipsToBounds=NO`），`clip_rect` 只是提示 | ① 适配层强制裁到面板矩形 ② 维持现状 | **②**——除非出现真实的溢出困扰（这是语义变更，且两个平台本就不一致） | ①会改变现有应用的可见行为，需要重新验收两个 demo |
| D-5 | **F17：压扁提醒的阈值**（24pt 启发式） | 真做 20pt 高的细条面板会被提醒（`dev_mode: false` 可关） | ① 给应用一个 opt-in 的阈值 / 开关 ② 维持 24pt 启发式 | **② 现在**——误报目前没人遇到；① 等真被误报再做 | 小（一处判据 + 文档） |
| D-6 | **F26：原生 label 的"天然宽度顶高最小宽度"**（两个 demo 到处手写拆行；换平台要重算） | 继续靠人肉拆行；新建应用还会踩 | ① 先做 `Widgets#text_width` 度量协议（两平台）+ opt-in 的过宽提醒 ② 不做 | **① 只在还要移植第三个应用时**——现在没有需求驱动 | 新协议 + Windows 侧要走 GDI 度量（比 macOS 深一层）；桩估算误差 −8%..+11%，提醒必须 opt-in 否则误报 |
| D-7 | **F27：原生控件自己着色（L3）**（`color` / `font_size` / `font_weight` / `font_family`） | 这些键只能靠把内容搬进 area 自绘 | ① 每平台写直通桥（macOS `setFont:` / `setTextColor:`，Windows `WM_SETFONT` / `WM_CTLCOLORSTATIC`）② 不做 | **②**——收益约样式普查的一成，成本是每平台一套 + 逐控件 plumbing | 中到大；桥是"写控件属性"，比现有只读桥风险高 |
| D-8 | **F28 / F29：`css_class` 别名表 + 状态类约定**（167 个类名的体量：sheets 60 / market 107） | 类名整块丢弃（一条提醒、一个声明不生效）；两份视图的重复代码继续存在 | ① 做别名表 `map_css_class(...)` + 状态类约定 ② 不做 | **②**——触发条件是"同一份视图跑浏览器与原生"；今天的 per-target 视图已绕开 | 中（要定约定、并进 StyleMatrix 管道）；A 路径（内置 CSS 子集解析器）受结构性天花板限制 |
| D-9 | **E4：Windows 侧的 Win32 桥**（`AreaHandle#focus` 真实现、窗口最小尺寸） | Windows 上两者如实降级（点击即给焦点，所以目前不紧急） | ① 按 ObjcBridge 的可用性模式加 `Win32Bridge` ② 不做 | **②**——直到出现"挂载自动聚焦要在 Windows 成立"这类需求 | 中；需要新的桥 + 平台矩阵两列同步 |
| D-10 | **F10：多窗口的后端绑定**（`Citrine::Native.active_widgets` 是全局单值） | "一进程一 App" 假设继续（文档已写明） | ① 加 `every(ms, backend:)` 显式绑定 ② 不做 | **②**——没有多窗口需求 | 小到中；但会动定时器 API |
| D-11 | **sheets 的 `⌘B` 只能加粗、不能取消**（读不存在的 `@active_row/@active_col`，属**共享逻辑**缺陷） | 用户按第二次没法取消加粗；浏览器侧同病 | ① 修共享逻辑（顺带修浏览器侧）② 只修原生侧 ③ 保留 | **① 排在有验收窗口时**——改共享逻辑要跑浏览器侧的 parity 测试 | 中；动的是两个渲染器共享的代码 |

## 待修（影响体验，但不阻塞"能跑"）

| id | 问题 | 位置 | 处理 |
|---|---|---|---|
| D1 | ~~原生终端窗口内容**横向溢出**：三列布局的自然宽度超过窗口宽度，最右列（交易下单/成交与挂单表头）被窗口右缘裁掉~~ → **2026-09-15 复核关闭**：成因（三列按内容天然宽度布局）已由"每列 `flex_grow: 1`"消除，`native/app.rb` 的列级注释与 README 都记了这一笔 | `citrine-market-terminal/native/app.rb`（三列 flex_grow）+ `native/README.md` 的窗口尺寸一节 | ✅ 关闭：Windows 实测三列各 **467**（x=116/590/1064），最右列右缘 1531 ≤ 内容区右缘 1532，无越界；macOS 侧 README 记"没有任何截断（逐格文字量过六列表头、十行六列数值…）"。**遗留**：Windows 上的**视觉**截断（文字是否被压成省略号）还需人眼过一遍——本机没有视觉模型，只能用几何与像素采样间接判断 |
| D2 | ~~`citrine-sheets/native/README.md:45,63` 仍写"`clip_rect` 对滚动面板**偏大 ~18px**（596×684 vs 可见 579×667）"~~ → **NA-1e 只读复核（2026-09-15）：sheets 侧已改到位**（第 45 行"现在报的是精确可见区…唯一的例外是首帧瞬态"、第 63 行表格"曾偏大、现已精确"） | citrine-sheets 仓（**不在本仓**：NA-1d 只上报、NA-1e 只读复核） | ✅ 关闭：不需要再派发 |

## 框架侧打磨

| id | 问题 | 说明 | 状态 |
|---|---|---|---|
| F1 | **area 拿不到空间就静默变 0×0 / 细条**（判据是"它**在容器链逐层**有没有 stretchy 尺寸"；**单个**面板在 stack 里不给 `flex_grow` 也有剩余空间——"没有尺寸来源就 0×0"是过度概括，NA-1e 改）——两个移植都踩过 | dev_mode 提醒"这个面板被压扁了（拿到了 0 尺寸 / 控件被挤成一条 / 滚动面板真实可见视口被挤扁）"已落地（`Renderer#warn_starved_area`，绘制回调里按节点去重）。**NA-1d 扩充**：非滚动面板的"挤成细条"（实测 753×16）与滚动面板的**视口塌陷**（Painter 只看到声明的内容尺寸 2000×2000，实测视口 736×16）旧口径都不报，现在并入（阈值 24pt，启发式）。**NA-1e**：判据 ② 只对**非滚动**面板（滚动面板的 Painter 尺寸是声明的内容尺寸，"内容矮、视口正常"是健康形状，旧口径误报"控件被挤成一条：2000.0×20.0"），滚动面板只由判据 ③ 说话；判据 ③ 的视口数字取自**当帧**（首帧可能偏大 ~17pt），提示文本里已如实标注；盲区 ①–⑤（阈值是启发式、后端拿不到几何、不看容器占比、滚动面板只剩判据 ③、判据 ③ 的数字是当帧读数）写在 §5.1 最后一条 | ✅ NA-1d + NA-1e 完成 |
| F2 | ~~`watch:` prop 会触发核心的「Proc 不是响应式属性」提醒（噪声）~~ → **已修（2026-09-15 复核关闭）**：`CONSUMED_PROPS` 已把 area 的 `watch` 排除在透传属性之外，基类的 `warn_unreactive_proc` 不再误报 | 复核证据：挂载 `watch: -> { 1 }` 的面板无输出；对照组 `label(id: -> { … })`（真透传属性）仍正常提醒 | ✅ 关闭 |
| F3 | `Painter#text` 的 `y` 语义（外接矩形左上角，**不是基线**）与 `align:` 依赖 `width:` 未进冻结文档 | 已补进 `native-area.md` 2.2 | ✅ NA-1c 完成 |
| F4 | `ref:` 登记在**产出该元素的组件**上（area 的 `refs[:panel]` 在面板组件，根组件看不到） | 已补文档 + 取法示例（面板自己暴露 `area_handle`）到 2.5 | ✅ NA-1c 完成 |
| F5 | `KeyEvent#raw` 当前是 `{kind: :key, …}` Hash；应用会读 `raw[:target][:tagName]` 这类路径 | 已补进 `native-area.md` 2.3：**raw 的形态是约定的一部分**——Hash、非 nil、非对象，加字段往后加（换对象会让 `window_key` 应用当场崩） | ✅ 完成 |
| F6 | `Widgets::Memory#find_all` 必须传句柄 | 已写进 `widgets/memory.rb` 的注释：两个方法都要传子树句柄（`NativeTest` 的 `find/find_all` 已带 `container`） | ✅ 完成 |
| F10 | `Citrine::Native.active_widgets` 是全局单值 → 同进程多窗口时定时器排到"最后建的"后端 | 文档已写明"一进程一 App"假设（`native-area.md` 2.6）；要真支持多窗口需 `every(ms, backend:)` 显式绑定 | 文档 ✅ / 绑定待做 |
| F11 | **box 会被内容钉死**（libui 的 box 布局）：放进"在父容器里没有 stretchy 尺寸"的 box 里的控件会被内容钉在最小尺寸（与 area/滚动无关，纯 label 同样复现） | 这是 SHEETS D2 的真因（不是"滚动面板不吃 flex_grow"）。正确判据（**NA-1d 改写**，NA-1c 的"每个嵌套 box 至少一个 `flex_grow` 子控件"被两个反例否证）：**参与拉伸的 box 自己要在父容器里有 stretchy 尺寸**，逐层成立才撑得开。`flex_grow` 在 libui 里只是"stretchy 布尔"、不是权重（两个 stretchy 子控件等分） | 记录在 `native-area.md` §5.7.2（含自己的复现数据与完整树）✅ NA-1d；框架不擅自改默认布局语义 |
| F12 | **绘制不裁剪到面板矩形**（AppKit `NSView` 默认 `clipsToBounds=NO`）：面板外的内容会显示，`clip_rect` 只是提示 | 记录在 §5.2/§5.7.5。要不要在适配层强制裁到面板矩形是**语义决策**（会改变现有应用的可见行为），未做 | 待决策 |
| F13 | `Recording#measure_text` 按字符数估算的偏差（`"+2.60%"`@14 估算 46.2 vs 真 50.46，偏窄 8%；CJK 偏宽 ~11%） | 已写进 2.2：桩测别断言"宽度刚好放得下"，贴合断言放真控件冒烟 | ✅ NA-1c 文档完成 |
| F17 | "面板被压扁"提醒的阈值（24pt ≈ 一行文本）是**启发式**，且只看面板自己多大、**不看容器占比** | 真要做 20pt 高的细条面板会被提醒（dev_mode: false 可关）；"面板占容器极小比例"这种形状框架读不到容器几何，只能应用自己量。写在 §5.1 最后一条的"已知盲区" | 待决策（要不要给应用一个 opt-in 的阈值/开关） |
| F18 | 滚动面板**首帧** `clip_rect` 偶发报成 NSScrollView 自己的尺寸（NA-1d 复跑：首帧 `[0,0,760,528]` vs 稳态 `[0,0,743,511]`；NA-2 4 次跑命中 2 次） | libui 在同一次 Draw 里才设 document view 的 frame，而框架的 `visibleRect` 读在它之前。只影响"首帧就按 `clip_rect` 裁剪并缓存"的应用 | 已写明（§5.7.6-6），不修 |
| F19 | 两条**不可捕获/静默**的脆弱面：① KVC 未知键 / 对非滚动视图发 `documentView` 抛 **ObjC 异常**，`rescue StandardError` 抓不住 → 进程终止；② 面板销毁后拿缓存视图指针再读**不崩、给陈旧值**（实测 `[0,0,543,343]`） | 框架当前路径不可达，靠不变量兜住（只对 `record[:scroll]` 读 `visibleRect`、`draw_area` 查 `@areas`、`forget` 清 cache）；已写进 `ObjcBridge#rect_of` 注释与 §5.7.6-7 | 已写明，不修 |
| F24 | ~~**"面板被压扁"提醒在 Windows 的 0×0 情形永远不会亮**~~ → **2026-09-15 已修**：新增**挂载期**的静态判据 `Renderer#warn_strict_stretch_chain`（绘制期那三条都挂在 Draw 回调里，而 Windows 的 0×0 面板 Draw 不跑，一条都不会亮）。判据同 §5.7.2：面板自己能 stretchy，且从组件根往下的每一层 box 都 stretchy；不满足就按节点去重提醒，并指出**断在第几层的哪个 box**（或"面板自己"）。不看几何，措辞是"在严格后端（Windows）上会塌"，只在 dev_mode 下出现 | 桩测 5 条锁定（面板自己 / 祖先第 2 层 / 完整链不报 / dev_mode 静默 / 无 area 不报）；两个 demo 的真实树跑过一遍无假阳性（market 冒烟开 dev_mode）。设计记录见 `native-area.md` §5.1 末尾 | ✅ 完成 |
| F25 | **根容器对应用隐藏却参与布局推理**：框架 `setup_root` 插入的根容器（`renderer.rb` 的竖排 box）本身**不 stretchy**，所以"组件根元素必须自己声明 `flex_grow: 1`"这条应用侧规则，本质是让应用替框架的内部节点买单（SHEETS-1c 的 D2、MARKET-1 的 Windows 适配都栽在这里）。macOS 对窗口直系子元素宽容、Windows 严格，同一个坑换平台才暴露 | 建议让根容器对 stretchy 链**透明**（组件根元素要拉伸时把根容器一起标 stretchy；它是窗口的唯一直系子控件，本来就吃满 client 区）。注意：多根组件（fragment/portal）下"所有子控件都拉伸"会平分空间，改动会静默影响现有应用布局，需要一轮独立验收 | 待决策（改默认语义需要验收；F24 的挂载期提醒是低风险替代） |
| F26 | **原生 label 的天然宽度会顶高窗口最小宽度，且没有任何提醒**：libui 的 label 不换行，天然宽度 = 文本宽度，直接进窗口的内容自然尺寸下限 → 两个 demo 到处手写"拆两行/三行（原因见 …）"（Header 快捷键说明、`quote_head`/`quote_stats`、`PositionRow`、持仓 summary…），换平台（Windows 控件更高、字体度量不同）还得重算 | **可行性分析（2026-09-15，未实现）**：① 适配层**没有文本度量入口**（`TextCache` 在 painter 层、只服务自绘面板），要新开一条 `Widgets#text_width` 之类的协议 + 两个平台的度量实现；② 桩后端的字符数估算误差 −8%..+11%（F13），挂载期提醒用它必然**误报**，阈值放宽到 ~25% 才稳，那样只剩"极端过宽"报得出来；③ Windows 上拿不到 label 的文本宽度（`GetWindowRect` 给的是被 libui 拉伸过的控件尺寸），得走 GDI 度量文本，比 macOS 的 `NSAttributedString` 深一层 | 待决策（建议：先做 ①，提醒做成 **opt-in**，避免误报噪音） |
| F27 | **原生控件本身着色（样式矩阵的 L3）**：`color` / `font_size` / `font_weight` / `font_family` 这些 `:painted` 文字键，目前只能靠把内容搬进 area 自绘；想让**原生 label / button 自己**变色变字体，libui 没有公开 API，只能走平台直通桥（macOS `setFont:` / `setTextColor:`，Windows `WM_SETFONT` / `WM_CTLCOLORSTATIC`；容器背景还要子类化窗口或换成自绘面板） | 成本：每平台一套 + 逐控件 plumbing（现有 ObjcBridge 只做了 focus/几何读取，没有控件属性写入）；收益：覆盖样式普查里约一成的排版类键。定档在 L3（见 docs/design/style-matrix.md 第七节） | 待决策（评估过再决定，见 backlog E4 的同类思路） |
| F28 | **`css_class` 的桥（样式矩阵文档第九节的 B 路径）**：类名现在整块丢弃（一条"没有对应概念"的提醒、一个声明不生效），而它有 167 个类名的体量（sheets 60 / market 107）。建议做**别名表**——`Citrine::Native.map_css_class(".panel" => { background:, border: }, ".is-on" => …)`，框架不解析 CSS、只查表，结果并进 StyleMatrix 的同一套管道（`:mapped` → 控件、`:painted` → area），提醒精确到"这个类在这里为什么不生效" | 触发条件：**出现"同一份视图跑浏览器与原生"的需求**时再做（今天的 per-target 视图已绕开）；A 路径（内置 CSS 子集解析器）的门槛见文档第九节——收益受结构性天花板限制 | 待决策（等单视图需求）。**2026-09-15 注**：两个 demo 已把**设计令牌层**抽成 `app/tokens.rb` 三端共享（HTML 外链 styles.css + 入口运行时注入 :root、`native/theme.rb` 派生、共享逻辑 Format/toolbar 取值，`test/tokens_test.rb` 机器守卫），"改配色要改多处"的问题在 demo 侧解决；css_class 的**类规则**仍按本条维持现状 |
| F29 | **状态类的语义映射**（`.is-on` / `.is-edit` / `.is-buy` / `.is-sell` / `.badge-hold` …）：表达的不是样式而是"**状态 → 表现**"，原生控件没有样式位，今天只能用文案（`state_button` 的 `✓` 标记）表达；即便做了 F28 的别名表或 A 的 CSS 解析，也要**单独定一套约定**（按钮文案 / 禁用态 / 自绘标记） | 与样式键的落点是两个问题：状态类在浏览器侧靠 CSS 伪类与类切换，原生侧没有对应机制。需要时再设计（可能的长相：`state_style` 断言或组件级 `visual_state` 约定） | 待决策（等单视图需求一起评估） |

## 工程化与流程（不阻塞交付）

| id | 问题 | 处理 |
|---|---|---|
| E1 | **没有 Windows CI**：整套验证本来就能在无 GUI 的 runner 上跑（`libui_scenario.rb` 默认不开窗，Windows 实测 SMOKE_OK），但此前没有任何自动回归——今天的 AppKitProbe 崩溃、strict stretchy 链全是人工跑出来的 | ✅ **2026-09-15 落地**：新增 `.github/workflows/ci.yml`——`macos-latest + windows-latest` 矩阵跑 `bundle exec rake`（桩测 + 不开窗的真控件冒烟），跨仓 checkout（`../citrine` 同级，配合 Gemfile 的开发期 path 依赖）。边界：GUI 模式留给人工/自托管 runner，Linux 需 GTK 运行时且真控件路径会整体跳过（暂不纳入）。**待首次 CI 运行确认**（本机无法执行 GitHub Actions，YAML 已本地解析校验） |
| E2 | **平台能力矩阵没有单一出处**：非 macOS 的降级项（`AreaHandle#focus` 返回 false、`window_activate` 无效、`clip_rect` 回退 `Clip*`、窗口最小尺寸不可用）散在 GOALS 风险清单、两个 demo 的 README 与代码注释里（三处拼着看） | ✅ **2026-09-15 落地**：`docs/design/platform-matrix.md`——窗口与焦点 / 布局与几何 / 运行时与生命周期三张表（macOS × Windows），图例区分"一致 / 如实降级 / 未实现 / 不适用"，附缺口清单与写平台代码的三条约定；`native-area.md` 2.3 与 GOALS 风险 9 已引用 |
| E3 | **launcher 引导逻辑在两个 demo 里同构重复**：路径存在性检查、信号注册（`Signal.list` 过滤这种平台细节）、"先退出主循环再拆解"的顺序，各写一遍、各改一遍 | ✅ **2026-09-15 落地**：框架提供 `App#trap_quit!`（按 `Signal.list` 过滤平台实际存在的信号，返回装上的名字）与 `Citrine::Native.run(…, signals: :default)`；**默认不接管进程级信号**（`trap` 会覆盖宿主的处理器，库不该悄悄接管——有判别用例锁住）。market 的 launcher 改成一行 `app.trap_quit!`；sheets 的 `run!` 补上 `signals: :default`（此前 Ctrl+C 是硬杀、不走有序拆解）。路径存在性检查仍留在应用侧（各仓的 `CITRINE_ROOT` 约定不同） |
| E4 | 可选项：`AreaHandle#focus` / 窗口最小尺寸在 Windows 上**能真实现**（user32 `SetFocus`、`WM_GETMINMAXINFO` 一类），当前是如实降级（Windows 上点击即给 area 焦点，所以不紧急） | 等有真实需求（例如"挂载自动聚焦"要在 Windows 上也成立）再做；做时按 ObjcBridge 的可用性模式加 Win32Bridge |
| E5 | **平台能力矩阵本身没有守卫**：`docs/design/platform-matrix.md` 是人工维护的表，新增/修改降级行为时容易忘记补两列（做合并的起因就是"三份文档各散一块"） | 🟡 **可机器校验的部分已落地（2026-09-15）**：新增 `test/platform_matrix_test.rb`（5 项）——① ObjcBridge 的可用性按平台断言（macOS 可用 / 非 macOS **如实不可用**）；② 不可用时 `activate` / `window_key?` / `focus` / `rect_of` / `scrolling_document_view` 逐个如实返回 `false`/`nil`（含空句柄不崩）；③ 桥的每个能力方法都经 `available?` 守卫（按 `return false/nil unless available?` 计数，新增能力漏守卫会红）；④ 矩阵文档必须提到桥覆盖的能力名（`window_is_key` / `AreaHandle#focus` / `window_activate` / `clip_rect`）。**仍无守卫**：依赖真控件几何或进程级行为的条目（控件天然高度、布局严格性、信号集合、滚轮/双击缺失）——那些只能靠真控件冒烟与人工实测，继续由文档兜住 |

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
