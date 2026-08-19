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
