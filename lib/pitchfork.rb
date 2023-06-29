# -*- encoding: binary -*-
require 'etc'
require 'stringio'
require 'raindrops'
require 'io/wait'

begin
  require 'rack'
rescue LoadError
  warn 'rack not available, functionality reduced'
end

# :stopdoc:
# Pitchfork module containing all of the classes (include C extensions) for
# running a Pitchfork web server.  It contains a minimalist HTTP server with just
# enough functionality to service web application requests fast as possible.
# :startdoc:

# pitchfork exposes very little of an user-visible API and most of its
# internals are subject to change.  pitchfork is designed to host Rack
# applications, so applications should be written against the Rack SPEC
# and not pitchfork internals.
module Pitchfork

  # Raised inside TeeInput when a client closes the socket inside the
  # application dispatch.  This is always raised with an empty backtrace
  # since there is nothing in the application stack that is responsible
  # for client shutdowns/disconnects.  This exception is visible to Rack
  # applications.  This is a subclass of the standard EOFError class and
  # applications should not rescue it explicitly, but rescue EOFError instead.
  # Such an error is likely an indication that the reverse proxy in front
  # of Pitchfork isn't properly buffering requests.
  ClientShutdown = Class.new(EOFError)

  BootFailure = Class.new(StandardError)

  # :stopdoc:

  # This returns a lambda to pass in as the app, this does not "build" the
  # app The returned lambda will be called when it is
  # time to build the app.
  def self.builder(ru, op)
    # allow Configurator to parse cli switches embedded in the ru file
    op = Pitchfork::Configurator::RACKUP.merge!(:file => ru, :optparse => op)
    if ru =~ /\.ru$/ && !defined?(Rack::Builder)
      abort "rack and Rack::Builder must be available for processing #{ru}"
    end

    # always called after config file parsing, may be called after forking
    lambda do |_, server|
      inner_app = case ru
      when /\.ru$/
        raw = File.read(ru)
        raw.sub!(/^__END__\n.*/, '')
        eval("Rack::Builder.new {(\n#{raw}\n)}.to_app", TOPLEVEL_BINDING, ru)
      else
        require ru
        Object.const_get(File.basename(ru, '.rb').capitalize)
      end

      Rack::Builder.new do
        use(Rack::ContentLength)
        use(Pitchfork::Chunked)
        use(Rack::Lint) if ENV["RACK_ENV"] == "development"
        use(Rack::TempfileReaper)
        run inner_app
      end.to_app
    end
  end

  # returns an array of strings representing TCP listen socket addresses
  # and Unix domain socket paths.  This is useful for use with
  # Raindrops::Middleware under Linux: https://yhbt.net/raindrops/
  def self.listener_names
    Pitchfork::HttpServer::LISTENERS.map do |io|
      Pitchfork::SocketHelper.sock_name(io)
    end
  end

  def self.log_error(logger, prefix, exc)
    message = exc.message
    message = message.dump if /[[:cntrl:]]/ =~ message
    logger.error "#{prefix}: #{message} (#{exc.class})"
    exc.backtrace.each { |line| logger.error(line) }
  end

  F_SETPIPE_SZ = 1031 if RUBY_PLATFORM =~ /linux/

  def self.pipe # :nodoc:
    IO.pipe.each do |io|
      # shrink pipes to minimize impact on /proc/sys/fs/pipe-user-pages-soft
      # limits.
      if defined?(F_SETPIPE_SZ)
        begin
          io.fcntl(F_SETPIPE_SZ, Raindrops::PAGE_SIZE)
        rescue Errno::EINVAL
          # old kernel
        rescue Errno::EPERM
          # resizes fail if Linux is close to the pipe limit for the user
          # or if the user does not have permissions to resize
        end
      end
    end
  end

  @socket_type = :SOCK_SEQPACKET
  def self.socketpair
    pair = UNIXSocket.socketpair(@socket_type).map { |s| MessageSocket.new(s) }
    pair[0].close_write
    pair[1].close_read
    pair
  rescue Errno::EPROTONOSUPPORT
    if @socket_type == :SOCK_SEQPACKET
      # macOS and very old linuxes don't support SOCK_SEQPACKET (SCTP).
      # In such case we can fallback to SOCK_STREAM (TCP)
      warn("SEQPACKET (SCTP) isn't supported, falling back to STREAM")
      @socket_type = :SOCK_STREAM
      retry
    else
      raise
    end
  end

  def self.clean_fork(setpgid: true, &block)
    if pid = Process.fork
      if setpgid
        Process.setpgid(pid, pid) # Make into a group leader
      end
      return pid
    end

    begin
      # Pitchfork recursively refork the worker processes.
      # Because of this we need to unwind the stack before resuming execution
      # in the child, otherwise on each generation the available stack space would
      # get smaller and smaller until it's basically 0.
      #
      # The very first version of this method used to call fork from a new
      # thread, however this can cause issues with some native gems that rely on
      # pthread_atfork(3) or pthread_mutex_lock(3), as the new main thread would
      # now be different.
      #
      # A second version used to fork from a new fiber, but fibers have a much smaller
      # stack space (https://bugs.ruby-lang.org/issues/3187), so it would break large applications.
      #
      # The latest version now use `throw` to unwind the stack after the fork, it however
      # restrict it to be called only inside `handle_clean_fork`.
      if Thread.current[:pitchfork_handle_clean_fork]
        throw self, block
      else
        while block
          block = catch(self) do
            Thread.current[:pitchfork_handle_clean_fork] = true
            block.call
            nil
          end
        end
      end
    rescue
      abort
    else
      exit
    end
  end

  def self.fork_sibling(&block)
    if REFORKING_AVAILABLE
      # We double fork so that the new worker is re-attached back
      # to the master.
      # This requires either PR_SET_CHILD_SUBREAPER which is exclusive to Linux 3.4
      # or the master to be PID 1.
      if middle_pid = Process.fork # parent
        # We need to wait(2) so that the middle process doesn't end up a zombie.
        Process.wait(middle_pid)
      else # first child
        clean_fork(&block) # detach into a grand child
        exit
      end
    else
      clean_fork(&block)
    end

    nil # it's tricky to return the PID
  end

  def self.time_now(int = false)
    Process.clock_gettime(Process::CLOCK_MONOTONIC, int ? :second : :float_second)
  end
  # :startdoc:
end
# :enddoc:

require 'pitchfork/pitchfork_http'

Pitchfork::REFORKING_AVAILABLE = Pitchfork::CHILD_SUBREAPER_AVAILABLE || Process.pid == 1

require_relative "pitchfork/const"
require_relative "pitchfork/socket_helper"
require_relative "pitchfork/stream_input"
require_relative "pitchfork/tee_input"
require_relative "pitchfork/mem_info"
require_relative "pitchfork/children"
require_relative "pitchfork/message"
require_relative "pitchfork/chunked"
require_relative "pitchfork/http_parser"
require_relative "pitchfork/refork_condition"
require_relative "pitchfork/configurator"
require_relative "pitchfork/tmpio"
require_relative "pitchfork/http_response"
require_relative "pitchfork/worker"
require_relative "pitchfork/http_server"
