# frozen_string_literal: true

# citrine-native（核心）任务入口：平台无关，CI 在无 GUI 的 ubuntu 上即可跑
require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs << "lib"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = false
end

desc "默认任务：渲染语义 + 样式矩阵单测（Memory 桩后端，不需要 GUI）"
task default: :test
