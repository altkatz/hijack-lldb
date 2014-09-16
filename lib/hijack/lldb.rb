module Hijack
  class LLDB
    def initialize(pid)
      @pid = pid
      @verbose = Hijack.options[:debug]
      @exec_path = File.join(Config::CONFIG['bindir'], Config::CONFIG['RUBY_INSTALL_NAME'] + Config::CONFIG['EXEEXT'])
      debugger
      attach_outside_gc
    end

    def eval(cmd)
      call("(void)rb_eval_string(#{cmd.strip.gsub(/"/, '\"').inspect})")
    end

    def quit
      return unless @lldb
      detach
      exec('quit')
      @backtrace = nil
      @lldb.close
      @lldb = nil
    end

  protected

    def previous_frame_inner_to_this_frame?
      backtrace.last =~ /previous frame inner to this frame/i
    end

    def attach_outside_gc
      @lldb = IO.popen("lldb #{@exec_path} #{@pid} 2>&1", 'r+')
      debugger
      wait
      ensure_attached_to_ruby_process
      attached = false

      3.times do |i|
        attach unless i == 0

        if previous_frame_inner_to_this_frame? || during_gc?
          detach
          sleep 0.1
        else
          attached = true
          break
        end
      end

      unless attached
        puts
        puts "=> Tried 3 times to attach to #{@pid} whilst GC wasn't running but failed."
        puts "=> This means either the process calls GC.start frequently or GC runs are slow - try hijacking again."
        exit 1
      end

      break_on_safe_stack_unwind
    end

    def break_on_safe_stack_unwind
      safe = false
      backtrace.each do |line|
        # vm_call_method == 1.9, rb_call == 1.8
        if line =~ /(vm_call_method|rb_call)/
          frame = line.match(/^\#([\d]+)/)[1]
          safe = true
          exec("frame select #{frame}")
          exec("break")
          exec("continue")
          exec("delete 1")
          break
        end
      end

      if !safe
        puts "=> WARNING: Did not detect a safe frame on which to set a breakpoint, hijack may fail."
      end
    end

    def during_gc?
      !!(call("(int)rb_during_gc()").first =~ /\$[\d]+ = 1/)
    end

    def detach
      exec("detach")
    end

    def attach
      exec("attach #{@pid}")
    end

    def ensure_attached_to_ruby_process
      unless backtrace.any? {|line| line =~ /(rb|ruby)_/}
        puts "\n=> #{@pid} doesn't appear to be a Ruby process!"
        detach
        exit 1
      end
    end

    def backtrace
      @backtrace ||= exec('bt')
    end

    def continue
      exec('continue')
    end

    def call(cmd)
      exec("call #{cmd}")
    end

    def exec(str)
      puts str if @verbose
      @lldb.puts(str)
      wait
      debugger
    end

    def wait
      lines = []
      line = ''
      while result = IO.select([@lldb])
        next if result.empty?
        c = @lldb.read(1)
        break if c.nil?
        STDOUT.write(c) if @verbose
        line << c
        break if line == "(lldb) " || line == " >"
        if line[-1] == ?\n
          lines << line
          line = ""
        end
      end
      debugger
      lines
    end
  end
end
