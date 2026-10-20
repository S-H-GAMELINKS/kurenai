# WEBrick on a machine with one thread.
#
# __clone refuses here, so Thread.new raises ThreadError, and WEBrick asks for a
# thread in two places: one per connection in GenericServer#start_thread, and a
# watcher in Utils::TimeoutHandler for every request it reads. Everything else
# WEBrick does -- the select on the listeners and the shutdown pipe, the
# non-blocking accept, the parsing, the servlets -- runs as written. So this
# replaces exactly those two and leaves the rest alone.
#
# The cost is concurrency: a connection is served to completion before the next
# one is accepted, so there is no keep-alive and a quiet connection is dropped
# quickly (see HTTPResponse below). That is what one thread means, and it is
# the thing kernel threads will take back out of this file.

require "webrick"

module WEBrick
  class GenericServer
    # The body of the upstream method, run on the calling thread. The thread
    # that comes back is the one that did the work, so start's
    #
    #     th[:WEBrickThread] = true
    #     thgroup.add(th)
    #
    # still has something to hold -- and its join at shutdown is the reason for
    # the singleton method at the bottom of this file.
    def start_thread(sock, &block)
      begin
        Thread.current[:WEBrickSocket] = sock
        begin
          addr = sock.peeraddr
          @logger.debug "accept: #{addr[3]}:#{addr[1]}"
        rescue SocketError
          @logger.debug "accept: <address unknown>"
          raise
        end
        call_callback(:AcceptCallback, sock)
        block ? block.call(sock) : run(sock)
      rescue Errno::ENOTCONN
        @logger.debug "Errno::ENOTCONN raised"
      rescue ServerError => ex
        msg = "#{ex.class}: #{ex.message}\n\t#{ex.backtrace[0]}"
        @logger.error msg
      rescue Exception => ex
        @logger.error ex
      ensure
        @tokens.push(nil)
        Thread.current[:WEBrickSocket] = nil
        if addr
          @logger.debug "close: #{addr[3]}:#{addr[1]}"
        else
          @logger.debug "close: <address unknown>"
        end
        sock.close
      end
      Thread.current
    end

    # The console as a listener, so that a keystroke can end the accept loop
    # the same way GenericServer#stop does from another thread: by writing to
    # the shutdown pipe. start selects on [shutdown pipe, *listeners] and hands
    # every ready listener to accept_client, so STDIN arrives here.
    #
    # It leaves the listener list before stop, because start's cleanup closes
    # every listener and the console is not this server's to close.
    def stop_on_console(io = STDIN)
      @listeners << io
      @console = io
    end

    alias_method :accept_client_from_socket, :accept_client
    private :accept_client_from_socket

    def accept_client(svr)
      return accept_client_from_socket(svr) unless svr.equal?(@console)

      # Take the keystroke, so Reline does not find it waiting for it.
      begin
        svr.read_nonblock(64)
      rescue IO::WaitReadable, EOFError
      end
      @listeners.delete(svr)
      @console = nil
      stop
      nil
    end
    private :accept_client
  end

  # A browser holds the server. It keeps its connection open between requests
  # and opens a spare one or two that send nothing until they are needed, and
  # HTTPServer#run waits on a quiet connection for up to :RequestTimeout --
  # thirty seconds -- before giving up on it. With a thread per connection that
  # wait costs one thread. With one thread it costs everybody: Chrome on the
  # far side of WSL's port forward got its first page and then nothing at all.
  #
  # So every response closes its connection, and a connection that has not
  # started a request within two seconds is let go. The second is enforced by
  # run's own wait_readable loop, not by the watcher thread below.
  class HTTPResponse
    def keep_alive?
      false
    end
  end
  Config::HTTP[:RequestTimeout] = 2

  module Utils
    # The request timeout is a watcher thread that raises into the one reading
    # the request. With no second thread there is nothing to watch from, so the
    # block simply runs. A client that starts a request and stops sending
    # partway holds the server until it goes away; one that never starts is
    # still let go by run, as above.
    def timeout(seconds, exception = Timeout::Error)
      yield(seconds)
    end
    module_function :timeout
  end
end

# start joins every thread start_thread returned once the loop ends, and every
# one of them was this thread. Joining oneself is a ThreadError, so for this
# thread alone join answers at once -- it has, by definition, already finished
# everything it was given.
def (Thread.current).join(*)
  self
end
