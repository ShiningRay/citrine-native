# frozen_string_literal: true
$stdout.sync = true

# 两个 demo 的**真窗口端到端验收**（Windows）。
#
#   bundle exec ruby test/support/demo_acceptance.rb [sheets|market|all]
#
# 为什么要有这个脚本：N1/N2 的验收物（examples/）之外，真正被移植的是
# citrine-sheets 与 citrine-market-terminal 两个真实应用。它们的"可玩"必须
# 在**真窗口 + 真鼠标**上验，而不是靠桩后端——但 2026-09-15 那次验收是手工做的
# （读控件标题 + 手点），无法复跑。本脚本把那套动作固定下来：
#
#   拉起 demo（子进程，独立 log）→ 轮询真窗口 → 枚举子控件读**标题**（GetWindowTextW）
#   → 真的把鼠标移过去点（SetCursorPos + mouse_event）→ 再读标题断言状态变化
#   → 发 WM_CLOSE 关窗，断言进程自己退出（退出路径也是被测对象）
#
# **点击两条路径**：优先真鼠标（先确认窗口真在前台：GetForegroundWindow + BringWindowToTop +
# AttachThreadInput，再校验光标到位）；拿不到前台时回退到**消息级点击**（把 WM_LBUTTONDOWN/UP
# 投给控件本身），并打印 info 标注——桌面是共享的，用户在机器前时前台常常拿不到。
# 两条路都会走到 libui 的回调，但只有真鼠标经过命中测试与焦点，所以哪条被用了要说清楚。
#
# 断言都建立在"**应用自己的原生控件标题**"上（label/button 的 caption）：
# sheets 的 `A1 · 60 行 × 26 列` / `位置 D15`，market 的 `上午盘 11:09 · 第 99 档`
# / `⏸ 暂停`↔`▶ 继续` / `4x ✓` / `第 1/2 页 · 共 6 只`。这比像素采样硬：改没改、
# 改成什么，都是应用写的字。
#
# **验不到的部分（如实声明）**：合成键盘不认——SendMessage(WM_KEYDOWN) 直投
# area 句柄、以及 AttachThreadInput + SetFocus 之后再投，两条路都被证否
# （libui 的 area 键事件不认合成消息）。所以键盘路径仍需人手点一遍，见
# docs/plan/acceptance-0.1.0.md 第三节。本脚本只覆盖鼠标 + 标题回读。
#
# 非 Windows、或同级目录里没有那两个仓库时，输出 SKIP 并以 0 退出（不算失败）。
#
# 用法提示：需要**装了 libui 的那个 ruby**（子进程用 RbConfig.ruby，即本进程的解释器）；
# 窗口会真的弹出来并闪动，运行时不要抢鼠标。

require "fiddle"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("../..", __dir__) # citrine-native 仓库根
PARENT = File.expand_path("..", ROOT)     # 三个仓库的共同父目录

# ---------------------------------------------------------------- Win32 绑定

module Win
  USER32 = Fiddle.dlopen("user32.dll")
  KERNEL32 = Fiddle.dlopen("kernel32.dll")

  def self.api(name, args, ret)
    Fiddle::Function.new(USER32[name], args, ret)
  end

  def self.kernel_api(name, args, ret)
    Fiddle::Function.new(KERNEL32[name], args, ret)
  end

  ENUM_WINDOWS = api("EnumWindows", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG], Fiddle::TYPE_INT)
  ENUM_CHILD = api("EnumChildWindows", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG],
                   Fiddle::TYPE_INT)
  WINDOW_PID = api("GetWindowThreadProcessId", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG)
  CLASS_NAME = api("GetClassNameW", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
  WINDOW_TEXT = api("GetWindowTextW", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
  WINDOW_RECT = api("GetWindowRect", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  POST_MESSAGE = api("PostMessageW", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_LONG_LONG,
                                      Fiddle::TYPE_LONG_LONG], Fiddle::TYPE_INT)
  SET_WINDOW_TEXT = api("SetWindowTextW", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  SEND_MESSAGE = api("SendMessageW", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_LONG_LONG,
                                      Fiddle::TYPE_LONG_LONG], Fiddle::TYPE_LONG_LONG)
  IS_WINDOW_VISIBLE = api("IsWindowVisible", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  GET_CURSOR_POS = api("GetCursorPos", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  GET_FOREGROUND_WINDOW = api("GetForegroundWindow", [], Fiddle::TYPE_VOIDP)
  BRING_WINDOW_TO_TOP = api("BringWindowToTop", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  ATTACH_THREAD_INPUT = api("AttachThreadInput", [Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_INT],
                            Fiddle::TYPE_INT)
  SCREEN_TO_CLIENT = api("ScreenToClient", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  CURRENT_THREAD_ID = kernel_api("GetCurrentThreadId", [], Fiddle::TYPE_LONG)
  SET_FOREGROUND = api("SetForegroundWindow", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  SET_CURSOR = api("SetCursorPos", [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
  MOUSE_EVENT = api("mouse_event", [Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG,
                                    Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)

  WM_CLOSE = 0x0010
  WM_CHAR = 0x0102 # 逐字符打字：Edit 会当作真实输入处理（并触发 EN_CHANGE）
  WM_LBUTTONDOWN = 0x0201
  WM_LBUTTONUP = 0x0202
  BM_CLICK = 0x00F5 # 复选框/按钮：走真控件自己的点击语义（会比直接改状态更接近用户动作）
  MOUSEEVENTF_LEFTDOWN = 0x0002
  MOUSEEVENTF_LEFTUP = 0x0004
  ENUM_CONTINUE = 1

  # 跨进程只能读窗口"标题"（Edit 的内容不是标题，恒空——踩过一次，见验收文档）。
  # 这里用到的都是 label/button 的 caption，恰好是标题，所以读得到。
  def self.text(handle, size = 512)
    buffer = Fiddle::Pointer.malloc(size * 2)
    buffer[0, size * 2] = "\0" * (size * 2)
    length = WINDOW_TEXT.call(handle, buffer, size)
    return "" if length <= 0

    buffer[0, length * 2].force_encoding("UTF-16LE").encode("UTF-8")
  end

  def self.class_name(handle, size = 256)
    buffer = Fiddle::Pointer.malloc(size * 2)
    buffer[0, size * 2] = "\0" * (size * 2)
    length = CLASS_NAME.call(handle, buffer, size)
    return "" if length <= 0

    buffer[0, length * 2].force_encoding("UTF-16LE").encode("UTF-8")
  end

  def self.rect(handle)
    pointer = Fiddle::Pointer.malloc(16)
    return nil if WINDOW_RECT.call(handle, pointer).zero?

    pointer[0, 16].unpack("l4")
  end

  def self.pid_of(handle)
    buffer = Fiddle::Pointer.malloc(4)
    WINDOW_PID.call(handle, buffer)
    buffer[0, 4].unpack1("L")
  end

  # 顶层窗口：EnumWindows 回调返回 1 继续枚举（返回 0 会中断枚举）
  def self.top_windows(pid)
    found = []
    callback = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_INT, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG]) do |handle, _|
      found << handle.to_i if pid_of(handle) == pid
      ENUM_CONTINUE
    end
    ENUM_WINDOWS.call(callback, 0)
    found
  end

  # 应用真正露出来的窗口：libui 还会建一个隐藏的辅助窗口
  # （标题 "libui utility window"，用于文本度量等），按 pid 取第一个会取错它——
  # 实测踩过：窗口标题断言读到辅助窗口、WM_CLOSE 也因此没送到主窗口。
  def self.visible_windows(pid)
    top_windows(pid).select { |handle| IS_WINDOW_VISIBLE.call(handle) != 0 && !text(handle).empty? }
  end

  # 子控件：EnumChildWindows 枚举**所有后代**（含嵌套容器里的）
  def self.children(handle)
    found = []
    callback = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_INT, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG]) do |child, _|
      found << child.to_i
      ENUM_CONTINUE
    end
    ENUM_CHILD.call(handle, callback, 0)
    found
  end

  # 控件清单：`Static|计数：3|72,50,161,67` 这种一行一条（与手工探针的输出同格式）
  #
  # 注意：树里会出现**不属于应用**的窗口——本机的输入法会往我们的窗口下挂
  # `Sogou_TSF_UI` / `Default IME`（rect 全 0）。断言都按类名或标题精确匹配，不受影响；
  # 打印时过滤掉空标题即可。
  def self.controls(pid)
    top_windows(pid).flat_map do |window|
      [window] + children(window)
    end.map do |handle|
      klass = class_name(handle)
      next if klass.empty?

      { handle: handle, class: klass, text: text(handle), rect: rect(handle) }
    end.compact
  end

  # 真鼠标点击（与手工探针同一套动作）：先激活窗口，再移动光标、按下、抬起
  # 把窗口带到前台。**必须先确认它真的在前台**：`SetForegroundWindow` 会被系统拦下
  # （调用方不是前台进程时），此时"坐标对了"的点击会落到别的窗口上——实测踩过两次：
  # 点「⏸ 暂停」与点「B 加粗」都出现过"控件纹丝不动"。
  #
  # 单纯 SetForegroundWindow 不够（会被拒），要**把本线程的输入队列挂到目标窗口的
  # 线程上**（AttachThreadInput）再置前——这是 Windows 上唯一稳定的做法，
  # 早先的 PowerShell 探针也是靠它才拿到焦点的。
  def self.focus(window)
    BRING_WINDOW_TO_TOP.call(window)
    SET_FOREGROUND.call(window)
    return true if foreground?(window)

    app_thread = WINDOW_PID.call(window, Fiddle::Pointer.malloc(4)) # 返回值就是线程 id
    my_thread = CURRENT_THREAD_ID.call
    return false if app_thread.zero? || my_thread == app_thread

    ATTACH_THREAD_INPUT.call(my_thread, app_thread, 1)
    begin
      5.times do
        BRING_WINDOW_TO_TOP.call(window)
        SET_FOREGROUND.call(window)
        return true if foreground?(window)

        sleep 0.2
      end
      false
    ensure
      ATTACH_THREAD_INPUT.call(my_thread, app_thread, 0)
    end
  end

  def self.foreground?(window) = GET_FOREGROUND_WINDOW.call.to_i == window.to_i

  # 消息级点击（**回退路径**）：把 WM_LBUTTONDOWN/UP 直接投给控件的客户区坐标，
  # 不需要窗口在前台。为什么需要它：桌面是共享的——用户正在用这台机器时，
  # `SetForegroundWindow`（即使挂了 AttachThreadInput）也会被系统拒掉，真鼠标点击
  # 就会落到别人的窗口上（实测踩过两次）。这条路径走的是控件自己的消息处理
  # （仍经 libui 回调），但不经过命中测试与焦点——**调用方必须如实标注用了哪条**。
  def self.click_message(handle, screen_x, screen_y)
    point = Fiddle::Pointer.malloc(8)
    point[0, 8] = [screen_x, screen_y].pack("l2")
    return false if SCREEN_TO_CLIENT.call(handle, point).zero?

    client_x, client_y = point[0, 8].unpack("l2")
    return false if client_x.negative? || client_y.negative?

    lparam = ((client_y & 0xFFFF) << 16) | (client_x & 0xFFFF)
    POST_MESSAGE.call(handle, WM_LBUTTONDOWN, 1, lparam)
    POST_MESSAGE.call(handle, WM_LBUTTONUP, 0, lparam)
    sleep 0.15
    true
  end

  def self.click(window, x, y)
    return false unless focus(window)

    sleep 0.15
    2.times do # 光标没到位就再挪一次
      SET_CURSOR.call(x, y)
      sleep 0.15
      cursor = cursor_pos
      if (cursor[0] - x).abs <= 2 && (cursor[1] - y).abs <= 2
        MOUSE_EVENT.call(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
        MOUSE_EVENT.call(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
        sleep 0.2
        return true
      end
    end
    false
  end

  def self.cursor_pos
    buffer = Fiddle::Pointer.malloc(8)
    GET_CURSOR_POS.call(buffer)
    buffer[0, 8].unpack("l2")
  end

  def self.close(window)
    POST_MESSAGE.call(window, WM_CLOSE, 0, 0)
  end

  def self.click_control(handle)
    POST_MESSAGE.call(handle, BM_CLICK, 0, 0)
  end

  # 给 Edit 写文本：**会触发 EN_CHANGE**（真控件自己的通知），所以 libui 的 on_change
  # → 应用的受控 state 这条链路是真的被走到，而不是"直接改 state"。
  def self.set_text(handle, string)
    wide = string.encode("UTF-16LE").b + "\0\0".b # 两段都是 BINARY，避免 UTF-16LE 与 ASCII-8BIT 拼接报错
    buffer = Fiddle::Pointer[wide]
    SET_WINDOW_TEXT.call(handle, buffer)
  end

  # 打字：逐字符 WM_CHAR 直接投给 Edit——这是**用户敲键盘**走的同一条路，
  # 会真的产生 EN_CHANGE（实测：SetWindowTextW 只改控件内容，应用侧的
  # on_change 不来，`add` 见空 draft 早退 → 计数停在 0/0，见验收文档第三节）。
  def self.type_text(handle, string)
    string.encode("UTF-16LE").unpack("v*").each do |code_unit|
      SEND_MESSAGE.call(handle, WM_CHAR, code_unit, 0)
      sleep 0.03
    end
  end
end

# ---------------------------------------------------------------- 断言与输出

module Report
  class << self
    attr_accessor :failures

    def check(name, actual, expected)
      if actual == expected
        puts "ok   #{name}"
      else
        puts "FAIL #{name}\n       期望 #{expected.inspect}\n       实际 #{actual.inspect}"
        @failures += 1
      end
    end

    def check_match(name, actual, pattern)
      if actual.is_a?(String) && actual.match?(pattern)
        puts "ok   #{name}（#{actual}）"
      else
        puts "FAIL #{name}\n       期望匹配 #{pattern.inspect}\n       实际 #{actual.inspect}"
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

    # 失败时把当场读到的控件清单打出来——这是定位的唯一证据来源
    def dump(pid, title)
      puts "--- 现场控件清单（#{title}）---"
      Win.controls(pid).each do |control|
        next if control[:rect].nil? || control[:text].to_s.empty?

        puts "    #{control[:class]}|#{control[:text]}|#{control[:rect].join(',')}"
      end
    end

    # 轮询到条件成立或超时：点击/启动后的 UI 更新是异步的，直接读会假阴
    def wait_until(timeout: 6, interval: 0.2)
      deadline = Time.now + timeout
      loop do
        value = yield
        return value if value
        return nil if Time.now > deadline

        sleep interval
      end
    end
  end
end
Report.failures = 0

# ---------------------------------------------------------------- demo 运行器

class Demo
  attr_reader :name, :dir, :pid, :log

  # script：相对 dir 的入口；bundle=true 时经 `bundle exec` 拉起（本仓 examples 用
  # citrine 的 path 依赖，必须走 Gemfile；两个 demo 的 bin/native 自己引导 $LOAD_PATH，
  # 反而不能带入本仓的 bundler 上下文）
  def initialize(name, dir, script: "bin/native", bundle: false)
    @name = name
    @dir = dir
    @script = script
    @bundle = bundle
    @log = File.join(Dir.tmpdir, "citrine-#{name}-acceptance.log")
  end

  def exist? = File.file?(File.join(@dir, @script))

  def start!
    File.delete(@log) if File.exist?(@log)
    if @bundle
      # **不要**写成 `ruby -S bundle exec ruby …`：那样会多出一层 ruby 进程，
      # 窗口属于孙进程，按 pid 找窗口/关窗/判退出全部落空（实测踩过）。
      # 在子进程内加载 bundler（RUBYOPT）即可，保持"一个 spawn = 一个应用进程"。
      env = { "BUNDLE_GEMFILE" => File.join(@dir, "Gemfile"), "RUBYOPT" => "-rbundler/setup" }
      @pid = Process.spawn(env, RbConfig.ruby, @script, chdir: @dir, out: @log, err: @log)
    else
      env = {
        "CITRINE_ROOT" => File.join(PARENT, "citrine"),
        "CITRINE_NATIVE_ROOT" => ROOT,
        "RUBYOPT" => nil,
        "BUNDLE_GEMFILE" => nil,
        "BUNDLE_PATH" => nil
      }
      @pid = Process.spawn(env, RbConfig.ruby, @script, chdir: @dir, out: @log, err: @log)
    end
  end

  # 主窗口：只认**可见且有标题**的顶层窗口；给了 title 就等到标题对上为止
  def window(title: nil, timeout: 25)
    @window = Report.wait_until(timeout: timeout, interval: 0.3) do
      candidates = Win.visible_windows(@pid)
      next nil if candidates.empty?

      (title && candidates.find { |handle| Win.text(handle) == title }) || candidates.first
    end
    # 给了 title 但一直没等到：仍然把当前候选交出去，由调用方的标题断言如实报失败
    @window ||= Win.visible_windows(@pid).first
  end

  def window_title = @window ? Win.text(@window) : nil

  def controls
    @last_controls = Win.controls(@pid)
  end

  # 失败时打印"最后读到的"控件清单：进程可能已经退出，那时再枚举就是空的
  def dump_last(title)
    list = @last_controls || []
    puts "--- 现场控件清单（#{title}，共 #{list.size} 个）---"
    list.each do |control|
      next if control[:rect].nil? || control[:text].to_s.empty?

      puts "    #{control[:class]}|#{control[:text]}|#{control[:rect].join(',')}"
    end
  end

  def text_matching(pattern)
    control = controls.find { |c| c[:text].to_s.match?(pattern) }
    control && control[:text]
  end

  def control_matching(pattern)
    controls.find { |c| c[:text].to_s.match?(pattern) }
  end

  def click_control(pattern, allow_message_fallback: true)
    control = Report.wait_until(timeout: 4) { control_matching(pattern) }
    raise "找不到要点的控件：#{pattern.inspect}（当前：#{controls.map { |c| c[:text] }.reject(&:empty?).join(' / ')}）" unless control

    rect = control[:rect]
    center = [(rect[0] + rect[2]) / 2, (rect[1] + rect[3]) / 2]
    placed = 2.times.any? { Win.click(@window || Win.top_windows(@pid).first || 0, *center) }

    if !placed && allow_message_fallback
      # 拿不到前台（用户正在用桌面时常见）→ 回退到消息级点击，并**如实标注**。
      # 重读一次控件：两次尝试之间行/控件可能已被重建，旧句柄会失效。
      fresh = control_matching(pattern) || control
      if Win.click_message(fresh[:handle], *center)
        puts "info 拿不到前台焦点：#{pattern.inspect} 改用消息级点击（WM_LBUTTONDOWN/UP）"
        placed = true
      end
    end
    raise "点击没能送达 #{pattern.inspect}（真点击与消息级回退都失败）" unless placed

    control
  end

  def click_at(x, y, handle: nil)
    placed = Win.click(@window || Win.top_windows(@pid).first || 0, x, y)
    if !placed && handle
      if Win.click_message(handle, x, y)
        puts "info 拿不到前台焦点：坐标点击 (#{x}, #{y}) 改用消息级点击"
        placed = true
      end
    end
    puts "info 点击坐标 (#{x}, #{y}) 没能送达（真点击与消息级回退都失败）" unless placed
    placed
  end

  # 点一个控件、等到期望的状态出现；没出现就再来一次（真点击在桌面上偶发丢失：
  # 实测第 5 轮出现过一次"点了删除但行还在"——现场清单证明控件没动过，属丢失而非缺陷）。
  # 重试会打印 info，不掩盖；两次都不动才算失败。期望状态用 block 表达（可以是"不等于原来"）。
  def click_until(pattern, attempts: 3, timeout: 6)
    attempts.times do |attempt|
      begin
        return false unless click_control(pattern)
      rescue RuntimeError => e
        # 放置失败是瞬时的（窗口没拿到前台、控件刚被重建导致句柄失效、光标没到位…）：
        # 交给这里的重试接手，不要让整段验收中断——实测踩过（todo 的「删除」一次没送达）。
        puts "info 第 #{attempt + 1} 次尝试没能送达 #{pattern.inspect}：#{e.message}"
        next
      end

      hit = Report.wait_until(timeout: timeout) { yield }
      return hit if hit

      if attempt < attempts - 1
        puts "info 点击 #{pattern.inspect} 后 #{timeout}s 内没等到期望状态（第 #{attempt + 1} 次尝试，重试）"
      end
    end
    nil
  end

  # 关窗 → 等它自己走完退出路径（MARKET-1d 的"先退出主循环再拆解"）
  def stop(timeout: 8)
    Win.close(@window) if @window
    deadline = Time.now + timeout
    while Time.now < deadline
      reaped = Process.waitpid(@pid, Process::WNOHANG)
      return true if reaped
      sleep 0.2
    end
    Process.kill("KILL", @pid) # 关窗没退出 = 如实记为失败，强杀以免留下窗口
    Process.waitpid(@pid, Process::WNOHANG)
    false
  end

  def log_text
    File.exist?(@log) ? File.read(@log, encoding: "UTF-8") : ""
  end
end

# ---------------------------------------------------------------- 本仓两个验收示例（N1/N2）

# N1 验收口径（对齐主仓 M0 Spike A）：真窗口里点击按钮，计数**精确 +1**
def accept_counter
  demo = Demo.new("counter", ROOT, script: "examples/counter.rb", bundle: true)
  puts "\n== examples/counter.rb（N1 验收物）=="
  demo.start!
  unless demo.window(title: "计数器")
    Report.check("窗口出现", false, true)
    return demo.stop
  end
  Report.check("窗口出现", true, true)
  Report.check("窗口标题", demo.window_title, "计数器")
  Report.check("初始计数", Report.wait_until(timeout: 10) { demo.text_matching(/\A计数：\d+\z/) }, "计数：0")

  3.times { demo.click_control(/\A点我 \+1\z/) }
  Report.check("真点 3 次后计数精确为 3", Report.wait_until(timeout: 6) { demo.text_matching(/\A计数：3\z/) }, "计数：3")

  Report.check("WM_CLOSE 后进程自行退出", demo.stop, true)
  Report.check("log 为空（无异常输出）", demo.log_text, "")
  demo.dump_last("counter") if Report.failures.positive?
rescue StandardError => e
  puts "FAIL counter 验收异常：#{e.class}: #{e.message}"
  Report.failures += 1
  demo&.stop
end

# N2 验收口径：增删 + 勾选都可玩；受控输入的写回链路（Edit 的 EN_CHANGE → state）
# 必须真的走通——证据是"不写回就加不进去"（`add` 对空 draft 早退），所以断言计数与行文本。
def accept_todo
  demo = Demo.new("todo", ROOT, script: "examples/todo.rb", bundle: true)
  puts "\n== examples/todo.rb（N2 验收物）=="
  demo.start!
  unless demo.window(title: "待办清单")
    Report.check("窗口出现", false, true)
    return demo.stop
  end
  Report.check("窗口出现", true, true)
  Report.check("窗口标题", demo.window_title, "待办清单")
  Report.check("初始计数", Report.wait_until(timeout: 10) { demo.text_matching(/\A待办：剩余 \d+ \/ 共 \d+\z/) },
               "待办：剩余 0 / 共 0")
  Report.check_match("空态提示", demo.text_matching(/暂无待办/), /暂无待办/)

  edit = Report.wait_until(timeout: 6) { demo.controls.find { |c| c[:class] == "Edit" } }
  unless edit
    Report.check("输入框是真 Edit 控件", false, true)
    demo.dump_last("todo")
    return demo.stop
  end
  Report.check("输入框是真 Edit 控件", true, true)

  Win.type_text(edit[:handle], "milk") # 逐字符 WM_CHAR：EN_CHANGE → on_change → draft（真输入链路）
  sleep 0.6
  Report.check("添加后计数", demo.click_until(/\A添加\z/) { demo.text_matching(/\A待办：剩余 1 \/ 共 1\z/) },
               "待办：剩余 1 / 共 1")
  Report.check_match("行文本（draft 真的写回了 state 才会加得进去）", demo.text_matching(/\Amilk\z/), /\Amilk\z/)
  Report.check_match("行内删除按钮", demo.text_matching(/\A删除\z/), /\A删除\z/)

  # 复选框在 Windows 上就是无标题的 BUTTON；用 BM_CLICK 走它自己的点击语义
  checkbox = demo.controls.find { |c| c[:class].start_with?("Button") && c[:text].to_s.empty? }
  if checkbox
    Win.click_control(checkbox[:handle])
    Report.check("勾选后剩余数归零", Report.wait_until(timeout: 6) { demo.text_matching(/\A待办：剩余 0 \/ 共 1\z/) },
                 "待办：剩余 0 / 共 1")
  else
    Report.check("找到复选框（无标题的 Button）", false, true)
  end

  Report.check("删除后回到空态", demo.click_until(/\A删除\z/) { demo.text_matching(/\A待办：剩余 0 \/ 共 0\z/) },
               "待办：剩余 0 / 共 0")
  Report.check_match("空态提示回来了", demo.text_matching(/暂无待办/), /暂无待办/)

  Report.check("WM_CLOSE 后进程自行退出", demo.stop, true)
  Report.check("log 为空（无异常输出）", demo.log_text, "")
  demo.dump_last("todo") if Report.failures.positive?
rescue StandardError => e
  puts "FAIL todo 验收异常：#{e.class}: #{e.message}"
  Report.failures += 1
  demo&.stop
end

# ---------------------------------------------------------------- 两个 demo 的验收

def accept_sheets
  demo = Demo.new("sheets", File.join(PARENT, "citrine-sheets"))
  return Report.skip("citrine-sheets", "同级目录没有该仓库") unless demo.exist?

  puts "\n== citrine-sheets（dev_mode 开：任何断链都会打到 log）=="
  demo.start!
  window = demo.window
  unless window
    Report.check("窗口出现", false, true)
    Report.dump(demo.pid, "sheets")
    return demo.stop
  end
  Report.check("窗口出现", true, true)

  # 网格表头 `A1 · 60 行 × 26 列`：位置在应用状态改变时会跟着变，是最好的观测点
  # （子控件是逐步建起来的，任何断言都要轮询——实测"表头已出现、位置标签还差一拍"。）
  header = Report.wait_until(timeout: 8) { demo.text_matching(/\A[A-Z]+\d+ · \d+ 行 × \d+ 列\z/) }
  Report.check_match("网格表头（选格观测点）", header, /\A[A-Z]+\d+ · \d+ 行 × \d+ 列\z/)
  position = Report.wait_until(timeout: 8) { demo.text_matching(/\A位置 [A-Z]+\d+\z/) }
  Report.check_match("公式栏位置标签", position, /\A位置 [A-Z]+\d+\z/)

  area = Report.wait_until(timeout: 8) { demo.controls.find { |c| c[:class] == "libui_uiAreaClass" } }
  unless area && area[:rect]
    Report.check("网格是自绘面板（libui_uiAreaClass）", false, true)
    demo.dump_last("sheets")
    return demo.stop
  end
  Report.check("网格是自绘面板（libui_uiAreaClass）", true, true)

  hint_before = demo.text_matching(/点一下网格即可用键盘/)
  # 启动提示在不在，取决于窗口起来时有没有拿到焦点（从有焦点的控制台拉起就会直接拿到）
  # ——只记录不断言，避免把环境差异当成应用缺陷。
  puts "info 启动提示（起窗时）：#{hint_before ? '在' : '不在（窗口起窗即拿到焦点）'}"

  left, top, right, bottom = area[:rect]
  width = right - left
  height = bottom - top

  # 网格左侧有行号栏、上方有列标栏——点太靠角会落在 gutter 上（实测 (left+6, top+6)
  # 不改选区），所以断言不能钉死在"左上角 = A1"，只能断言**方向性**（自校准，无魔数）：
  # 越靠右下点的格，行列号不能更小。
  # 点击必须**真的改变选区**——只断言"标签形状对"会被点击前的旧值骗过（实测踩过：
  # 点击丢了、位置标签还写着 A1，形状断言照样通过）。
  selection = -> { demo.text_matching(/\A位置 ([A-Z]+\d+)\z/) }
  before = Report.wait_until(timeout: 5) { selection.call }
  demo.click_at(left + (width * 0.35), top + (height * 0.35), handle: area[:handle])
  cell_a = Report.wait_until(timeout: 5) { now = selection.call; now if now && now != before }
  Report.check_true("点网格中偏左上处**改变了选区**（#{before} → #{cell_a}）", !cell_a.nil?, cell_a.to_s)

  demo.click_at(left + (width * 0.75), top + (height * 0.75), handle: area[:handle])
  cell_b = Report.wait_until(timeout: 5) { now = selection.call; now if now && now != cell_a }
  Report.check_true("点网格中偏右下处**又改变了一次**（#{cell_a} → #{cell_b}）", !cell_b.nil?, cell_b.to_s)

  cell_index = lambda do |label|
    name = label.to_s.split(" ").last
    column = name[/\A[A-Z]+/].to_s.each_char.reduce(0) { |acc, ch| (acc * 26) + (ch.ord - 64) }
    [column, name[/\d+\z/].to_i]
  end
  from, to = cell_index.call(cell_a), cell_index.call(cell_b)
  Report.check("越往右下点，列号不更小（#{cell_a} → #{cell_b}）", to[0] >= from[0], true)
  Report.check("越往右下点，行号不更小（#{cell_a} → #{cell_b}）", to[1] >= from[1], true)
  Report.check("两次点击落在不同的格子上（点击真的改变了选区）", cell_a != cell_b, true)

  # ⑥ 应用逻辑（**鼠标可达的部分**）：工具栏按钮驱动格式化 → 撤销 → 重做 → 重算全部。
  #    为什么从这里入手：sheets 的"编辑单元格"走 area 侧的按键（libui 的 entry 收不到键，
  #    设计文档 2.3），而合成键盘投递不到 area（见验收文档第三节）——所以单元格编辑
  #    本机验不了；但工具栏是纯鼠标，且应用把结果写在**状态标签**上：
  #      `已设置格式 E20（撤销 1 / 重做 0）` → `已撤销（撤销 0 / 重做 1）` → `已重做（撤销 1 / 重做 0）`
  #      `上次重算 已重算全部公式：重算 131 格 · 显示变化 0 格 · 3 ms`
  Report.check_match("点「B 加粗」后状态显示格式化并进入撤销栈",
                     demo.click_until(/\AB 加粗\z/) { demo.text_matching(/\A已设置格式 [A-Z]+\d+（撤销 1 \/ 重做 0）\z/) },
                     /\A已设置格式 [A-Z]+\d+（撤销 1 \/ 重做 0）\z/)
  Report.check_match("点「↶ 撤销」后可重做",
                     demo.click_until(/\A↶ 撤销\z/) { demo.text_matching(/\A已撤销（撤销 0 \/ 重做 1）\z/) },
                     /\A已撤销（撤销 0 \/ 重做 1）\z/)
  Report.check_match("点「↷ 重做」后回到已格式化",
                     demo.click_until(/\A↷ 重做\z/) { demo.text_matching(/\A已重做（撤销 1 \/ 重做 0）\z/) },
                     /\A已重做（撤销 1 \/ 重做 0）\z/)

  recalc = demo.click_until(/\A重算全部\z/) { demo.text_matching(/\A上次重算 已重算全部公式：重算 \d+ 格/) }
  Report.check_match("点「重算全部」后报告重算格数", recalc, /\A上次重算 已重算全部公式：重算 \d+ 格/)
  Report.check_true("重算格数 > 0（真的算了东西）",
                    recalc.to_s[/重算 (\d+) 格/, 1].to_i.positive?,
                    recalc.to_s[/重算 (\d+) 格/, 1].to_s)

  # 表头（选格观测点）与位置标签必须自洽：都是同一个单元格
  label = demo.text_matching(/\A位置 ([A-Z]+\d+)\z/)
  header_now = demo.text_matching(/\A([A-Z]+\d+) · \d+ 行 × \d+ 列\z/)
  Report.check("表头与位置标签指向同一个单元格", header_now.to_s.split(" ").first, label.to_s.split(" ").last)

  # 点击后应用进入键盘模式 → 启动提示消失
  hint_after = demo.text_matching(/点一下网格即可用键盘/)
  Report.check("点击后启动提示消失（已拿到焦点）", hint_after.nil?, true)

  # ⑤ 关闭时进程要自己退出（先退出主循环、再拆解），而不是被强杀
  exited = demo.stop
  Report.check("WM_CLOSE 后进程自行退出", exited, true)
  log = demo.log_text
  Report.check("log 为空（dev_mode 下没有断链提醒、无异常输出）", log, "")
  demo.dump_last("sheets") if Report.failures.positive?
rescue StandardError => e
  puts "FAIL citrine-sheets 验收异常：#{e.class}: #{e.message}"
  Report.failures += 1
  demo&.stop
end

def accept_market
  demo = Demo.new("market", File.join(PARENT, "citrine-market-terminal"))
  return Report.skip("citrine-market-terminal", "同级目录没有该仓库") unless demo.exist?

  puts "\n== citrine-market-terminal =="
  demo.start!
  window = demo.window
  unless window
    Report.check("窗口出现", false, true)
    Report.dump(demo.pid, "market")
    return demo.stop
  end
  Report.check("窗口出现", true, true)

  # 头部账目标签：数值会随仿真变化，所以只断言"形状"
  Report.check_match("总资产标签", Report.wait_until(timeout: 8) { demo.text_matching(/\A总资产 [\d,]+\.\d\d\z/) },
                     /\A总资产 [\d,]+\.\d\d\z/)
  Report.check_match("浮动盈亏标签", Report.wait_until(timeout: 8) { demo.text_matching(/\A浮动盈亏 [-+]?[\d,]+\.\d\d\z/) },
                     /\A浮动盈亏 [-+]?[\d,]+\.\d\d\z/)
  ledger = demo.text_matching(/\A上午盘 \d\d:\d\d · 第 \d+ 档\z/)
  Report.check_match("走时标签", ledger, /\A上午盘 \d\d:\d\d · 第 \d+ 档\z/)

  # ① 行情真的在推进：同一标签隔几秒读两次，档位必须变大
  step_before = ledger.to_s[/第 (\d+) 档/, 1].to_i
  sleep 3
  step_after = demo.text_matching(/\A上午盘 \d\d:\d\d · 第 \d+ 档\z/).to_s[/第 (\d+) 档/, 1].to_i
  Report.check("行情档位在推进（3 秒后更大）", step_after > step_before, true)

  # ② 暂停 ↔ 继续：真点按钮，标题必须翻转
  Report.check("点暂停后按钮变「▶ 继续」",
               demo.click_until(/\A⏸ 暂停\z|\A▶ 继续\z/) { demo.text_matching(/\A▶ 继续\z/) }, "▶ 继续")
  Report.check("再点一次回到「⏸ 暂停」",
               demo.click_until(/\A▶ 继续\z/) { demo.text_matching(/\A⏸ 暂停\z/) }, "⏸ 暂停")

  # ③ 变速按钮：点 4x → 该按钮带上 ✓
  Report.check("点 4x 后标题为「4x ✓」",
               demo.click_until(/\A4x\z|\A4x ✓\z/) { demo.text_matching(/\A4x ✓\z/) }, "4x ✓")

  # ④ 手动下单（确定性路径，不用等自动交易、**必须在自动交易开关之前跑**——
  #    实测顺序反了会失败：开关早打开的话，等手动下单时资金已被自动交易花掉，
  #    「全部」填出来的数量不足 100 股，应用如实报 `数量无效`，成交断言当然不成立）。
  #    点「全部」→ 数量填到最大可买 → 点「提交买入」→ 成交，价格与手续费都在可读标签上。
  #    实测口径：`最大可买 700 股`、`委托结果：成交：买入 700 股 @ 1,372.17（手续费 240.13）`。
  Report.check_match("点「全部」后给出最大可买股数",
                     demo.click_until(/\A全部\z/) { demo.text_matching(/最大可买 \d+ 股/) },
                     /最大可买 \d+ 股/)
  max_buy = demo.text_matching(/最大可买 (\d+) 股/).to_s[/最大可买 (\d+) 股/, 1].to_i
  Report.check_true("最大可买 > 0（点「全部」真的按可用资金算出了数量）", max_buy.positive?, max_buy.to_s)

  filled = demo.click_until(/\A提交买入 /) do
    # 价格带千分位（`@ 1,374.26`）——第一次写 `[\d.]+` 所以永远匹配不上，实测踩到
    demo.text_matching(/\A委托结果：成交：买入 \d+ 股 @ [\d,]+\.\d\d（手续费 [\d,]+\.\d\d）\z/)
  end
  Report.check_match("点「提交买入」后成交并报告价格与手续费", filled,
                     /\A委托结果：成交：买入 \d+ 股 @ [\d,]+\.\d\d（手续费 [\d,]+\.\d\d）\z/)
  Report.check_match("提示标签与委托结果一致", demo.text_matching(/\A提示：成交：买入 \d+ 股 @ [\d,]+\.\d\d/),
                     /\A提示：成交：买入 \d+ 股 @ [\d,]+\.\d\d/)

  held_after_manual = demo.text_matching(/\A第 \d+\/\d+ 页 · 共 (\d+) 只\z/)
  manual_count = held_after_manual.to_s[/共 (\d+) 只/, 1].to_i
  Report.check_true("手动下单后持仓里出现了这一只", manual_count.positive?, "共 #{manual_count} 只")

  # ⑤ 校验路径（同样确定性）：资金已经投进去了，再点一次「全部」+「提交买入」必然
  #    填不出合法数量 → 应用要**如实报出原因**（实测：`数量无效：请输入 100 的整数倍…`）。
  #    这条断言的价值在于"错误路径也可读、且不是静默失败"。
  demo.click_until(/\A全部\z/) { true } # 「全部」本身不改可读状态，点一下即可
  invalid = demo.click_until(/\A提交买入 /) { demo.text_matching(/\A委托结果：数量无效：/) }
  Report.check_match("资金不足时如实报「数量无效」（不是静默失败）", invalid, /\A委托结果：数量无效：/)
  # 如实记录一处 UX 观察（不断言，避免把"可能不是有意的行为"钉死）：
  # 校验失败时 `提示：` 仍是上一次的成功文案，两个标签不同步。
  warning = demo.text_matching(/\A提示：/)
  puts "info 校验失败后「提示：」标签仍是：#{warning}" if warning && !warning.include?("数量无效")

  # ⑥ 自动交易**真的在交易**（不只是按钮文案）：持仓要**比手动下单后更多**，
  #    账目要变动，而且两处浮盈必须逐帧一致——头部 `浮动盈亏 X` 与持仓面板 `市值 M · 浮盈 X`。
  #    实测（手工采样 60 秒）：持仓 1→6 只、出现分页 `第 1/2 页`、两处数字逐帧相同、
  #    运行日志 0 字节。这里把"同一帧里两个数相等"作为断言：两处各读一次会读到不同帧
  #    （标签每档刷新），所以必须在**一次枚举**里取两个标签。
  #    ⚠️ 这条断言踩过三个坑：① 符号（盈利是 `+427.00`，只写 `-?` 读不到）；
  #    ② 持仓面板的汇总标签是**两行**（`市值 … · 浮盈 …` 换行接 `可用 … · 冻结 …`，
  #    写 `\z` 会在"有持仓"之后永远匹配不上）；③ 标签每档刷新，必须同帧读。
  toggle = demo.control_matching(/\A自动交易 (关|开 ✓)\z/)
  Report.check_match("自动交易开关文案", toggle && toggle[:text], /\A自动交易 (关|开 ✓)\z/)
  if toggle && toggle[:text] != "自动交易 开 ✓"
    demo.click_until(/\A自动交易 关\z/) { demo.text_matching(/\A自动交易 开 ✓\z/) }
  end
  Report.check("自动交易已开", demo.text_matching(/\A自动交易 开 ✓\z/), "自动交易 开 ✓")

  holdings = Report.wait_until(timeout: 60, interval: 1.0) do
    label = demo.text_matching(/\A第 \d+\/\d+ 页 · 共 \d+ 只\z/)
    count = label.to_s[/共 (\d+) 只/, 1].to_i
    label if count > manual_count # 严格多于手动那一只 = 自动交易自己开了仓
  end
  Report.check_match("自动交易开出了新仓（比手动下单时更多）", holdings, /\A第 \d+\/\d+ 页 · 共 \d+ 只\z/)

  same_frame = Report.wait_until(timeout: 20, interval: 0.5) do
    controls = demo.controls # 一次枚举 = 同一帧
    # 两个标签的文本形状都要按**实测**写：
    #   · 符号：盈利时是 `+427.00`（只写 `-?` 会在盈利时读不到）
    #   · 持仓面板的汇总标签是**两行**（`市值 … · 浮盈 …` 换行后接 `可用 … · 冻结 …`），
    #     所以只能止于行内、不能 `\z`（写 `\z` 会在"有持仓"之后永远匹配不上——实测踩过）
    header = controls.find { |c| c[:text].to_s.match?(/\A浮动盈亏 [-+]?[\d,]+\.\d\d/) }
    panel = controls.find { |c| c[:text].to_s.match?(/\A市值 [\d,]+\.\d\d · 浮盈 [-+]?[\d,]+\.\d\d/) }
    next nil unless header && panel

    header_pnl = header[:text].split(" ").last
    panel_pnl = panel[:text][/浮盈 ([-+]?[\d,]+\.\d\d)/, 1]
    [header_pnl, panel_pnl] if header_pnl == panel_pnl
  end
  Report.check("同一帧里「浮动盈亏」与持仓面板「浮盈」相等", !same_frame.nil?, true)

  moved = demo.text_matching(/\A总资产 ([\d,]+\.\d\d)\z/)
  Report.check("总资产已随交易变动（不再是初始值）", moved != "总资产 1,000,000.00", true)

  # ⑥ 关窗即退出 + log 干净（跑过自动交易之后仍然干净：无异常、无崩溃）
  exited = demo.stop
  Report.check("WM_CLOSE 后进程自行退出", exited, true)
  Report.check("log 为空（自动交易跑过之后也无异常输出）", demo.log_text, "")
  demo.dump_last("market") if Report.failures.positive?
rescue StandardError => e
  puts "FAIL citrine-market-terminal 验收异常：#{e.class}: #{e.message}"
  Report.failures += 1
  demo&.stop
end

# ---------------------------------------------------------------- 入口

unless RbConfig::CONFIG["host_os"].match?(/mswin|mingw/i)
  puts "SKIP demo_acceptance：本脚本只在 Windows 上跑（当前 #{RbConfig::CONFIG['host_os']}）"
  exit 0
end

target = (ARGV.first || "all").downcase
UNKNOWN = "用法：ruby test/support/demo_acceptance.rb [all|examples|counter|todo|sheets|market]"
unless %w[all examples counter todo sheets market].include?(target)
  puts "#{UNKNOWN}（收到 #{target.inspect}）"
  exit 2
end
puts "citrine-native 真窗口验收（#{target}）；三仓库父目录：#{PARENT}"

accept_counter if %w[all examples counter].include?(target)
accept_todo if %w[all examples todo].include?(target)
accept_sheets if %w[all sheets].include?(target)
accept_market if %w[all market].include?(target)

puts "\n#{Report.failures.zero? ? 'DEMO_ACCEPTANCE_OK' : "DEMO_ACCEPTANCE_FAILED（#{Report.failures} 项）"}"
exit(Report.failures.zero? ? 0 : 1)
