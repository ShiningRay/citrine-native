# 发布手册（RELEASING）

面向**仓库管理员**：citrine-native 怎么发一个版本。发布走 **RubyGems Trusted Publishing
（OIDC）**——流水线里没有任何 secret，也不需要在本地持有 API key。

发布链路的每一环都有机器校验（`test/release_metadata_test.rb`，随套件跑）：版本号、CHANGELOG、
gemspec、`Gemfile.lock`、CI 与发布工作流里的 Ruby 版本、工作流的触发条件与 OIDC 权限、
以及"门禁 → 构建 → 发布"的先后顺序。**唯一无法在本机证明的是"工作流在 GitHub 上真的能跑通"**，
那要第一次真跑（见下面"首次发布的额外确认"）。

## 一、一次性前置：注册 Trusted Publisher

在 <https://rubygems.org> 登录后：**Account settings → Trusted Publishers → Register**，
按下列字段填写（这些值同时被 `test/release_metadata_test.rb` 钉住，改工作流会红）：

| 字段 | 值 |
|---|---|
| Owner | `ShiningRay` |
| Repository | `citrine-native` |
| Workflow file | `release.yml` |
| Environment | 留空 |

名称占用（2026-09-15 查 rubygems.org API）：`citrine-native` 未被占用（404）。

## 二、发布一个版本

```bash
# 1. 版本与 CHANGELOG：两处必须一致（测试会查）
#    lib/citrine/native/version.rb  →  VERSION = "0.1.0"
#    CHANGELOG.md                   →  ## [0.1.0] - 2026-09-15
git commit -am "Release 0.1.0" && git push origin main

# 2. 打标签并推（标签触发发布；工作流自己会校验标签与 VERSION 一致）
git tag v0.1.0 && git push origin v0.1.0
```

推完在 Actions 里看 `Release` 工作流，它拆成两个 job、按顺序做四件事
（为什么拆 job 见 release.yml 头部注释：门禁要同级 citrine 的 path 依赖、发布要仓库在
workspace 根，两个诉求挤在一个 job 里做不到）：

1. **门禁（gate job，macOS + Windows 矩阵，与 CI 同）**：`bundle exec rake`
   （桩测 + 不开窗的真控件冒烟）——任何一台红了就没有下一步
2. **校验标签与 VERSION 一致**（不一致直接失败，不会发出错误版本）
3. **构建**：`gem build citrine-native.gemspec`
4. **发布**：附产物到 GitHub Release → OIDC 换 RubyGems 凭据 → `gem push`

## 三、发布后验证（与 §二 同等重要）

发布**前**先在本机把这两条跑掉——它们不联网，能把"打包坏了"挡在发布之前：

```bash
bundle exec rake consumer_smoke   # 构建两个 gem → 装进干净 GEM_HOME → 仓库外 require + 渲染 + 点击 +1
bundle exec rake demo_acceptance  # 两个 demo + N1/N2 示例的真窗口端到端（44 项断言）
```

发布**后**再验一次真用户路径：

```bash
# 1. 装发布出来的那个版本（不是本地构建的）
gem install citrine-native

# 2. 冒烟：真窗口跑一个例子（需要 libui 的动态库）
curl -O https://raw.githubusercontent.com/ShiningRay/citrine-native/main/examples/counter.rb
ruby counter.rb            # 窗口出现、点按钮计数 +1

# 3. 元数据对不对得上
gem info citrine-native    # 版本、依赖（含过渡依赖 base64）、源码/变更入口
```

`consumer_smoke` 与"装发布版"的区别（别把前者当后者）：脚本里的 `citrine` 是**从同级仓库
工作树现构建**的，且依赖用 `--ignore-dependencies` 跳过解析——它证明"两个仓库打出来的包能装能跑"，
不证明"依赖闭包在干净机器上能从 RubyGems 解析出来"。后者只有 §三 的第 1 步能证明。

本仓的端到端验收（`bundle exec rake demo_acceptance`）**不在发布门禁里**：它要真屏幕、真鼠标，
且依赖同级仓库，留给本机人工跑（见 `docs/plan/acceptance-0.1.0.md`）。

## 四、出错时

| 情况 | 处置 |
|---|---|
| 工作流在"校验标签与 VERSION 一致"处失败 | 删掉标签改对再打：`git push --delete origin v0.1.0`（本地 `git tag -d v0.1.0`）——**没有产物被发布** |
| 门禁失败 | 同上；修好再发 |
| 已经发布到 RubyGems 但发现有问题 | 优先发一个修复版本（`0.1.1`）；确实要撤就 `gem yank citrine-native -v 0.1.0`，并在 CHANGELOG 里记明原因 |

## 五、首次发布的额外确认

下面几项在本机无法验证，第一次发布时逐条看：

- [ ] 工作流能在 GitHub 的 runner 上装好依赖（`ruby/setup-ruby` + `bundler-cache`）并跑完门禁
- [ ] OIDC 发布这一步通过（Trusted Publisher 注册的字段与实际运行的工作流文件名必须一致）
- [ ] GitHub Release 上出现了 `.gem` 产物
- [ ] `gem install citrine-native` 之后，新环境里 `require "citrine-native"` 可用（含 `base64` 过渡依赖是否已随 `citrine` 上游修复而可移除）

## 六、过渡依赖的移除条件

`citrine-native.gemspec` 里有一条过渡依赖 `base64`：`citrine` 0.2.0 的 `sourcemap.rb` 用了它，
而 Ruby ≥ 3.4 起 `base64` 不再是默认 gem、上游 gemspec 又没声明。**上游在 citrine 的 gemspec 里
补上声明后**，删掉本仓这条依赖即可（删的时候顺手更新 CHANGELOG 与本文档第六节）。
