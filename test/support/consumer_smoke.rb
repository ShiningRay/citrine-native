# frozen_string_literal: true
$stdout.sync = true

# 消费端冒烟：**把 gem 当用户那样装**，再在仓库外用一次。
#
#   bundle exec ruby test/support/consumer_smoke.rb
#
# 为什么需要它：本仓开发态全是 path 依赖（`gem "citrine", path: "../citrine"`），
# "在我们的工作树里跑通"**不等于**"打包出来的 gem 在用户机器上能用"。这个脚本
# 全程在临时目录里做四件事，不碰工作树、不联网：
#
#   1. 本地构建两个 gem（`gem build --output`，产物落在临时目录）
#   2. 装进一个全新的 GEM_HOME（`gem install --local --ignore-dependencies`）
#   3. 在仓库**外**的空目录里 `require "citrine-native-libui"`，并断言**加载的是装好的那份**
#      （看 `$LOADED_FEATURES` 指向临时 GEM_HOME，而不是工作树的 lib/）
#   4. 用装好的 gem 把组件挂到 Memory 桩后端上跑一遍（点击 +1），断控件树
#
# 边界（如实声明）：不开真窗口（真窗口的端到端在 `rake demo_acceptance`，发布后的
# 人工验证在 RELEASING §三）；也不验证依赖能否从 RubyGems 解析——那需要网络。
# `--ignore-dependencies` 是为了不联网装依赖：citrine 的运行时依赖由系统 GEM_PATH 提供，
# 所以本脚本证明的是"**打包与加载是否正确**"，不是"依赖闭包在干净机器上能否解析"。
# 另外：用作对比的 `citrine` gem 是**从同级仓库的工作树现构建**的（不是 RubyGems 上那份），
# 所以这里验的是"两个仓库一起打出来的包能不能用"，不是"已发布的 citrine 能不能配"。
# 这两条都属于"发布后验证"（RELEASING §三）。

require "rbconfig"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("../..", __dir__)
PARENT = File.expand_path("..", ROOT)
CITRINE_DIR = File.join(PARENT, "citrine")
GEM = File.join(RbConfig::CONFIG["bindir"], "gem")
GEM_CMD = [RbConfig.ruby, GEM].freeze

module Report
  @failures = 0
  class << self
    attr_reader :failures

    def check(name, actual, expected)
      if actual == expected
        puts "ok   #{name}"
      else
        puts "FAIL #{name}\n       期望 #{expected.inspect}\n       实际 #{actual.inspect}"
        @failures += 1
      end
    end

    def check_true(name, condition, detail = nil)
      if condition
        puts "ok   #{name}#{detail ? "（#{detail}）" : ''}"
      else
        puts "FAIL #{name}#{detail ? "\n       #{detail}" : ''}"
        @failures += 1
      end
    end

    def skip(name, reason)
      puts "skip #{name}（#{reason}）"
    end
  end
end

def run(*command, chdir: nil, env: {})
  # env 放在命令数组首位才是环境变量（IO.popen([env, cmd, args...])），否则会被当成 mode；
  # chdir: nil 会报 "no implicit conversion of nil into String"，所以要按需带上
  options = { err: [:child, :out] }
  options[:chdir] = chdir if chdir
  output = IO.popen([env, *command], **options, &:read)
  [output, $?.exitstatus]
end

def build_gem(repo_dir, gemspec, output)
  out, status = run(*GEM_CMD, "build", "--output", output, gemspec, chdir: repo_dir)
  [out, status, File.exist?(output)]
end

abort "找不到 citrine 仓库：#{CITRINE_DIR}（本脚本需要两个仓库同级）" unless File.directory?(CITRINE_DIR)

Dir.mktmpdir("citrine-consumer-") do |tmp|
  gem_home = File.join(tmp, "gems")
  sandbox = File.join(tmp, "sandbox") # 仓库外的运行目录
  FileUtils.mkdir_p([gem_home, sandbox])

  puts "临时目录：#{tmp}"

  # ── 1. 本地构建两个 gem ──────────────────────────────────
  citrine_gem = File.join(tmp, "citrine.gem")
  native_gem = File.join(tmp, "citrine-native-libui.gem")

  out, status, built = build_gem(CITRINE_DIR, "citrine.gemspec", citrine_gem)
  Report.check("构建 citrine.gem", built, true)
  puts out.lines.last(3).map { |line| "      #{line}" }.join if !built || status != 0
  next unless built # 上游仓库构建不出来就到此为止（不是本仓的问题）

  out, status, built = build_gem(ROOT, "citrine-native-libui.gemspec", native_gem)
  if built
    puts "ok   构建 citrine-native-libui.gem（#{File.size(native_gem)} 字节）"
  else
    Report.check("构建 citrine-native-libui.gem", false, true)
    puts out.lines.last(5).map { |line| "      #{line}" }.join
  end
  next unless built

  # ── 2. 装进全新的 GEM_HOME ───────────────────────────────
  [citrine_gem, native_gem].each do |file|
    out, status = run(*GEM_CMD, "install", "--local", "--no-document", "--ignore-dependencies",
                      "--install-dir", gem_home, file)
    Report.check("安装 #{File.basename(file)}", status.zero?, true)
    puts out.lines.last(3).map { |line| "      #{line}" }.join unless status.zero?
  end

  installed = Dir.glob(File.join(gem_home, "gems", "citrine-native-libui-*")).first
  Report.check_true("citrine-native-libui 已装进临时 GEM_HOME", !installed.nil?, installed)

  # ── 3+4. 在仓库外 require，并用装好的那份跑一遍渲染 ──────
  probe = File.join(sandbox, "consumer_probe.rb")
  # 单引号 heredoc：探针脚本里的 `#{}` 必须原样写进去，不能被本脚本插值
  File.write(probe, <<~'RUBY')
    # 这个文件在仓库外的临时目录里，只有 gem 可用——加载到的必须是装好的那份
    require "citrine-native-libui"

    # Windows 的加载路径用反斜杠，正则两种分隔符都要认
    loaded = $LOADED_FEATURES.grep(%r{[\\/]citrine-native\.rb\z}).first.to_s
    puts "VERSION=#{Citrine::Native::VERSION}"
    puts "LOADED_FROM=#{loaded}"

    class CounterSmoke < Citrine::Component
      state :count, default: 0

      def view
        stack(gap: 8) do
          label { "计数：#{count}" }
          button(on_click: -> { self.count += 1 }) { "点我 +1" }
        end
      end
    end

    Citrine.dev_mode = false
    backend = Citrine::Native::Widgets::Memory.new
    renderer = Citrine::Native::Renderer.new(widgets: backend)
    root = renderer.mount_component(CounterSmoke.new, { title: "consumer smoke" })
    button = backend.find(root.dom, kind: :button)
    3.times { button.fire(:click) }
    puts "LABEL=#{backend.find(root.dom, kind: :label).text}"
    puts "CONSUMER_OK"
  RUBY

  # GEM_HOME 指向新装的目录；GEM_PATH 保留系统路径（citrine 的运行时依赖 listen/puma/rack
  # 是系统 gem）——所以"本 gem 与 citrine 来自新装的那份，其余依赖来自系统"
  env = {
    "GEM_HOME" => gem_home,
    "GEM_PATH" => "#{gem_home}#{File::PATH_SEPARATOR}#{Gem.path.join(File::PATH_SEPARATOR)}",
    "RUBYOPT" => nil,
    "BUNDLE_GEMFILE" => nil,
    "BUNDLE_PATH" => nil
  }
  out, status = run(RbConfig.ruby, probe, chdir: sandbox, env: env)

  Report.check("仓库外 `require \"citrine-native-libui\"` 成功", status.zero?, true)
  version_line = out[/^VERSION=(.+)$/, 1]
  Report.check("版本号与 version.rb 一致", version_line, Citrine::Native::VERSION)

  loaded_from = out[/^LOADED_FROM=(.+)$/, 1].to_s
  # Windows 上两边都可能是混合分隔符：统一成 `/` 再比前缀
  normalized = loaded_from.tr("\\", "/")
  Report.check_true("加载的是**装好的 gem**（不是工作树）",
                    normalized.start_with?(gem_home.tr("\\", "/")),
                    loaded_from.empty? ? "没读到加载路径" : loaded_from)

  Report.check("点击 3 次后计数精确为 3", out[/^LABEL=(.+)$/, 1], "计数：3")
  Report.check_true("探针跑到底", out.include?("CONSUMER_OK"), out.lines.last(3).join(" ").strip)

  unless status.zero?
    puts "--- 探针输出 ---"
    out.lines.each { |line| puts "      #{line}" }
  end
end

puts "\n#{Report.failures.zero? ? 'CONSUMER_SMOKE_OK' : "CONSUMER_SMOKE_FAILED（#{Report.failures} 项）"}"
exit(Report.failures.zero? ? 0 : 1)
