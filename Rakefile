# frozen_string_literal: true

require "rake/testtask"
require "bundler/gem_tasks" # rake build / rake install（N5 发布走 Trusted Publishing）

Rake::TestTask.new do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = false
  t.ruby_opts << "-rtest_helper" # 公共入口先于框架代码加载
end

desc "默认跑 CRuby 单测（桩后端，不需要窗口）"
task default: :test

desc "真控件冒烟：真窗口 + 真主循环（窗口会闪现一下；CI 无 GUI 时跳过）"
task :gui_smoke do
  sh "bundle exec ruby test/support/libui_scenario.rb --gui"
end
