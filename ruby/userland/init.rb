# The first Ruby that runs on top of CRuby.
#
# Embedded in the image as a string and evaluated at boot, because there is
# nothing to require it from until the load path below is set up.

# Nothing here is a terminal as far as the kernel is concerned, so CRuby block
# buffers its output. A prompt that appears after the answer is not a prompt.
STDOUT.sync = true

# The kernel serves Ruby libraries at the root, so putting "/" on the load path
# is all require needs. Nothing is monkey-patched: CRuby's own require calls
# stat, open, mmap and read, and the Ruby kernel answers.
$LOAD_PATH.unshift("/")

# CRuby names its encoding constants from the encoding database, which is
# normally a dynamically loaded extension. kernel/enc.c declares the four
# built-in encodings but cannot create the constants, so they are made here
# from what is registered. Without them reline fails on Encoding::US_ASCII, and
# cgi/escape -- which WEBrick reaches through erb -- on Encoding::UTF_8.
Encoding.list.each do |encoding|
  name = encoding.name.gsub("-", "_").gsub(".", "_")
  next if Encoding.const_defined?(name, false)
  begin
    Encoding.const_set(name, encoding)
  rescue NameError
    # Names that are not valid constants; nothing looks those up by constant.
  end
end

puts "cruby #{RUBY_VERSION} on picoruby-kernel"
puts "1 + 1 = #{1 + 1}"

# Bignum arithmetic, which is CRuby's and not something the mruby VM below it
# could do. It also exercises the 128-bit division helpers the kernel links
# from compiler-rt.
puts "2**100 = #{2**100}"

# The parser is Prism, compiled into the kernel image.
puts [3, 1, 2].sort.inspect

# Read a file whose filesystem is implemented in Ruby. Between File.read and
# the bytes arriving, every step -- open, fstat, read, close -- ran in the
# other VM.
puts File.read("/hello.rb")
puts "read #{File.size("/hello.rb")} bytes from the Ruby VFS"

# The two extensions irb depends on. io/console is linked in and registered by
# Init_ext. ripper needs its Ruby half too, and that comes through require from
# the VFS -- which is the same road irb and reline will travel.
require "io/console"
require "ripper"
puts "io/console: IO#raw #{IO.method_defined?(:raw)}"
puts "ripper: #{Ripper.lex("1 + 1").length} tokens from Ripper.lex"

# ---------------------------------------------------------------- threads
#
# Real ones: each Thread.new is pthread_create, which is __clone, which is a
# task in kernel/task.c with its own stack and its own copy of the TLS. Waiting
# -- join, Queue#pop, a contended Mutex, sleep -- is a futex, and Timeout is a
# second thread raising into the first, woken out of its condition variable.
begin
  values = 4.times.map { |i| Thread.new { i + 1 } }.map(&:value)
  puts "threads: #{values.length} joined #{values.inspect}"

  # More threads than the kernel has slots for, a few at a time: each one that
  # finishes has to give back its slot and its stack for this to get to the end.
  50.times { 4.times.map { Thread.new {} }.each(&:join) }
  puts "threads: 200 started and finished"

  queue = Queue.new
  producer = Thread.new do
    100.times { |i| queue << i }
    queue << nil
  end
  items = 0
  items += 1 while queue.pop
  producer.join
  puts "queue: #{items} items"

  mutex = Mutex.new
  total = 0
  4.times.map { Thread.new { 250.times { mutex.synchronize { total += 1 } } } }
   .each(&:join)
  puts "mutex: #{total}"

  # A thread that never makes a syscall. Without preemption it would keep the
  # CPU and the GVL for ever, and this sleep would never end: the tick has to
  # take the CPU from it so CRuby's timer thread can ask for the GVL back.
  spinner = Thread.new { loop {} }
  sleep 0.05
  spinner.kill
  spinner.join
  puts "preempt: a spinning thread gave way"

  require "timeout"
  begin
    Timeout.timeout(0.1) { sleep 1 }
    puts "timeout: did not fire"
  rescue Timeout::Error => e
    puts "timeout: #{e.class}"
  end
rescue Exception => e
  puts "threads failed: #{e.class}: #{e.message}"
  puts e.backtrace.first(8).join("\n") if e.backtrace
end

# ---------------------------------------------------------------- socket
#
# ext/socket is linked in and registered, but the kernel has no network yet.
# What is being checked here is the extension rather than the network: that the
# constant tables mkconstants.rb generated survived the cross compile, that
# require "socket" found socket.rb in the Ruby filesystem and defined Addrinfo
# on top of the C half, and that musl's getaddrinfo answers for a numeric
# address without a resolver.
#
# The last check is the interesting one. TCPServer.new has to fail, and it has
# to fail as Errno::ENOSYS -- an ordinary SystemCallError that Ruby code can
# rescue -- rather than as a crash or a hang. Until a NIC exists that is the
# correct behaviour, and it is worth asserting, because the alternative is a
# socket layer that looks present and is not.
begin
  require "socket"
  puts "socket: AF_INET #{Socket::AF_INET}, SOMAXCONN #{Socket::SOMAXCONN}"
  puts "socket: hostname #{Socket.gethostname}"
  puts "socket: Addrinfo #{Addrinfo.tcp("10.0.2.15", 80).inspect}"

  # WEBrick, on top of that. The listener is CRuby's own TCPServer --
  # WEBrick makes it through Socket.tcp_server_sockets -- and the accept loop is
  # WEBrick's: one select over the listeners and a shutdown pipe, a
  # non-blocking accept, and a thread per connection. Nothing in it is patched;
  # the threads are kernel tasks.
  #
  # It serves until somebody types something. A time limit was tried first and
  # was wrong: it made a server that could only be reached by a program fast
  # enough to catch the window, which is to say not by hand -- and a web server
  # nobody can visit is not one. But a blocking accept with no way out would
  # mean irb was only reachable on a machine with no network, so a thread
  # watches the console and a keystroke on it shuts the server down -- which is
  # how WEBrick expects to be stopped, from another thread, through its
  # shutdown pipe.
  require "webrick"

  # There is no resolver, so a reverse lookup of every peer would only be a
  # wait for an answer that cannot come.
  server = WEBrick::HTTPServer.new(BindAddress: "0.0.0.0", Port: 80,
                                   DoNotReverseLookup: true)
  server.mount_proc("/") do |_request, response|
    response.content_type = "text/plain"
    response.body = "hello from a Ruby kernel\n"
  end

  # Printed from inside start rather than before it, because that is when the
  # select is about to run; the tests knock as soon as they see this line.
  server.config[:StartCallback] = proc do
    address = server.listeners.first.local_address
    puts "http: serving on #{address.ip_address}:#{address.ip_port}, " \
         "press Enter for irb"
  end

  console = Thread.new do
    STDIN.wait_readable
    # Take the keystroke, so Reline does not find it waiting for it.
    begin
      STDIN.read_nonblock(64)
    rescue IO::WaitReadable, EOFError
    end
    server.shutdown
  end

  server.start
  console.join
  puts "http: stopped"
rescue Exception => e
  puts "socket failed: #{e.class}: #{e.message}"
  puts e.backtrace.first(8).join("\n") if e.backtrace
end

# ---------------------------------------------------------------- irb

# The far end of the serial port is a real terminal, and the kernel now
# implements enough of one -- termios, window size, a line discipline -- for
# Reline to drive it. TERM=dumb would make it give up before trying.
ENV["TERM"] = "vt100"

# There is one directory and no user database. Reline expands ~/.inputrc, and
# without HOME set CRuby falls back to looking the user up by uid and fails.
ENV["HOME"] = "/"
begin
  require "irb"
  puts "irb #{IRB::VERSION} loaded"

  # IRB.start would do setup and run in one step, but setup resets the
  # configuration from its defaults -- so anything set before it is discarded,
  # which is why history saving kept running after being switched off. Doing
  # the two halves separately leaves somewhere to put the settings.
  IRB.setup(nil)

  # No pager to page into, and no writable filesystem to save history on.
  IRB.conf[:USE_PAGER] = false
  IRB.conf[:SAVE_HISTORY] = false

  irb = IRB::Irb.new
  IRB.conf[:MAIN_CONTEXT] = irb.context
  irb.run(IRB.conf)
  puts "irb finished"
rescue Exception => e
  puts "irb failed: #{e.class}: #{e.message}"
  puts e.backtrace.first(8).join("\n") if e.backtrace
end
