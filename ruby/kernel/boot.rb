# What the kernel does once the machine is usable.
#
# Compiled to bytecode by picorbc and embedded in the image; there is no
# compiler in the kernel, so this file cannot be changed without rebuilding.

puts "picoruby vm ok"

# Enough Ruby to show the VM is genuinely running: a block, an integer method
# from mrblib, string interpolation and an array literal.
sum = 0
3.times { |i| sum += i }
puts "sum #{sum}"
puts [1, 2, 3].map { |n| n * n }.inspect

# Find out how much RAM there is and make it the arena. This has to happen
# before CRuby starts: its first mmap is the first thing that needs a page.
Kernel::Memory.init
puts "memory: arena #{Kernel::Memory.free_bytes / (1024 * 1024)} MB free"

# Build the filesystem table, then show what it holds. Doing this here rather
# than on first use keeps a failure at boot, where it is visible.
Kernel::VFS.build
puts "vfs: #{Kernel::VFS.paths.length} files"

# Find the network card, if the machine has one. Done here rather than on first
# use for the same reason the filesystem table is: a syscall handler is the
# wrong place to discover the hardware, and a failure at boot is visible.
Kernel::E1000.probe
Kernel::E1000.report

# One frame out and one frame in, with no protocol stack in between. This is
# the only check that covers the descriptor rings on their own, and the answer
# comes from another machine rather than from this one.
Kernel::ARP.report
