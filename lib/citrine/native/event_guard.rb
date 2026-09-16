# frozen_string_literal: true

module Citrine
  module Native
    # 事件层错误边界（统一契约，两后端同口径）：应用的事件处理器抛出的异常
    # **一律不抛回平台事件栈**——Fiddle/libui 闭包里抛出走未定义路径（轻则丢事件
    # 重则崩进程），GTK 信号处理器里抛出直接终止进程。策略单点在核心：Renderer
    # 的各 dispatch 入口包 guard，后端自己的非核心路径（libui 的 queue_main、
    # GTK 的信号块）复用同一份实现，只报不抛，主循环继续。
    #
    # 与渲染期错误边界（Renderer 节点级错误边界）分层：那是 view 构树期，
    # 这里是事件回调期。
    module EventGuard
      module_function

      # 执行块；异常打 stderr（上下文 + 首 8 帧栈）后返回 nil。
      # 调用方需要布尔语义时自己对返回值做 !!（如键盘"是否已处理"）。
      def guard(context)
        yield
      rescue StandardError => e
        report(e, context)
        nil
      end

      # 只报不吞的变体（调用方自己 rescue 时复用同一份输出格式）
      def report(exception, context)
        warn "[citrine-native] #{context} 抛出 #{exception.class}: #{exception.message}"
        return unless exception.backtrace

        warn(exception.backtrace.first(8).map { |line| "    #{line}" }.join("\n"))
        nil
      end
    end
  end
end
