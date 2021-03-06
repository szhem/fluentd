#
# Fluent
#
# Copyright (C) 2011 FURUHASHI Sadayuki
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
module Fluent
  class NewTailInput < Input
    Plugin.register_input('tail', self)

    def initialize
      super
      @paths = []
    end

    config_param :path, :string
    config_param :tag, :string
    config_param :rotate_wait, :time, :default => 5
    config_param :pos_file, :string, :default => nil

    attr_reader :paths

    def configure(conf)
      super

      @paths = @path.split(',').map {|path| path.strip }
      if @paths.empty?
        raise ConfigError, "tail: 'path' parameter is required on tail input"
      end

      unless @pos_file
        $log.warn "'pos_file PATH' parameter is not set to a 'tail' source."
        $log.warn "this parameter is highly recommended to save the position to resume tailing."
      end

      configure_parser(conf)

      @multiline_mode = conf['format'] == 'multiline'
      @receive_handler = if @multiline_mode
                           method(:parse_multilines)
                         else
                           method(:parse_singleline)
                         end
    end

    def configure_parser(conf)
      @parser = TextParser.new
      @parser.configure(conf)
    end

    def start
      if @pos_file
        @pf_file = File.open(@pos_file, File::RDWR|File::CREAT, DEFAULT_FILE_PERMISSION)
        @pf_file.sync = true
        @pf = PositionFile.parse(@pf_file)
      end

      @loop = Coolio::Loop.new
      @tails = @paths.map {|path|
        pe = @pf ? @pf[path] : MemoryPositionEntry.new
        tw = TailWatcher.new(path, @rotate_wait, pe, &method(:receive_lines))
        tw.log = log
        tw
      }
      @tails.each {|tail|
        tail.attach(@loop)
      }
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      @tails.each {|tail|
        tail.close
      }
      @loop.stop
      @thread.join

      flush_buffer if @multiline_mode
      @pf_file.close if @pf_file
    end

    def flush_buffer
      @tails.each { |tail|
        if lb = tail.line_buffer
          lb.chomp!
          time, record = parse_line(lb)
          if time && record
            Engine.emit(@tag, time, record)
          else
            log.warn "got incomplete line at shutdown from #{tail.path}: #{lb.inspect}"
          end
        end
      }
    end

    def run
      @loop.run
    rescue
      log.error "unexpected error", :error=>$!.to_s
      log.error_backtrace
    end

    def receive_lines(lines, tail_watcher)
      es = @receive_handler.call(lines, tail_watcher)
      unless es.empty?
        begin
          Engine.emit_stream(@tag, es)
        rescue
          # ignore errors. Engine shows logs and backtraces.
        end
      end
    end

    def parse_line(line)
      return @parser.parse(line)
    end

    def convert_line_to_event(line, es)
      begin
        line.chomp!  # remove \n
        time, record = parse_line(line)
        if time && record
          es.add(time, record)
        else
          log.warn "pattern not match: #{line.inspect}"
        end
      rescue => e
        log.warn line.dump, :error => e.to_s
        log.debug_backtrace(e)
      end
    end

    def parse_singleline(lines, tail_watcher)
      es = MultiEventStream.new
      lines.each { |line|
        convert_line_to_event(line, es)
      }
      es
    end

    def parse_multilines(lines, tail_watcher)
      lb = tail_watcher.line_buffer
      es = MultiEventStream.new
      lines.each { |line|
        if @parser.parser.firstline?(line)
          if lb
            convert_line_to_event(lb, es)
          end
          lb = line
        else
          if lb.nil?
            log.warn "got incomplete line before first line from #{tail_watcher.path}: #{lb.inspect}"
          else
            lb << line
          end
        end
      }
      tail_watcher.line_buffer = lb
      es
    end

    class TailWatcher
      def initialize(path, rotate_wait, pe, &receive_lines)
        @path = path
        @rotate_wait = rotate_wait
        @pe = pe || MemoryPositionEntry.new
        @receive_lines = receive_lines

        @rotate_queue = []

        @timer_trigger = TimerWatcher.new(1, true, &method(:on_notify))
        @stat_trigger = StatWatcher.new(path, &method(:on_notify))

        @rotate_handler = RotateHandler.new(path, &method(:on_rotate))
        @io_handler = nil
        @log = $log
      end

      attr_reader :path
      attr_accessor :line_buffer

      # We use accessor approach to assign each logger, not passing log object at initialization,
      # because several plugins depend on these internal classes.
      # This approach avoids breaking plugins with new log_level option.
      attr_accessor :log

      def log=(logger)
        @log = logger
        @timer_trigger.log = logger
        @stat_trigger.log = logger
        @rotate_handler.log = logger
      end

      def wrap_receive_lines(lines)
        @receive_lines.call(lines, self)
      end

      def attach(loop)
        @timer_trigger.attach(loop)
        @stat_trigger.attach(loop)
        on_notify
      end

      def detach
        @timer_trigger.detach if @timer_trigger.attached?
        @stat_trigger.detach if @stat_trigger.attached?
      end

      def close
        @rotate_queue.reject! {|req|
          req.io.close
          true
        }
        detach
      end

      def on_notify
        @rotate_handler.on_notify
        return unless @io_handler
        @io_handler.on_notify

        # proceeds rotate queue
        return if @rotate_queue.empty?
        @rotate_queue.first.tick

        while @rotate_queue.first.ready?
          if io = @rotate_queue.first.io
            stat = io.stat
            inode = stat.ino
            if inode == @pe.read_inode
              # rotated file has the same inode number with the last file.
              # assuming following situation:
              #   a) file was once renamed and backed, or
              #   b) symlink or hardlink to the same file is recreated
              # in either case, seek to the saved position
              pos = @pe.read_pos
            else
              pos = io.pos
            end
            @pe.update(inode, pos)
            io_handler = IOHandler.new(io, @pe, log, &method(:wrap_receive_lines))
          else
            io_handler = NullIOHandler.new
          end
          @io_handler.close
          @io_handler = io_handler
          @rotate_queue.shift
          break if @rotate_queue.empty?
        end
      end

      def on_rotate(io)
        if @io_handler == nil
          if io
            # first time
            stat = io.stat
            fsize = stat.size
            inode = stat.ino

            last_inode = @pe.read_inode
            if inode == last_inode
              # seek to the saved position
              pos = @pe.read_pos
            elsif last_inode != 0
              # this is FilePositionEntry and fluentd once started.
              # read data from the head of the rotated file.
              # logs never duplicate because this file is a rotated new file.
              pos = 0
              @pe.update(inode, pos)
            else
              # this is MemoryPositionEntry or this is the first time fluentd started.
              # seek to the end of the any files.
              # logs may duplicate without this seek because it's not sure the file is
              # existent file or rotated new file.
              pos = fsize
              @pe.update(inode, pos)
            end
            io.seek(pos)

            @io_handler = IOHandler.new(io, @pe, log, &method(:wrap_receive_lines))
          else
            @io_handler = NullIOHandler.new
          end

        else
          if io && @rotate_queue.find {|req| req.io == io }
            return
          end
          last_io = @rotate_queue.empty? ? @io_handler.io : @rotate_queue.last.io
          if last_io == nil
            log.info "detected rotation of #{@path}"
            # rotate imeediately if previous file is nil
            wait = 0
          else
            log.info "detected rotation of #{@path}; waiting #{@rotate_wait} seconds"
            wait = @rotate_wait
            wait -= @rotate_queue.first.wait unless @rotate_queue.empty?
          end
          @rotate_queue << RotationRequest.new(io, wait)
        end
      end

      class TimerWatcher < Coolio::TimerWatcher
        def initialize(interval, repeat, &callback)
          @callback = callback
          @log = $log
          super(interval, repeat)
        end

        attr_accessor :log

        def on_timer
          @callback.call
        rescue
          # TODO log?
          @log.error $!.to_s
          @log.error_backtrace
        end
      end

      class StatWatcher < Coolio::StatWatcher
        def initialize(path, &callback)
          @callback = callback
          @log = $log
          super(path)
        end

        attr_accessor :log

        def on_change(prev, cur)
          @callback.call
        rescue
          # TODO log?
          @log.error $!.to_s
          @log.error_backtrace
        end
      end

      class RotationRequest
        def initialize(io, wait)
          @io = io
          @wait = wait
        end

        attr_reader :io, :wait

        def tick
          @wait -= 1
        end

        def ready?
          @wait <= 0
        end
      end

      MAX_LINES_AT_ONCE = 1000

      class IOHandler
        def initialize(io, pe, log, &receive_lines)
          @log = log
          @log.info "following tail of #{io.path}"
          @io = io
          @pe = pe
          @receive_lines = receive_lines
          @buffer = ''.force_encoding('ASCII-8BIT')
          @iobuf = ''.force_encoding('ASCII-8BIT')
        end

        attr_reader :io

        def on_notify
          begin
            lines = []
            read_more = false

            begin
              while true
                if @buffer.empty?
                  @io.read_nonblock(2048, @buffer)
                else
                  @buffer << @io.read_nonblock(2048, @iobuf)
                end
                while line = @buffer.slice!(/.*?\n/m)
                  lines << line
                end
                if lines.size >= MAX_LINES_AT_ONCE
                  # not to use too much memory in case the file is very large
                  read_more = true
                  break
                end
              end
            rescue EOFError
            end

            unless lines.empty?
              @receive_lines.call(lines)
              @pe.update_pos(@io.pos - @buffer.bytesize)
            end
          end while read_more

        rescue
          @log.error $!.to_s
          @log.error_backtrace
          close
        end

        def close
          @io.close unless @io.closed?
        end
      end

      class NullIOHandler
        def initialize
        end

        def io
        end

        def on_notify
        end

        def close
        end
      end

      class RotateHandler
        def initialize(path, &on_rotate)
          @path = path
          @inode = nil
          @fsize = -1  # first
          @on_rotate = on_rotate
          @log = $log
        end

        attr_accessor :log

        def on_notify
          begin
            io = File.open(@path)
            stat = io.stat
            inode = stat.ino
            fsize = stat.size
          rescue Errno::ENOENT
            # moved or deleted
            inode = nil
            fsize = 0
          end

          begin
            if @inode != inode || fsize < @fsize
              # rotated or truncated
              @on_rotate.call(io)
              io = nil
            end

            @inode = inode
            @fsize = fsize
          ensure
            io.close if io
          end

        rescue
          @log.error $!.to_s
          @log.error_backtrace
        end
      end
    end


    class PositionFile
      def initialize(file, map, last_pos)
        @file = file
        @map = map
        @last_pos = last_pos
      end

      def [](path)
        if m = @map[path]
          return m
        end

        @file.pos = @last_pos
        @file.write path
        @file.write "\t"
        seek = @file.pos
        @file.write "0000000000000000\t00000000\n"
        @last_pos = @file.pos

        @map[path] = FilePositionEntry.new(@file, seek)
      end

      def self.parse(file)
        map = {}
        file.pos = 0
        file.each_line {|line|
          m = /^([^\t]+)\t([0-9a-fA-F]+)\t([0-9a-fA-F]+)/.match(line)
          next unless m
          path = m[1]
          pos = m[2].to_i(16)
          ino = m[3].to_i(16)
          seek = file.pos - line.bytesize + path.bytesize + 1
          map[path] = FilePositionEntry.new(file, seek)
        }
        new(file, map, file.pos)
      end
    end

    # pos               inode
    # ffffffffffffffff\tffffffff\n
    class FilePositionEntry
      POS_SIZE = 16
      INO_OFFSET = 17
      INO_SIZE = 8
      LN_OFFSET = 25
      SIZE = 26

      def initialize(file, seek)
        @file = file
        @seek = seek
      end

      def update(ino, pos)
        @file.pos = @seek
        @file.write "%016x\t%08x" % [pos, ino]
        @inode = ino
      end

      def update_pos(pos)
        @file.pos = @seek
        @file.write "%016x" % pos
      end

      def read_inode
        @file.pos = @seek + INO_OFFSET
        raw = @file.read(8)
        raw ? raw.to_i(16) : 0
      end

      def read_pos
        @file.pos = @seek
        raw = @file.read(16)
        raw ? raw.to_i(16) : 0
      end
    end

    class MemoryPositionEntry
      def initialize
        @pos = 0
        @inode = 0
      end

      def update(ino, pos)
        @inode = ino
        @pos = pos
      end

      def update_pos(pos)
        @pos = pos
      end

      def read_pos
        @pos
      end

      def read_inode
        @inode
      end
    end
  end

  # This TailInput is for existence plugins which extends old in_tail
  # This class will be removed after release v1.
  class TailInput < Input
    def initialize
      super
      @paths = []
    end

    config_param :path, :string
    config_param :tag, :string
    config_param :rotate_wait, :time, :default => 5
    config_param :pos_file, :string, :default => nil

    attr_reader :paths

    def configure(conf)
      super

      @paths = @path.split(',').map {|path| path.strip }
      if @paths.empty?
        raise ConfigError, "tail: 'path' parameter is required on tail input"
      end

      unless @pos_file
        $log.warn "'pos_file PATH' parameter is not set to a 'tail' source."
        $log.warn "this parameter is highly recommended to save the position to resume tailing."
      end

      configure_parser(conf)
    end

    def configure_parser(conf)
      @parser = TextParser.new
      @parser.configure(conf)
    end

    def start
      if @pos_file
        @pf_file = File.open(@pos_file, File::RDWR|File::CREAT, DEFAULT_FILE_PERMISSION)
        @pf_file.sync = true
        @pf = PositionFile.parse(@pf_file)
      end

      @loop = Coolio::Loop.new
      @tails = @paths.map {|path|
        pe = @pf ? @pf[path] : MemoryPositionEntry.new
        tw = TailWatcher.new(path, @rotate_wait, pe, &method(:receive_lines))
        tw.log = log
        tw
      }
      @tails.each {|tail|
        tail.attach(@loop)
      }
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      @tails.each {|tail|
        tail.close
      }
      @loop.stop
      @thread.join
      @pf_file.close if @pf_file
    end

    def run
      @loop.run
    rescue
      log.error "unexpected error", :error=>$!.to_s
      log.error_backtrace
    end

    def receive_lines(lines)
      es = MultiEventStream.new
      lines.each {|line|
        begin
          line.chomp!  # remove \n
          time, record = parse_line(line)
          if time && record
            es.add(time, record)
          else
            log.warn "pattern not match: #{line.inspect}"
          end
        rescue
          log.warn line.dump, :error=>$!.to_s
          log.debug_backtrace
        end
      }

      unless es.empty?
        begin
          Engine.emit_stream(@tag, es)
        rescue
          # ignore errors. Engine shows logs and backtraces.
        end
      end
    end

    def parse_line(line)
      return @parser.parse(line)
    end

    class TailWatcher
      def initialize(path, rotate_wait, pe, &receive_lines)
        @path = path
        @rotate_wait = rotate_wait
        @pe = pe || MemoryPositionEntry.new
        @receive_lines = receive_lines

        @rotate_queue = []

        @timer_trigger = TimerWatcher.new(1, true, &method(:on_notify))
        @stat_trigger = StatWatcher.new(path, &method(:on_notify))

        @rotate_handler = RotateHandler.new(path, &method(:on_rotate))
        @io_handler = nil
        @log = $log
      end

      # We use accessor approach to assign each logger, not passing log object at initialization,
      # because several plugins depend on these internal classes.
      # This approach avoids breaking plugins with new log_level option.
      attr_accessor :log

      def log=(logger)
        @log = logger
        @timer_trigger.log = logger
        @stat_trigger.log = logger
        @rotate_handler.log = logger
      end

      def attach(loop)
        @timer_trigger.attach(loop)
        @stat_trigger.attach(loop)
        on_notify
      end

      def detach
        @timer_trigger.detach if @timer_trigger.attached?
        @stat_trigger.detach if @stat_trigger.attached?
      end

      def close
        @rotate_queue.reject! {|req|
          req.io.close
          true
        }
        detach
      end

      def on_notify
        @rotate_handler.on_notify
        return unless @io_handler
        @io_handler.on_notify

        # proceeds rotate queue
        return if @rotate_queue.empty?
        @rotate_queue.first.tick

        while @rotate_queue.first.ready?
          if io = @rotate_queue.first.io
            stat = io.stat
            inode = stat.ino
            if inode == @pe.read_inode
              # rotated file has the same inode number with the last file.
              # assuming following situation:
              #   a) file was once renamed and backed, or
              #   b) symlink or hardlink to the same file is recreated
              # in either case, seek to the saved position
              pos = @pe.read_pos
            else
              pos = io.pos
            end
            @pe.update(inode, pos)
            io_handler = IOHandler.new(io, @pe, log, &@receive_lines)
          else
            io_handler = NullIOHandler.new
          end
          @io_handler.close
          @io_handler = io_handler
          @rotate_queue.shift
          break if @rotate_queue.empty?
        end
      end

      def on_rotate(io)
        if @io_handler == nil
          if io
            # first time
            stat = io.stat
            fsize = stat.size
            inode = stat.ino

            last_inode = @pe.read_inode
            if inode == last_inode
              # seek to the saved position
              pos = @pe.read_pos
            elsif last_inode != 0
              # this is FilePositionEntry and fluentd once started.
              # read data from the head of the rotated file.
              # logs never duplicate because this file is a rotated new file.
              pos = 0
              @pe.update(inode, pos)
            else
              # this is MemoryPositionEntry or this is the first time fluentd started.
              # seek to the end of the any files.
              # logs may duplicate without this seek because it's not sure the file is
              # existent file or rotated new file.
              pos = fsize
              @pe.update(inode, pos)
            end
            io.seek(pos)

            @io_handler = IOHandler.new(io, @pe, log, &@receive_lines)
          else
            @io_handler = NullIOHandler.new
          end

        else
          if io && @rotate_queue.find {|req| req.io == io }
            return
          end
          last_io = @rotate_queue.empty? ? @io_handler.io : @rotate_queue.last.io
          if last_io == nil
            log.info "detected rotation of #{@path}"
            # rotate imeediately if previous file is nil
            wait = 0
          else
            log.info "detected rotation of #{@path}; waiting #{@rotate_wait} seconds"
            wait = @rotate_wait
            wait -= @rotate_queue.first.wait unless @rotate_queue.empty?
          end
          @rotate_queue << RotationRequest.new(io, wait)
        end
      end

      class TimerWatcher < Coolio::TimerWatcher
        def initialize(interval, repeat, &callback)
          @callback = callback
          @log = $log
          super(interval, repeat)
        end

        attr_accessor :log

        def on_timer
          @callback.call
        rescue
          # TODO log?
          @log.error $!.to_s
          @log.error_backtrace
        end
      end

      class StatWatcher < Coolio::StatWatcher
        def initialize(path, &callback)
          @callback = callback
          @log = $log
          super(path)
        end

        attr_accessor :log

        def on_change(prev, cur)
          @callback.call
        rescue
          # TODO log?
          @log.error $!.to_s
          @log.error_backtrace
        end
      end

      class RotationRequest
        def initialize(io, wait)
          @io = io
          @wait = wait
        end

        attr_reader :io, :wait

        def tick
          @wait -= 1
        end

        def ready?
          @wait <= 0
        end
      end

      MAX_LINES_AT_ONCE = 1000

      class IOHandler
        def initialize(io, pe, log, &receive_lines)
          @log = log
          @log.info "following tail of #{io.path}"
          @io = io
          @pe = pe
          @receive_lines = receive_lines
          @buffer = ''.force_encoding('ASCII-8BIT')
          @iobuf = ''.force_encoding('ASCII-8BIT')
        end

        attr_reader :io

        def on_notify
          begin
            lines = []
            read_more = false

            begin
              while true
                if @buffer.empty?
                  @io.read_nonblock(2048, @buffer)
                else
                  @buffer << @io.read_nonblock(2048, @iobuf)
                end
                while line = @buffer.slice!(/.*?\n/m)
                  lines << line
                end
                if lines.size >= MAX_LINES_AT_ONCE
                  # not to use too much memory in case the file is very large
                  read_more = true
                  break
                end
              end
            rescue EOFError
            end

            unless lines.empty?
              @receive_lines.call(lines)
              @pe.update_pos(@io.pos - @buffer.bytesize)
            end

          end while read_more

        rescue
          @log.error $!.to_s
          @log.error_backtrace
          close
        end

        def close
          @io.close unless @io.closed?
        end
      end

      class NullIOHandler
        def initialize
        end

        def io
        end

        def on_notify
        end

        def close
        end
      end

      class RotateHandler
        def initialize(path, &on_rotate)
          @path = path
          @inode = nil
          @fsize = -1  # first
          @on_rotate = on_rotate
          @log = $log
        end

        attr_accessor :log

        def on_notify
          begin
            io = File.open(@path)
            stat = io.stat
            inode = stat.ino
            fsize = stat.size
          rescue Errno::ENOENT
            # moved or deleted
            inode = nil
            fsize = 0
          end

          begin
            if @inode != inode || fsize < @fsize
              # rotated or truncated
              @on_rotate.call(io)
              io = nil
            end

            @inode = inode
            @fsize = fsize
          ensure
            io.close if io
          end

        rescue
          @log.error $!.to_s
          @log.error_backtrace
        end
      end
    end


    class PositionFile
      def initialize(file, map, last_pos)
        @file = file
        @map = map
        @last_pos = last_pos
      end

      def [](path)
        if m = @map[path]
          return m
        end

        @file.pos = @last_pos
        @file.write path
        @file.write "\t"
        seek = @file.pos
        @file.write "0000000000000000\t00000000\n"
        @last_pos = @file.pos

        @map[path] = FilePositionEntry.new(@file, seek)
      end

      def self.parse(file)
        map = {}
        file.pos = 0
        file.each_line {|line|
          m = /^([^\t]+)\t([0-9a-fA-F]+)\t([0-9a-fA-F]+)/.match(line)
          next unless m
          path = m[1]
          pos = m[2].to_i(16)
          ino = m[3].to_i(16)
          seek = file.pos - line.bytesize + path.bytesize + 1
          map[path] = FilePositionEntry.new(file, seek)
        }
        new(file, map, file.pos)
      end
    end

    # pos               inode
    # ffffffffffffffff\tffffffff\n
    class FilePositionEntry
      POS_SIZE = 16
      INO_OFFSET = 17
      INO_SIZE = 8
      LN_OFFSET = 25
      SIZE = 26

      def initialize(file, seek)
        @file = file
        @seek = seek
      end

      def update(ino, pos)
        @file.pos = @seek
        @file.write "%016x\t%08x" % [pos, ino]
        @inode = ino
      end

      def update_pos(pos)
        @file.pos = @seek
        @file.write "%016x" % pos
      end

      def read_inode
        @file.pos = @seek + INO_OFFSET
        raw = @file.read(8)
        raw ? raw.to_i(16) : 0
      end

      def read_pos
        @file.pos = @seek
        raw = @file.read(16)
        raw ? raw.to_i(16) : 0
      end
    end

    class MemoryPositionEntry
      def initialize
        @pos = 0
        @inode = 0
      end

      def update(ino, pos)
        @inode = ino
        @pos = pos
      end

      def update_pos(pos)
        @pos = pos
      end

      def read_pos
        @pos
      end

      def read_inode
        @inode
      end
    end
  end
end
