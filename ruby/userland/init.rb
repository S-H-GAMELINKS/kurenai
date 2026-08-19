# The first Ruby that runs on top of CRuby.
#
# Embedded in the image as a string and evaluated at boot. There is no
# filesystem yet, so this is how userland code gets in.

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
