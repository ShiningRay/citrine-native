# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/todo"

# N2 验收：Todo 示例（examples/todo.rb）在原生后端的完整可玩性——
# 输入 → 添加 → 勾选 → 删除，全部经真控件回调路径（桩后端记录的回调）驱动。
# 注意 check_box 没有内容位（同 DOM 的 <input type=checkbox>）：条目标签是相邻 label。
# 回车提交在 v0 不可用（libui 的 entry 不暴露按键事件，GOALS 第五节）——
# 这里覆盖的是按钮提交路径 + 受控输入的双向绑定。
class TodoExampleTest < NativeTest
  def test_add_toggle_and_remove_round_trip
    app = mount(TodoApp)
    entry = find(kind: :entry)
    add_button = find(kind: :button)
    assert_equal ["待办：剩余 0 / 共 0", "暂无待办，输入一条试试"], texts(kind: :label)

    type(entry, "买菜")
    click(add_button)
    type(entry, "写代码")
    click(add_button)

    assert_equal "待办：剩余 2 / 共 2", texts(kind: :label).first
    assert_equal %w[买菜 写代码], item_texts
    assert_equal "", entry.value, "提交后草稿要清空（受控：清 state 即清控件）"

    toggle(item_checkbox("买菜"))

    assert_equal "待办：剩余 1 / 共 2", texts(kind: :label).first

    # 删掉唯一未完成的那条 → 剩余归零，勾选状态留在 state 里
    click(delete_button_for("写代码"))

    assert_equal "待办：剩余 0 / 共 1", texts(kind: :label).first
    assert_equal ["买菜"], item_texts
    assert_equal [{ text: "买菜", done: true }], app.items
  end

  def test_blank_draft_is_not_added
    mount(TodoApp)
    entry = find(kind: :entry)

    type(entry, "   ")
    click(find(kind: :button))

    assert_equal ["待办：剩余 0 / 共 0", "暂无待办，输入一条试试"], texts(kind: :label)
  end

  def test_rows_are_reused_when_items_change
    app = mount(TodoApp)
    add_item("一条")
    add_item("两条")
    before = item_checkboxes

    app.remove_at(0)

    assert_same before.last, item_checkboxes.first, "删掉一行不该重建剩下的行（keyed 复用）"
  end

  private

  # 模拟用户输入：写控件值 + 触发原生变更回调
  def type(entry, text)
    entry.value = text
    entry.fire(:change)
  end

  def toggle(checkbox)
    checkbox.checked = !checkbox.checked
    checkbox.fire(:toggle)
  end

  def add_item(text)
    type(find(kind: :entry), text)
    click(find(kind: :button))
  end

  # 行 = 含 checkbox 的那个 row 容器；其余 label 都是整体文案
  def rows = find_all(kind: :box).select { |box| box.children.any? { |child| child.kind == :checkbox } }
  def item_checkboxes = rows.map { |row| row.children.find { |child| child.kind == :checkbox } }
  def item_texts = rows.map { |row| row.children.find { |child| child.kind == :label }.text }
  def item_checkbox(text) = rows.find { |row| row.children.any? { |child| child.text.to_s == text } }
                                     .children.find { |child| child.kind == :checkbox }
  def delete_button_for(text) = rows.find { |row| row.children.any? { |child| child.text.to_s == text } }
                                      .children.find { |child| child.kind == :button }
end
