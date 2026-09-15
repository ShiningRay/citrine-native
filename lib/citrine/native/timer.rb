# frozen_string_literal: true

module Citrine
  module Native
    # 定时器（设计 2.5）：后台 Thread + sleep，到点经适配层的 `queue_main` 排回主线程。
    #
    #   handle = Citrine::Native.every(200) { tick }   # 周期
    #   once   = Citrine::Native.after(500)  { once }  # 一次
    #   handle.stop                                    # 幂等；可从主线程/回调内调用
    #
    # 为什么不用 libui 的 uiTimer：它只能从主线程注册、且生命周期绑在主循环上；走
    # "后台线程 + queue_main" 之后，定时器只依赖适配层的跨线程通道（也就是文档给应用的
    # 唯一跨线程规则），停下也能从任何线程调用。
    #
    # 回调体在主线程执行（与所有控件操作同线程），异常按"回调里的异常不中断应用"的既有
    # 口径打到 stderr 后继续（周期定时器继续跑，单次定时器就此结束）。
    class Timer
      attr_reader :interval

      def self.every(milliseconds, &block) = new(milliseconds, repeat: true, &block)
      def self.after(milliseconds, &block) = new(milliseconds, repeat: false, &block)

      def initialize(milliseconds, repeat:, &block)
        raise ArgumentError, "定时器需要块：Citrine::Native.every(ms) { … }" unless block

        interval = milliseconds.to_f
        raise ArgumentError, "定时器间隔应为正数毫秒，收到 #{milliseconds.inspect}" unless interval.positive?

        @interval = interval
        @repeat = repeat
        @block = block
        @stopped = false
        @thread = Thread.new { run }
        @thread.name = "citrine-native-timer"
      end

      # 幂等（重复 stop 无副作用），可从主线程或在定时器回调内调用
      def stop
        @stopped = true
        @thread&.kill
        self
      end

      def stopped? = @stopped
      def running? = !@stopped

      private

      def run
        loop do
          sleep(@interval / 1000.0)
          break if @stopped

          queue_tick
          break unless @repeat
        end
      end

      # 到点：把回调排回主线程。stop 与"排到主线程"之间有竞争窗口（stop 可能在块执行前
      # 发生，比如组件卸载），所以块内再查一次 @stopped——卸载后不该再被定时器叫醒。
      #
      # 用 **queue_main_once**（执行完就释放引用）而不是 queue_main：定时器每次到点都排一个
      # 新闭包，而 queue_main 会把闭包常驻住（Fiddle 闭包不能被 GC 回收，见 widgets/libui.rb），
      # 于是常驻写法等于"每个 tick 漏一个闭包"——NA-2 实测 50ms 定时器 5 秒内
      # closures/ticks = 54/52（慢漏但无界），而两个移植 demo 都在用 `every`。
      # 定时器的闭包本来就只需执行一次，语义等价；按钮/按键那类**必须**常驻的订阅闭包仍走 queue_main。
      def queue_tick
        widgets = Citrine::Native.active_widgets
        if widgets.nil?
          warn "[citrine-native] 定时器到点了但没有活动后端（Citrine::Native.active_widgets 为空）：" \
               "定时器要在 Citrine::Native.run/start 之后创建"
          return
        end

        widgets.queue_main_once do
          tick unless @stopped
        end
      end

      def tick
        @block.call
      rescue StandardError => e
        warn "[citrine-native] 定时器回调抛出 #{e.class}: #{e.message}"
        warn(e.backtrace.first(8).map { |line| "    #{line}" }.join("\n"))
      end
    end
  end
end
