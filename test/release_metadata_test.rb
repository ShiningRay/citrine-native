# frozen_string_literal: true

# 核心包的发布元数据对拍：版本号这条线的各处引用互相锁住。
#
#   version.rb ←→ CHANGELOG 的最新已发布条目
#   version.rb ←→ gemspec
#   version.rb ←→ Gemfile.lock 里对自身的记录（提交里的那份，见下）
#   gemspec.files ←→ 仓库里真实存在的 lib/**/*.rb 与文档
#
# 不覆盖：工作流在 GitHub 上能否跑通——那要真跑。
require "minitest/autorun"
require "yaml"

class ReleaseMetadataTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def read(relative) = File.read(File.join(ROOT, relative), encoding: "UTF-8")

  def gemspec = @gemspec ||= Gem::Specification.load(File.join(ROOT, "citrine-native.gemspec"))

  def version = Citrine::Native::VERSION

  def changelog_headings
    read("CHANGELOG.md").scan(/^## \[([^\]]+)\](?: - (\S+))?/).map { |name, date| [name, date] }
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

  # 版本号与锁文件必须**在同一个提交里**一起更新（看提交里的那份而非工作树，
  # 原因与 libui 包相同：bundler 会在跑测试前把工作树锁文件自动修好）
  def test_committed_version_and_gemfile_lock_agree
    committed_version = git_show("lib/citrine/native/version.rb")
    committed_lock = git_show("Gemfile.lock")
    skip "不在 git 仓库里（或文件未纳入版本控制）" if committed_version.empty? || committed_lock.empty?

    version_in_head = committed_version[/VERSION\s*=\s*"([^"]+)"/, 1]
    recorded = committed_lock.scan(/^    citrine-native \(([^)]+)\)$/).flatten.uniq

    refute_nil version_in_head, "HEAD 的 version.rb 里读不到 VERSION"
    refute_empty recorded, "HEAD 的 Gemfile.lock 里找不到自身版本记录"
    assert_equal [version_in_head], recorded,
                 "HEAD 的 Gemfile.lock 记录 #{recorded.inspect}，而 HEAD 的 version.rb 是 #{version_in_head}"                  "——两者要在同一个提交里一起更新"
  end

  def git_show(path)
    `git -C "#{ROOT}" show HEAD:#{path} 2>/dev/null`
  end

  def test_changelog_has_an_entry_for_the_current_version
    released = changelog_headings.map(&:first).reject { |name| name == "Unreleased" }
    assert_includes released, version,
                    "CHANGELOG 里没有 [#{version}] 这一节（标题格式 `## [#{version}] - YYYY-MM-DD`）"
  end

  def test_released_changelog_entries_have_iso_dates
    entries = changelog_headings.reject { |name, _| name == "Unreleased" }
    refute_empty entries
    entries.each do |name, date|
      assert_match(/\A\d{4}-\d{2}-\d{2}\z/, date.to_s, "CHANGELOG 的 [#{name}] 缺 ISO 日期")
    end
  end

  # 核心包不许直接依赖任何 UI 工具包（后端选择是整个拆分的前提）
  def test_core_does_not_depend_on_ui_toolkits
    spec = gemspec
    toolkit_deps = spec.dependencies.select { |d| %w[libui gtk3 qt].include?(d.name) }
    assert_empty toolkit_deps, "核心包的 gemspec 出现了 UI 工具包依赖：#{toolkit_deps.map(&:name).inspect}"
  end

  def test_core_sources_do_not_require_ui_toolkits
    lib = Dir.glob(File.join(ROOT, "lib/**/*.rb")).map { |path| File.read(path) }.join("
")
    refute lib.match?(/require ["'](libui|gtk3)["']/), "核心 lib/ 里不允许 require UI 工具包"
  end
end
