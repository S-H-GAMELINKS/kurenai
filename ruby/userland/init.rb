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

ENV["TERM"] = "dumb"
begin
  require "irb"
  puts "irb #{IRB::VERSION} loaded"

  # No pager to page into, no filesystem to save history on, and completion
  # left off until the terminal is a terminal.
  IRB.conf[:USE_PAGER] = false
  IRB.conf[:SAVE_HISTORY] = nil
  IRB.conf[:USE_AUTOCOMPLETE] = false

  IRB.start
  puts "irb finished"
rescue Exception => e
  puts "irb failed: #{e.class}: #{e.message}"
  puts e.backtrace.first(8).join("\n") if e.backtrace
end
