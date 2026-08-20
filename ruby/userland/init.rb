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
  # A server, with nothing above it. Plain CRuby, unmodified: the descriptor,
  # the bind, the listen, the accept and the wait are the Ruby kernel's, the TCP
  # is lwIP's, and the frames are carried by a driver written in Ruby.
  #
  # It runs for a couple of seconds and then gives way to irb, because a kernel
  # that stops at a blocking accept is a kernel that only boots when somebody
  # connects. WEBrick will take this over and keep it.
  #
  # IO.select is here rather than a bare accept on purpose. It lowers to
  # select(2) where accept lowers to poll, and WEBrick's own accept loop uses
  # select -- so the thing that has to work later is the thing being used here.
  server = TCPServer.new("0.0.0.0", 80)
  puts "http: listening on #{server.local_address.ip_address}:" \
       "#{server.local_address.ip_port}"

  body = "hello from a Ruby kernel\n"
  served = 0
  deadline = Time.now + 2

  while Time.now < deadline
    next unless IO.select([server], nil, nil, 0.2)

    client = server.accept
    request = client.gets.to_s.strip
    puts "http: #{request} from #{client.peeraddr[3]}"
    client.write("HTTP/1.1 200 OK\r\n" \
                 "Content-Type: text/plain\r\n" \
                 "Content-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{body}")
    client.close
    served += 1
  end

  server.close
  puts "http: served #{served} requests"
rescue Exception => e
  puts "socket failed: #{e.class}: #{e.message}"
  puts e.backtrace.first(8).join("\n") if e.backtrace
end

# ---------------------------------------------------------------- irb

# CRuby names its encoding constants from the encoding database, which is
# normally a dynamically loaded extension. kernel/enc.c declares the four
# built-in encodings but cannot create the constants, so they are made here
# from what is registered. Without them reline fails on Encoding::US_ASCII.
Encoding.list.each do |encoding|
  name = encoding.name.gsub("-", "_").gsub(".", "_")
  next if Encoding.const_defined?(name, false)
  begin
    Encoding.const_set(name, encoding)
  rescue NameError
    # Names that are not valid constants; nothing looks those up by constant.
  end
end

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
