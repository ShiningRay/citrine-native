# frozen_string_literal: true

require_relative "test_helper"

# 文档表格对拍：仓库里的 Markdown 表格必须**每张表内字段数一致**。
#
# 为什么值得一条测试：本项目踩过两次"表格单元格里写了未转义的管道"——渲染出来是
# 多出一格、内容错位，靠人读很难发现（第一次是 `Static…milk`，第二次是文件清单）。
# 这两次都是先被脚本抓出来的。检查很便宜：连续的以 `|` 开头的行算作**一张表**
# （空行/标题/正文即收尾），同一张表内每行的**单元格数**必须相同；单元格里嵌管道
# 要用 GFM 的转义写法（反斜杠 + 管道），计数时会先把它换成占位符，所以转义不会误报。
#
# 代码块（``` 围栏）里的 `|` 不算表格——文档里会引用命令行或 ASCII 示意。
class DocTableTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # 覆盖面：主文档 + README + CHANGELOG + docs 下所有 Markdown（含子目录）
  def documents
    patterns = ["*.md", "docs/*.md", "docs/**/*.md"]
    patterns.flat_map { |pattern| Dir.glob(File.join(ROOT, pattern)) }.uniq.sort
  end

  def test_documents_exist
    assert_operator documents.size, :>=, 10, "没扫到文档，检查 glob"
    assert_includes documents, File.join(ROOT, "GOALS.md")
  end

  def test_tables_have_consistent_column_counts
    offenders = []

    documents.each do |path|
      table = [] # [行号, 单元格数]
      in_fence = false

      flush = lambda do
        next if table.empty?

        counts = table.map(&:last).uniq
        if counts.size > 1
          offenders << "#{relative(path)}:#{table.first.first} 同一张表内单元格数不一致 #{counts.sort.inspect}"
        end
        table.clear
      end

      File.readlines(path, chomp: true, encoding: "UTF-8").each_with_index do |line, index|
        if line.start_with?("```", "~~~")
          flush.call
          in_fence = !in_fence
          next
        end

        unless line.start_with?("|")
          flush.call # 非表格行（空行/标题/正文）= 表格结束——少这一句会把全文所有表当成一张
          next
        end

        next if in_fence

        table << [index + 1, cell_count(line)]
      end
      flush.call
    end

    assert_empty offenders, "文档表格结构问题：\n  #{offenders.join("\n  ")}"
  end

  # 单元格数：先把**转义过的**管道（反斜杠 + 管道，GFM 在表格里嵌入管道的正规写法）
  # 换成占位符，再剥掉行首/行尾那两个作为边界的裸管道。有些表格省略行尾的管道，
  # 那种写法字段数会差 1 但渲染出来是同一种表——不剥就会误报。
  def cell_count(line)
    cells = line.gsub("\\|", "\u0001").split("|", -1)
    cells.shift if cells.first == ""
    cells.pop if cells.last == ""
    cells.size
  end

  def relative(path) = path.delete_prefix("#{ROOT}/")
end
