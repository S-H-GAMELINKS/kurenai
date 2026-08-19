# The first Ruby that runs on top of CRuby.
#
# Embedded in the image as a string and evaluated at boot. There is no
# filesystem CRuby can require from yet, so this is how userland code gets in.

# Nothing here is a terminal as far as the kernel is concerned, so CRuby block
# buffers its output. A prompt that appears after the answer is not a prompt.
STDOUT.sync = true

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

# The two extensions irb depends on, linked into the image and registered by
# Init_ext rather than loaded from disk. Checking them here rather than
# discovering it inside irb, where the failure would be much harder to read.
require "io/console"
require "ripper"
puts "io/console: IO#raw #{IO.method_defined?(:raw)}"
# The C half of Ripper is linked in and registered. Its Ruby half --
# Ripper.lex, Ripper::Lexer, Ripper.sexp -- lives in ext/ripper/lib and is not
# embedded yet, so those are still missing. irb's RubyLex needs them, which
# makes a working require the next thing to build.
puts "ripper: #{defined?(Ripper) ? "class present" : "missing"}, " \
     "Ripper.lex #{Ripper.respond_to?(:lex) ? "available" : "not embedded yet"}"

# ---------------------------------------------------------------- the REPL
#
# Deliberately small. irb is the goal, and this exists to settle everything
# underneath it first: that a blocking read on the console returns a line, that
# the line discipline in the Ruby kernel turns Return into something gets will
# accept, and that eval and the exception path work. Whatever breaks here would
# break inside irb, where it would be much harder to see.

def repl
  puts
  puts "picoruby-kernel repl -- 'exit' to leave"

  loop do
    print "> "
    line = STDIN.gets
    break if line.nil?

    line = line.chomp
    next if line.empty?
    break if line == "exit"

    begin
      puts "=> #{eval(line, TOPLEVEL_BINDING).inspect}"
    rescue SyntaxError, StandardError => e
      puts "#{e.class}: #{e.message}"
    end
  end

  puts "repl done"
end

repl
