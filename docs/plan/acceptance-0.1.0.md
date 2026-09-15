# 0.1.0 验收证据（Roadmap N0–N5）

> 目的：发布前把"每条验收口径 ↔ 当前证据"摊在一张表上，并**如实标出未验证项**。
> 证据全部来自本机（Windows，Ruby 4.0.6 x64-mingw-ucrt + libui 0.2.4）2026-09-15 的实跑；
> macOS 侧的历史证据在 GOALS 变更日志与各仓 README 里（会注明来源平台）。

## 一、Roadmap 验收口径逐条对照

| 里程碑 | 验收口径（GOALS 第六节） | 当前证据 | 状态 |
|---|---|---|---|
| **N0** | gemspec/Gemfile/入口占位可 `bundle install`；设计文档评审通过 | `bundle install` 冷/热都通过（macOS 3.4.8 / Windows 4.0.6）；GOALS + 4 份 design 文档 | ✅ |
| **N1** | Counter 示例在 CRuby 起真窗口，点击精确 +1 | **本机真窗口实测**：`bundle exec ruby examples/counter.rb` 起窗（400×300），用真实鼠标点击按钮 3 次 → 子控件文本从 `计数：0` 变 `计数：3`（Win32 子窗口枚举读回） | ✅ |
| **N2** | Todo 示例完整可玩（增删、勾选、回车提交） | **本机真窗口实测**（可复跑：`DEMO=todo bundle exec rake demo_acceptance`，13 项）：添加后 `待办：剩余 1 / 共 1` + 行内标签 `milk` + `删除` 按钮（提示切到"勾选表示完成"）；勾选后 `剩余 0 / 共 1`；删除后回 `共 0` + 空态提示。**输入框**：逐字符 `WM_CHAR`（用户打字的同一条路）→ `EN_CHANGE → on_change → draft`，**行真的被加进去**才算验通。⚠️ **更正**：本行早先记的"`WM_SETTEXT` 注入 → 应用内读回 `milk` 且 `on_change` 收到 `milk`"不成立——`SetWindowTextW` 只改 Edit 的内容（跨进程读回来的就是它，看着像成功），应用侧 `draft` 仍空、`add` 早退、计数停在 `共 0`；脚本化时被这 13 项断言抓出来。**回车提交不成立**（libui 的 entry 不暴露按键）——已改成按钮提交，属立项时的既定结论 | ✅（回车缺口已记录） |
| **N3** | CRuby 单测覆盖 Renderer 语义（桩后端，CI 无需真窗口） | `bundle exec rake` = 162 runs / 670 assertions / 0 failures（N3 完成时的数；现为 **169 / 712**）；对齐清单见 `semantics-coverage.md`（主仓 16 条逐条给出承担方，本轮补 7 条断言） | ✅ |
| **N4** | 对照主仓元素/事件词表出支持矩阵，未支持项全部有 dev_mode 提醒 | `element-event-matrix.md`（18 个元素标签 × 23 个事件词条逐个给处置）+ `test/element_event_matrix_test.rb`（8 项机器校验：未支持元素必须有替代建议、未支持事件必须在文档里出现）+ 7 条缺失的元素替代建议已补 | ✅ |
| **N5** | 移植一个真实应用；gem 0.1.0 发布（Trusted Publishing） | dogfooding：citrine-sheets 与 citrine-market-terminal 的原生版都在本机跑通（见下）；**0.1.0 已发布（2026-09-15）**：`v0.1.0` 标签触发 [Release 工作流](../../../.github/workflows/release.yml)（gate 矩阵 + gem 两 job）**全绿**——门禁（macos-latest + windows-latest 跑 `bundle exec rake`）→ 标签一致性校验 → `gem build` → 附产物到 GitHub Release → OIDC 换凭据 → `gem push`；**rubygems.org 已上架**（API 返回 0.1.0：依赖 base64 ≥ 0.2 / citrine ≥ 0.2 / libui ≥ 0.1、changelog/source 元数据齐全），GitHub Release 附 `citrine-native-0.1.0.gem`；发布后验证：curl 下载的**发布产物** `gem install --local` → 解析器自动补上 citrine 0.2.0 → 仓库外 require（LOADED_FROM 指向装好的那份）→ 桩渲染点击 3 次 `计数：3`。**首发红了两轮的复盘**：① 门禁跑在 ubuntu——libui 的 GTK 后端无显示服务器时 C 层 abort，rescue 拦不住（修：门禁挪 macOS + 冒烟脚本预判无显示器的 Linux）；② `rubygems/release-gem` 的 git 步骤固定在 workspace 根跑，而门禁要同级 citrine 的 path 依赖（修：拆 gate + gem 两 job，gem job 用 release-gem 内部同款 OIDC 凭据动作 + `gem push`）；对拍测试同步加强（needs: gate / 两 job 的 Ruby 版本 / 校验先于构建），两次红灯各加 3 条断言 | ✅ |

## 二、平台与集成（本机 Windows 实测）

| 项 | 命令 / 方法 | 结果 |
|---|---|---|
| 框架套件（桩后端） | `bundle exec rake` | 178 runs / 762 assertions / 0 failures（1 skip） |
| 框架套件（含真窗口） | `CITRINE_NATIVE_GUI=1 bundle exec rake` | 178 / 769 / 0 failures / **0 skips** |
| 发布元数据对拍 | `test/release_metadata_test.rb`（随套件跑） | 9 项 / 50 断言：版本号 ↔ CHANGELOG（含 ISO 日期）、gemspec 元数据与打包清单、**提交里的**锁文件 ↔ 提交里的版本号（工作树的锁会被 bundler 自动改好，故看 git）、CI/发布工作流的 Ruby 版本 ⊆ `required_ruby_version`、发布工作流三条硬前置（只由 `v*` 触发、`id-token: write`、门禁→构建→发布顺序）、RELEASING.md 存在。牙齿用**临时克隆**验过（克隆里提交"只改版本号不改锁文件"→ 如期变红） |
| **消费端冒烟**（打包产物能不能用） | `bundle exec rake consumer_smoke`（= `test/support/consumer_smoke.rb`） | 10 项：构建 `citrine.gem` + `citrine-native.gem`（98 304 字节）→ 装进**全新 GEM_HOME** → 在**仓库外**空目录 `require "citrine-native"` → **断言加载的是装好的那份**（`LOADED_FROM=…\gems\citrine-native-0.1.0\lib\citrine-native.rb`，开发态的 path 依赖骗不过它）→ 版本号一致 → 挂载组件、点 3 次 → `计数：3`。不联网、不碰工作树（已确认兄弟仓库 0 改动、临时目录自清理、无 `.gem` 残留）。**边界**：`citrine` 是从工作树现构建的、依赖用 `--ignore-dependencies` 跳过解析——"依赖闭包能在干净机器上解析"只有装发布版那一步能证明（RELEASING §三） |
| 文档表格对拍 | `test/doc_table_test.rb`（随套件跑） | 2 项：每张表内**单元格数一致**（会认 GFM 转义，代码块内的管道不算）、覆盖面自检（≥10 份文档且含 GOALS.md）。全仓文档表格结构 0 问题 |
| 真控件冒烟（默认 + GUI） | `ruby test/support/libui_scenario.rb [--gui]` | `SMOKE_OK`、stderr 干净、退出码 0 |
| **citrine-sheets 原生版** | `ruby bin/native`（该仓） + `DEMO=sheets bundle exec rake demo_acceptance`（18 项） | 窗口起窗正常（内容容器 rect `46,50→1262,865`）、dev_mode 开而 `stderr` **0 字节**；**真点击选格**：A1 → `B9` → `E20`（每次都比对"改变前/后"，避免点击丢失时被旧值骗过）；**应用逻辑（鼠标可达的部分）**：`B 加粗` → `已设置格式 E20（撤销 1 / 重做 0）`、`↶ 撤销` → `已撤销（撤销 0 / 重做 1）`、`↷ 重做` → `已重做（撤销 1 / 重做 0）`、`重算全部` → `已重算全部公式：重算 132 格`；`native:test` 58/184/0。⚠️ **单元格编辑本机验不了**——编辑按键走 area 侧（libui 的 entry 收不到键，设计文档 2.3），而合成键盘投递不到 area（见第三节） |
| **citrine-market-terminal 原生版** | `ruby bin/native`（该仓） + `DEMO=market bundle exec rake demo_acceptance`（21 项） | 窗口起窗正常（头部控件行 rect `y=76..101` 可读）、`stderr` **0 字节**；**真点按钮**：`⏸ 暂停`→`▶ 继续`、`4x`→`4x ✓`、`自动交易 关`→`开 ✓`；**走时标题回读**：`第 13 档`→`第 90 档`→`第 99 档`（3 秒）；**手动下单（确定性）**：点「全部」→ `最大可买 700 股`（预估金额 956,592.00）→ 点「提交买入」→ `委托结果：成交：买入 700 股 @ 1,381.01（手续费 241.68）`、`提示：` 同步、持仓出现该只；**校验路径**：资金投完后再下单 → `委托结果：数量无效：请输入 100 的整数倍（如 100 / 500 / 1000）`（**不是静默失败**）；**自动交易真的在交易**（60 秒手工采样）：持仓 `共 1 → 2 → 3 → 4 → 6 只`、出现分页 `第 1/2 页`、`总资产` 由 1,000,000.00 漂到 952,123.67、**头部 `浮动盈亏` 与持仓面板 `浮盈` 每一帧都相等**（`+427/+427` … `-47,690/-47,690`）、运行日志 0 字节（无异常、无崩溃）；`native:test` 85/1136/0、`rake test` 29/238/0、`native:smoke` ✅（持 6 只走势图 217px ≥ 150）。**一处 UX 观察**（如实记录、未断言）：校验失败时 `提示：` 仍留着上一次的成功文案，两个标签不同步 |
| 样式 L1/L2 | `test/style_matrix_test.rb` | 16 项：矩阵自洽、`:mapped` 落地、area 底板绘制顺序与参数、响应式重读、border 三态、提醒分档 |
| 平台能力矩阵守卫（E5 部分） | `test/platform_matrix_test.rb` | 5 项：桥可用性按平台断言、不可用时五个能力方法如实降级、`available?` 守卫计数、矩阵文档对拍 |
| F24 挂载期提醒 | 真控件探针（断链树） | 警告如期在**挂载期**打出，且面板实测塌成 `396×0`（证实"Draw 不跑 → 绘制期提醒永不亮"的前提） |
| **两个 demo 的当前框架回归扫**（2026-09-15 晚） | 真窗口 + 真鼠标点击 + 子窗口标题回读 | **citrine-sheets**（`run!` → dev_mode **开**，任何断链都会打印）：窗口 1262×865 起窗正常、`stderr` **0 字节**（新框架在该应用上**不误报**）；真实点击网格 (348,481) → 表头 `A1 · 60 行 × 26 列` → **`D15 · …`**、`位置 D15`、选区行 `选区 D15 · 单元格 1 …`（坐标换算吻合、应用状态与控制标题一致）；启动提示"点一下网格即可用键盘（窗口还没拿到键盘焦点）"在点击后**消失** → 应用进入键盘模式。**citrine-market-terminal**：同样 `stderr` **0 字节**；真点 `⏸ 暂停` → **`▶ 继续`**、真点 `4x` → **`4x ✓`**、真点 `自动交易 关` → **`自动交易 开 ✓`**；**走时可读验证**：`上午盘 09:43 · 第 13 档` → `11:00 · 第 90 档` → 3 秒后 `11:09 · 第 99 档`（仿真在真实推进） |
| **上面这套动作已脚本化**（可复跑） | `bundle exec rake demo_acceptance`（目标参数：`all` / `examples` / `counter` / `todo` / `sheets` / `market`） | **58 项断言**（counter 6 / todo 13 / sheets 18 / market 21），`ok/FAIL` 逐条 + 退出码 0/1。覆盖：真窗口出现与**标题**（含"只认可见且有标题的顶层窗口"——libui 的隐藏辅助窗口会抢先，实测踩过）、`计数：0 → 3`（**N1 的"精确 +1"**）、`待办：剩余 0/共 0 → 1/共 1 → 剩余 0/共 1 → 共 0`（**N2 的增删勾选**）、网格表头/位置标签、选格必须**真的改变**（比 "A1→B9→E20"，不再被旧值骗过）+ 方向性（越往右下列号行号不更小，不依赖列宽行高）、**sheets 的应用逻辑**：`B 加粗`→`已设置格式（撤销 1 / 重做 0）`、`↶ 撤销`→`已撤销（撤销 0 / 重做 1）`、`↷ 重做`→回到已格式化、`重算全部`→`已重算全部公式：重算 N 格`（N > 0）、**market 的下单与校验**：`最大可买 N 股` → `成交：买入 N 股 @ 价格（手续费 F）` → 资金不足时 `数量无效：请输入 100 的整数倍`、`⏸ 暂停`↔`▶ 继续` 往返、`4x ✓`、**行情档位 3 秒后更大**、**自动交易真的开出新仓**（比手动那一只更多）+ **同一帧里头部「浮动盈亏」与持仓面板「浮盈」相等** + 总资产随交易变动、`WM_CLOSE` 后**进程自行退出**、log 为空。**点击取径如实标注**：优先真鼠标（校验窗口在前台 + 光标到位），拿不到前台时回退到消息级点击（`WM_LBUTTONUP/DOWN` 投给控件）并打印 `info`——桌面是共享的，用户在用机器时前台常拿不到；非 Windows 或缺同级仓库 → SKIP 且 0 退出；未知参数 → 退 2 |

## 三、未验证 / 边界（如实清单）

| 项 | 为什么未验证 | 建议 |
|---|---|---|
| **真 OS 键盘注入** | 合成输入的边界（本轮三次实测划清）：① `SetWindowTextW` 到 Edit——**只改控件内容**，应用侧 `on_change` 不来（"看起来成功"的假象，见 N2 行的更正）；② 逐字符 `WM_CHAR` 到 Edit——**成功**，走的是用户打字的同一条路（todo 的 4 条断言靠它）；③ 但到 **area** 就不行：`SendMessage(WM_KEYDOWN/WM_KEYUP)` 直投 area 句柄、以及 `AttachThreadInput` + `SetFocus(area)`（已确认 `GetFocus() == area`）后再投，两条路都投不动——sheets 的选区仍停在点击选中的 `D15`。SendKeys 本身在本环境也不可靠（前台窗口被宿主抢走） | 键盘到**原生 Edit** 已验证；键盘到**自绘 area** 仍需人手点一遍（两个 demo 的键盘路径在发布前人工过一遍） |
| **macOS 侧的 chart 重构** | chart 文字并入自绘面板后改变了 macOS 布局（走势图更高），本机无 macOS | 下次在 macOS 上复跑 `native:smoke` |
| **CI / Release 工作流首跑** | ~~本机无法执行 GitHub Actions~~ → **2026-09-15 已完成**：CI 首跑 `macos-latest + windows-latest` 全绿；Release 工作流首跑红了两轮（复盘见 §一 N5 行），修复后 `v0.1.0` 第三推全绿并真实发布 | 工作流在 GitHub 上真的能跑通——已证明 |
| **消费端 `gem install citrine-native`**（直连索引解析） | 本机两条路都不通，且都不是发布的问题：① 默认源是阿里云镜像，发布后同步有延迟（已确认上线 20 分钟内未同步）；② 直连 rubygems.org 时 Ruby 的索引下载（`specs.4.8.gz`）撞上本机 **IPv6 黑洞**（无 v6 路由，Ruby 顺序尝试卡死；curl 有 happy-eyeballs 能回退） | 已分块证明：rubygems.org API 元数据正确、.gem 可直接下载（curl）、**下载的发布产物装进本机后解析器自动补齐 citrine 0.2.0、require 与渲染全过**（LOADED_FROM 指向装好的那份）。下次网络/镜像就绪时补跑一次完整 `gem install` 即可闭环 |
| **sheets 的 ⌘B 只能加粗不能取消** | 浏览器侧共享逻辑缺陷（读不存在的 `@active_row/@active_col`），改它会改浏览器行为 | 需单独决策（demos-native.md 的"待用户决定"） |

## 四、本机验证方法论（可复现）

**先跑这个**：`bundle exec rake demo_acceptance`（或 `DEMO=examples|counter|todo|sheets|market` 只跑一个）
——本仓 N1/N2 验收示例 + 两个 demo 的真窗口端到端验收，53 项断言、`ok/FAIL` 逐条、退出码 0/1。
它把下面第 1、3 条的做法固定成了脚本（拉起 → 轮询真窗口 → 枚举子控件读标题 → 真鼠标点击 /
逐字符 `WM_CHAR` 打字 → 关窗断言进程自退）。**点击有两条路径，脚本会标注用了哪条**：优先真鼠标
（校验窗口真在前台 + 光标到位），拿不到前台时回退到**消息级点击**（`WM_LBUTTONDOWN/UP` 投给控件）
并打印 `info`——桌面是共享的，你正在用机器时前台多半拿不到（实测那一轮 5 次点击全部回退，
但断言照常成立：area 的选区、按钮的命令都走到了）。非 Windows、或缺同级仓库时 SKIP 且 0 退出；
未知参数退 2。**键盘到自绘 area 不在其中**（见第三节）；**sheets 的单元格编辑也不在其中**
（它走 area 侧按键，同上一条）。

**脚本化时踩到并已写进代码注释的三个坑**（都会让断言"看着通过"或"莫名失败"）：

1. **`bundle exec` 会多一层 ruby**：`ruby -S bundle exec ruby x.rb` 时窗口属于**孙进程**，
   按 spawn 的 pid 找窗口/关窗/判退出全部落空。改成子进程内 `RUBYOPT=-rbundler/setup`
   （`BUNDLE_GEMFILE` 指过去），保持"一个 spawn = 一个应用进程"。
2. **libui 有隐藏辅助窗口**（标题 `libui utility window`）：按 pid 取"第一个顶层窗口"会取到它
   → 标题断言读到它、`WM_CLOSE` 也没送到主窗口。改成只认**可见且有标题**的窗口；本仓示例
   还按标题精确等待。另外本机输入法会往窗口树里挂 `Sogou_TSF_UI` / `Default IME`（rect 全 0），
   无害但会出现在转储里。
3. **子控件是逐步建起来的**：任何断言都要轮询（实测"表头已出现、位置标签还差一拍"），
   否则会得到偶发假阴（第一版就这样在连跑中失败过一次）。

Windows 上没有视觉模型时，验收靠这三样（都在本次用过）：

1. **子窗口枚举读控件文本**（`EnumChildWindows` + `GetWindowTextW`）：能读到 label/button 的**标题**
   （`Static|计数：3`、`Button|添加`）——这是最硬的证据。
   ⚠️ **踩过的坑**：`GetWindowText` 跨进程只给窗口"标题"，**Edit 的内容不是标题 → 恒返回空**。
   读输入框内容必须在**应用内**读（`app.widgets.get_value(handle)`），否则会误判成"文本被清空"。
   ✅ **两个 demo 都自带可读状态面**（比像素可靠得多）：sheets 的 `A1 · 60 行 × 26 列` / `位置 D15` / `选区 D15 · 单元格 1`，
   market 的 `上午盘 11:09 · 第 99 档` / `总资产` / `浮动盈亏` / 按钮上的 `⏸ 暂停`↔`▶ 继续`、`4x ✓`、`自动交易 开 ✓`。
   凡状态能落到原生控件的**标题**上，就优先用标题回读，像素只用于"有没有画、画在哪儿"。
2. **像素采样 + 逐节点几何**（`user32 GetWindowRect` + 组件树遍历）：判"有没有画"、"在哪儿画"。
3. **文件握手驱动**（外部脚本与 app 用文件同步步骤）：避免"采样时机错位"造成的假阴/假阳
   （本次就遇到一次：dump 早于 app 的下一步，读到的是上一步的状态）。

⚠️ 另一条实测（复现框架的线程约束）：**从后台线程直接改 UI 会让 libui abort**
（`uiWindowsEnsureDestroyWindow() error ... GetLastError() == 5`，exit 3）。UI 改动必须回主线程
（`widgets.queue_main`）——本次探针踩了一次，正好反证了文档里的硬约束。
