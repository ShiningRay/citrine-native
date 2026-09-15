# frozen_string_literal: true

# N2 验收示例：Todo —— 受控文本输入（双向绑定）+ 勾选 + 增删。
#
#   bundle exec ruby examples/todo.rb
#
# 组件代码只用平台无关 API（同一份定义可搬到浏览器 DOM / Canvas / SSR）。
#
# v0 的两处原生差异（GOALS 第五节）：
# - libui 的 entry 不暴露按键事件 → **回车提交不可用**，改为「添加」按钮
#   （`on_enter:` 在原生后端会给出 dev_mode 提醒）
# - 原生 input 没有 placeholder → 用相邻 label 说明

begin
  require "citrine-native-libui"
rescue LoadError
  require_relative "../lib/citrine-native"
end

class TodoApp < Citrine::Component
  MIN_TEXT_LENGTH = 1

  state :items, default: [] # v1 集合语义：整体替换（就地改写要靠 set! 强制通知）
  state :draft, default: ""
  computed(:remaining) { items.count { |item| !item[:done] } }

  def view
    stack(gap: 10) do
      label { "待办：剩余 #{remaining} / 共 #{items.size}" }

      row(gap: 8) do
        # 受控输入：value 传 Signal，输入即写回 state（原生控件天然支持 IME）
        text_input(value: signal(:draft), style: { flex_grow: 1 })
        button(on_click: :add) { "添加" }
      end

      items.each_with_index do |item, index|
        # key 用条目对象身份：就地勾选不换对象 → 行与控件原地复用
        row(key: item.object_id, gap: 8) do
          # check_box 没有内容位（与 DOM 的 <input type=checkbox> 一致）：
          # 文本标签是相邻的 label
          check_box(checked: item[:done], on_change: ->(checked) { toggle(index, checked) })
          label { item[:text] }
          button(on_click: -> { remove_at(index) }) { "删除" }
        end
      end

      label { items.empty? ? "暂无待办，输入一条试试" : "勾选表示完成" }
    end
  end

  def add
    text = draft.strip
    return if text.length < MIN_TEXT_LENGTH

    self.items = items + [{ text: text, done: false }]
    self.draft = "" # 受控输入：清空 state 即清空控件里的文本
  end

  def toggle(index, checked)
    items[index][:done] = checked # 就地改写…
    signal(:items).set!(items)    # …配 set!：引用没变，普通 set 会被相等短路
  end

  def remove_at(index)
    self.items = items.each_with_index.reject { |_item, i| i == index }.map(&:first)
  end
end

# 直接 `ruby examples/todo.rb` 时起窗口；被测试 require 时只定义组件
Citrine::Native.run(TodoApp, title: "待办清单", width: 420, height: 380) if $PROGRAM_NAME == __FILE__
