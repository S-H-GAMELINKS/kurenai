# A file with no filesystem under it.
#
# Embedded in the kernel image and served by ruby/kernel/vfs.rb. When CRuby
# reads this, every step between File.read and the bytes arriving is Ruby
# running in the other VM.
puts "hello from a file served by the Ruby kernel"
