# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

# 发布元数据对拍：把"版本号"这条线在**五个地方**互相锁住，任一处漂了就红。
#
#   version.rb ←→ CHANGELOG 的最新已发布条目
#   version.rb ←→ gemspec（spec.version 直接来自 version.rb，这里验它确实读到了）
#   version.rb ←→ Gemfile.lock 里对自身的记录（忘记 bundle install 会漂）
#   gemspec.files ←→ 仓库里真实存在的 lib/**/*.rb 与四份必需文档
#   CI / 发布工作流里的 Ruby 版本 ⊆ gemspec.required_ruby_version
#   发布工作流的触发条件与 OIDC 权限（Trusted Publishing 的两个硬前置）
#
# **不覆盖**（如实声明）：工作流在 GitHub 上是否真的能跑通——那要第一次真跑；
# 本文件只保证"能被本机证明的引用关系"是对的。
class ReleaseMetadataTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def read(relative) = File.read(File.join(ROOT, relative), encoding: "UTF-8")

  def gemspec = @gemspec ||= Gem::Specification.load(File.join(ROOT, "citrine-native.gemspec"))

  def version = Citrine::Native::VERSION

  def changelog_headings
    read("CHANGELOG.md").scan(/^## \[([^\]]+)\](?: - (\S+))?/).map { |name, date| [name, date] }
  end

  def test_version_matches_latest_released_changelog_entry
    headings = changelog_headings
    assert_equal "Unreleased", headings.first.first, "CHANGELOG 的第一节应该是 [Unreleased]"

    released = headings.map(&:first).reject { |name| name == "Unreleased" }
    refute_empty released, "CHANGELOG 里没有任何已发布版本条目"
    assert_equal version, released.first,
                 "version.rb（#{version}）与 CHANGELOG 最新已发布条目（#{released.first}）不一致"
  end

  def test_released_changelog_entries_have_iso_dates
    entries = changelog_headings.reject { |name, _| name == "Unreleased" }
    refute_empty entries

    entries.each do |name, date|
      assert_match(/\A\d{4}-\d{2}-\d{2}\z/, date.to_s, "CHANGELOG 的 [#{name}] 缺 ISO 日期")
    end
  end

  def test_gemspec_metadata_is_consistent
    spec = gemspec
    assert_equal "citrine-native", spec.name
    assert_equal version, spec.version.to_s, "gemspec 的 version 与 version.rb 不一致"
    assert_equal ["lib"], spec.require_paths
    assert_equal spec.homepage, spec.metadata["source_code_uri"]
    assert_equal "#{spec.homepage}/blob/main/CHANGELOG.md", spec.metadata["changelog_uri"]
    assert_equal "MIT", spec.license
  end

  def test_gemspec_packages_every_library_file_and_required_doc
    files = gemspec.files
    missing_lib = Dir.glob(File.join(ROOT, "lib/**/*.rb")).map { |path| path.delete_prefix("#{ROOT}/") } - files
    assert_empty missing_lib, "gemspec 的 files 漏了这些库文件：#{missing_lib.inspect}"

    %w[README.md LICENSE GOALS.md CHANGELOG.md].each do |doc|
      assert_includes files, doc, "gemspec 的 files 里没有 #{doc}"
      assert_path_exists File.join(ROOT, doc), "#{doc} 不存在，但 gemspec 声称打包它"
    end
  end

  # 版本号与锁文件必须**在同一个提交里**一起更新。
  #
  # 为什么看 git 而不是工作树：`bundle exec`（以及 rake）会在跑测试前把工作树里的
  # Gemfile.lock 自动修好（路径依赖的版本变化会触发 bundler 重写），所以读工作树
  # **永远修不出漂移**——实测确认过（把 version.rb 改成 0.1.1 后锁文件被顺手改写）。
  # CI 检出的正是"提交里的那份"，所以断言对象是 HEAD。
  def test_committed_version_and_gemfile_lock_agree
    committed_version = git_show("lib/citrine/native/version.rb")
    committed_lock = git_show("Gemfile.lock")
    skip "不在 git 仓库里（或文件未纳入版本控制）" if committed_version.empty? || committed_lock.empty?

    version_in_head = committed_version[/VERSION\s*=\s*"([^"]+)"/, 1]
    recorded = committed_lock.scan(/^    citrine-native \(([^)]+)\)$/).flatten.uniq

    refute_nil version_in_head, "HEAD 的 version.rb 里读不到 VERSION"
    refute_empty recorded, "HEAD 的 Gemfile.lock 里找不到自身版本记录"
    assert_equal [version_in_head], recorded,
                 "HEAD 的 Gemfile.lock 记录 #{recorded.inspect}，而 HEAD 的 version.rb 是 #{version_in_head}" \
                 "——两者要在同一个提交里一起更新"
  end

  # CHANGELOG 必须有当前版本号那一节（发版前漏写条目 → 红）
  def test_changelog_has_an_entry_for_the_current_version
    released = changelog_headings.map(&:first).reject { |name| name == "Unreleased" }
    assert_includes released, version,
                    "CHANGELOG 里没有 [#{version}] 这一节（标题格式 `## [#{version}] - YYYY-MM-DD`）"
  end

  def git_show(path)
    `git -C "#{ROOT}" show HEAD:#{path} 2>/dev/null`
  end

  def test_ci_and_release_ruby_versions_are_supported
    requirement = Gem::Requirement.new(gemspec.required_ruby_version.to_s)

    ci = YAML.safe_load(read(".github/workflows/ci.yml"))
    ci_versions = ci.dig("jobs", "test", "strategy", "matrix", "ruby") || []
    refute_empty ci_versions, "ci.yml 的 matrix 里没声明 ruby 版本"

    release = YAML.safe_load(read(".github/workflows/release.yml"))
    release_version = release.dig("jobs", "gem", "steps").filter_map { |step| step["with"] && step["with"]["ruby-version"] }
    refute_empty release_version, "release.yml 里没声明 ruby-version"

    (ci_versions + release_version).each do |raw|
      value = raw.to_s
      assert requirement.satisfied_by?(Gem::Version.new(value)),
             "工作流用的 Ruby #{value} 不满足 gemspec.required_ruby_version（#{requirement}）"
    end
  end

  def test_release_workflow_has_trusted_publishing_preconditions
    release = YAML.safe_load(read(".github/workflows/release.yml"))
    job = release.dig("jobs", "gem")

    # YAML 1.1 把裸 `on` 解析成布尔 true——两条键都试
    trigger = release["on"] || release[true]
    assert_equal ["v*"], trigger&.dig("push", "tags"),
                 "发布工作流必须只由 v* 标签触发"
    assert_equal "write", job.dig("permissions", "id-token"),
                 "Trusted Publishing（OIDC）需要 id-token: write"
    assert_equal "write", job.dig("permissions", "contents"),
                 "要往 GitHub Release 附产物就需要 contents: write"

    # 门禁与构建：先跑测试，再构建，最后才 push（顺序错了会把没测过的 gem 发出去）
    names = job["steps"].map { |step| step["name"].to_s }
    gate = names.index { |name| name.include?("门禁") }
    build = names.index { |name| name.include?("构建 gem") }
    push = names.index { |name| name.include?("发布到 RubyGems") }
    refute_nil gate
    refute_nil build
    refute_nil push
    assert_operator gate, :<, build, "门禁必须在构建之前"
    assert_operator build, :<, push, "构建必须在发布之前"

    # 标签与 VERSION 的一致性校验必须存在（发布错版本的防线）
    assert(names.any? { |name| name.include?("校验标签") }, "缺少标签与 VERSION 一致性校验步骤")
  end

  def test_releasing_doc_exists
    assert_path_exists File.join(ROOT, "RELEASING.md"), "缺少发布手册（RELEASING.md）"
  end
end
