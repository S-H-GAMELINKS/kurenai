# Build PicoRuby's mruby VM as a freestanding x86_64 static library to be
# linked into the kernel:
#
#   MRUBY_CONFIG=x86_64-bare-metal rake
#     -> build/x86_64-bare-metal/lib/libmruby.a
#
# This file is the tracked original. The build stage copies it into
# third_party/picoruby/build_config/, which is not tracked.

MUSL_INSTALL = File.expand_path("#{MRUBY_ROOT}/../musl/install")
CC_COMMAND = ENV["CC"] || "clang"
CLANG_RESOURCE_DIR = `#{CC_COMMAND} -print-resource-dir`.strip

MRuby::CrossBuild.new("x86_64-bare-metal") do |conf|
  conf.toolchain :gcc

  conf.cc.command       = CC_COMMAND
  conf.cxx.command      = CC_COMMAND
  conf.linker.command   = CC_COMMAND
  conf.archiver.command = ENV["AR"] || "llvm-ar"

  # Mirror the flags the kernel itself is built with, so every object in
  # libmruby.a stays ABI compatible with the rest of the image. -nostdinc plus
  # the two -isystem paths are what make the VM compile against musl's headers
  # rather than the host's; mixing the two produces a library that links but
  # crashes, because struct layouts disagree.
  freestanding = %W(
    -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -m64
    -nostdinc
    -isystem #{CLANG_RESOURCE_DIR}/include
    -isystem #{MUSL_INSTALL}/include
  )
  conf.cc.flags  = freestanding.dup
  conf.cxx.flags = freestanding.dup
  conf.cc.flags << "-Wall" << "-Wno-unused-parameter"

  # MRB_INT64 is not optional here. The syscall bridge carries 64-bit addresses
  # of CRuby buffers through Ruby Integers; with 32-bit integers they would be
  # truncated silently, corrupting memory rather than raising.
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  # Allocate from a pool the kernel hands over (mrb_open_with_custom_alloc)
  # instead of the libc allocator. Beyond being a bare-metal requirement, it
  # is what stops a PicoRuby-side allocation from reaching musl's malloc,
  # which would call back into the syscall dispatcher that PicoRuby itself
  # implements.
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"

  # No clock_gettime until the kernel provides one.
  conf.cc.defines << "NO_CLOCK_GETTIME=1"

  # NOTE:
  # MRB_NO_STDIO is deliberately not defined. picoruby-mruby's file_ext.c always
  # includes mruby/io.h, which #errors when MRB_NO_STDIO is set, and PicoRuby is
  # designed around stdio symbols existing and the console being redirected
  # through the platform HAL. musl supplies those symbols.
  conf.picoruby
end
