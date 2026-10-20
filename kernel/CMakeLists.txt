# The kernel itself.
#
# Configured by the superbuild as a child project so it can use the bare-metal
# toolchain file, the same one the CRuby cross library uses.
#
# The build has two halves because the machine starts in 32-bit protected mode
# and the kernel is 64-bit:
#
#   kernel64.elf  the kernel, linked at 2MB
#   kernel64.bin  the same, as a flat image
#   kernel.elf    the 32-bit Multiboot stub with kernel64.bin embedded in it
#
# Only the 64-bit half is an ordinary CMake target. The stub is built with
# explicit commands: it is a different ABI, and a CMake project has one
# toolchain, so expressing it as a target would mean a second child project for
# a single assembly file.

cmake_minimum_required(VERSION 3.25)
project(picoruby_kernel LANGUAGES C ASM)

foreach(v BOOT_DIR RUBY_DIR PICORBC PICORUBY_LIB PICORUBY_INCLUDE_DIRS MUSL_INSTALL
          CRUBY_LIB CRUBY_SRC PICORUBY_SRC LWIP_SRC GEMS_DIR WEBRICK_SRC MUI_SRC EMBED_SCRIPT EMBED_FILES)
  if(NOT ${v})
    message(FATAL_ERROR "kernel: -D${v}=... is required")
  endif()
endforeach()

find_program(LLD_EXECUTABLE ld.lld REQUIRED)

# Prints every routed syscall, its result, and any exception raised while
# servicing it. Off by default because it is written to the same console the
# system uses, but it is the only way to see what CRuby is asking for and what
# the Ruby kernel answered.
option(BRIDGE_TRACE "Trace syscalls routed to Ruby" OFF)


# ---------------------------------------------------------------- Ruby -> C
# picorbc emits the bytecode as a C array directly, so no separate embedding
# step is needed. The array lands in .rodata, inside the etext/edata range, and
# mruby therefore runs it in place instead of copying it to the heap.
set(BOOT_BYTECODE ${CMAKE_CURRENT_BINARY_DIR}/boot_bytecode.c)
add_custom_command(
  OUTPUT ${BOOT_BYTECODE}
  COMMAND ${PICORBC} -B kernel_bytecode -o ${BOOT_BYTECODE} ${RUBY_DIR}/kernel/boot.rb
  DEPENDS ${RUBY_DIR}/kernel/boot.rb ${PICORBC}
  COMMENT "Compiling ruby/kernel/boot.rb")

# The kernel's Ruby, compiled as one unit. Order matters: memory, vfs and fd
# have to be defined before syscall.rb refers to them.
set(KERNEL_RUBY
  ${RUBY_DIR}/kernel/memory.rb
  ${RUBY_DIR}/kernel/vfs.rb
  ${RUBY_DIR}/kernel/fd.rb
  ${RUBY_DIR}/kernel/tty.rb
  ${RUBY_DIR}/kernel/pci.rb
  ${RUBY_DIR}/kernel/e1000.rb
  ${RUBY_DIR}/kernel/arp.rb
  ${RUBY_DIR}/kernel/net.rb
  ${RUBY_DIR}/kernel/poll.rb
  ${RUBY_DIR}/kernel/sockets.rb
  ${RUBY_DIR}/kernel/syscall.rb)

set(SYSCALL_BYTECODE ${CMAKE_CURRENT_BINARY_DIR}/syscall_bytecode.c)
add_custom_command(
  OUTPUT ${SYSCALL_BYTECODE}
  COMMAND ${PICORBC} -B syscall_bytecode -o ${SYSCALL_BYTECODE} ${KERNEL_RUBY}
  DEPENDS ${KERNEL_RUBY} ${PICORBC}
  COMMENT "Compiling the kernel's Ruby")

# ---------------------------------------------------------------- embedded files
# The read-only filesystem, served by ruby/kernel/vfs.rb. Entries pair the path
# a file appears at with the file it comes from, so the layout CRuby sees is
# stated here rather than following the source tree.
#
# Ruby libraries are served at the root, and ruby/userland/init.rb puts "/" on
# the load path, so require works through the ordinary CRuby machinery: it
# calls stat, open and read, and the Ruby kernel answers.
set(EMBEDDED_ENTRIES "")
set(EMBEDDED_SOURCES "")

# Adds every listed file, keeping its path relative to root.
function(embed_under root)
  foreach(relative IN LISTS ARGN)
    list(APPEND EMBEDDED_ENTRIES "/${relative}=${root}/${relative}")
    list(APPEND EMBEDDED_SOURCES "${root}/${relative}")
  endforeach()
  set(EMBEDDED_ENTRIES "${EMBEDDED_ENTRIES}" PARENT_SCOPE)
  set(EMBEDDED_SOURCES "${EMBEDDED_SOURCES}" PARENT_SCOPE)
endfunction()

embed_under(${RUBY_DIR}/files hello.rb rbconfig.rb www/index.html)

# Ripper's Ruby half. The C half is already linked in and registered as
# ripper.so, which is what ripper/core.rb requires.
embed_under(${CRUBY_SRC}/ext/ripper/lib
  ripper.rb
  ripper/core.rb
  ripper/lexer.rb
  ripper/filter.rb
  ripper/sexp.rb)

# ext/socket's Ruby half, and it is not optional. require "socket" finds
# socket.so already registered by Init_ext, then goes on looking for socket.rb
# on the load path -- so without this file the require succeeds and Addrinfo,
# Socket.tcp_server_sockets and Socket.tcp are simply missing. WEBrick asks for
# all three.
embed_under(${CRUBY_SRC}/ext/socket/lib socket.rb)

# NOTE:
# Everything a gem or the standard library ships, found by globbing rather than
# listed. The argument against globs elsewhere is that a source list should say
# what the build compiles; here the right set is "whatever this version ships",
# the versions are pinned, and listing 90 files by hand would only be a way to
# get it wrong.
function(embed_all_ruby_under root)
  file(GLOB_RECURSE found RELATIVE ${root} ${root}/*.rb)
  list(SORT found)
  embed_under(${root} ${found})
  set(EMBEDDED_ENTRIES "${EMBEDDED_ENTRIES}" PARENT_SCOPE)
  set(EMBEDDED_SOURCES "${EMBEDDED_SOURCES}" PARENT_SCOPE)
endfunction()

# irb and reline whole, and the parts of the standard library they reach for.
#
# The standard library is filtered rather than embedded entire. Most of what
# CRuby ships exists to talk to a network, a package index or a filesystem this
# machine does not have, and it is a third of the image. What is left is what
# irb, reline and WEBrick actually require -- the last being why uri, erb and
# cgi/escape are in.
function(embed_ruby_under root)
  cmake_parse_arguments(A "" "" "EXCLUDE" ${ARGN})
  file(GLOB_RECURSE found RELATIVE ${root} ${root}/*.rb)
  list(SORT found)
  foreach(pattern IN LISTS A_EXCLUDE)
    list(FILTER found EXCLUDE REGEX "${pattern}")
  endforeach()
  embed_under(${root} ${found})
  set(EMBEDDED_ENTRIES "${EMBEDDED_ENTRIES}" PARENT_SCOPE)
  set(EMBEDDED_SOURCES "${EMBEDDED_SOURCES}" PARENT_SCOPE)
endfunction()

embed_ruby_under(${GEMS_DIR}/irb/lib)
embed_ruby_under(${GEMS_DIR}/reline/lib)

# WEBrick whole, and the Ruby halves of the extensions linked in for it. As with
# socket.rb, the C half being registered is not enough: require "digest" finds
# digest.so and then loads /digest.rb, which is where Digest() is defined, and
# require "date" is /date.rb requiring date_core.so rather than the other way
# round.
embed_all_ruby_under(${WEBRICK_SRC}/lib)

# mui, the editor irb opens the pages in. Its lib/ is all Ruby; the curses
# adapter comes along but is never loaded, because the ANSI one is used.
embed_all_ruby_under(${MUI_SRC}/lib)
embed_all_ruby_under(${CRUBY_SRC}/ext/date/lib)
embed_all_ruby_under(${CRUBY_SRC}/ext/digest/lib)
embed_all_ruby_under(${CRUBY_SRC}/ext/strscan/lib)

embed_ruby_under(${CRUBY_SRC}/lib EXCLUDE
  "^bundler"      # a package manager, with no packages and no network
  "^rubygems"     # likewise
  "^net/"         # clients; there is no connect(2) here
  "^resolv"
  "^open-uri"
  "^yaml"         # psych is a C extension that is not linked
  "^mkmf"         # builds extensions; there is no compiler here
  "^un\\.rb"
  "^ipaddr"
  "^find\\.rb")

set(EMBEDDED_MANIFEST ${CMAKE_CURRENT_BINARY_DIR}/embedded_manifest.txt)
string(REPLACE ";" "\n" EMBEDDED_MANIFEST_TEXT "${EMBEDDED_ENTRIES}")
file(WRITE ${EMBEDDED_MANIFEST} "${EMBEDDED_MANIFEST_TEXT}\n")

set(EMBEDDED_FILES_C ${CMAKE_CURRENT_BINARY_DIR}/embedded_files.c)
add_custom_command(
  OUTPUT ${EMBEDDED_FILES_C}
  COMMAND ${CMAKE_COMMAND}
          -DMANIFEST=${EMBEDDED_MANIFEST}
          -DOUTPUT=${EMBEDDED_FILES_C}
          -P ${EMBED_FILES}
  DEPENDS ${EMBEDDED_SOURCES} ${EMBEDDED_MANIFEST} ${EMBED_FILES}
  COMMENT "Embedding the read-only filesystem")

# ---------------------------------------------------------------- Ruby -> string
# The CRuby side has no bytecode compiler available at build time, and no
# filesystem to read from at run time, so its script is embedded as source and
# evaluated. A generated C file keeps the quoting in one place.
set(USERLAND_SCRIPT ${CMAKE_CURRENT_BINARY_DIR}/userland_script.c)
add_custom_command(
  OUTPUT ${USERLAND_SCRIPT}
  COMMAND ${CMAKE_COMMAND}
          -DINPUT=${RUBY_DIR}/userland/init.rb
          -DOUTPUT=${USERLAND_SCRIPT}
          -DSYMBOL=userland_script
          -P ${EMBED_SCRIPT}
  DEPENDS ${RUBY_DIR}/userland/init.rb ${EMBED_SCRIPT}
  COMMENT "Embedding ruby/userland/init.rb")

# ---------------------------------------------------------------- 64-bit kernel
# lwIP, compiled here rather than by a build of its own: it is a set of C files
# meant to be built with the embedder's flags against an lwipopts.h the embedder
# writes, and kernel/net/lwipopts.h is that file.
#
# Listed rather than globbed, for the reason the CRuby source list is: lwIP
# ships a great deal this machine has no use for, and a glob would pull in
# whichever of it appeared. What is left out is as deliberate as what is in --
# src/api is the socket and netconn layers, which NO_SYS has no threads for;
# src/apps is a web server, an MQTT client and more, none of which is wanted
# under a Ruby one; netif/ has SLIP, 6LoWPAN and a bridge; and ipv6 is off.
set(LWIP_SOURCES
  core/init.c core/def.c core/mem.c core/memp.c core/netif.c core/pbuf.c
  core/ip.c core/inet_chksum.c core/timeouts.c core/sys.c core/stats.c
  core/tcp.c core/tcp_in.c core/tcp_out.c core/udp.c core/raw.c core/dns.c
  core/altcp.c core/altcp_alloc.c core/altcp_tcp.c
  core/ipv4/ip4.c core/ipv4/ip4_addr.c core/ipv4/ip4_frag.c
  core/ipv4/etharp.c core/ipv4/icmp.c core/ipv4/dhcp.c core/ipv4/acd.c
  core/ipv4/igmp.c
  netif/ethernet.c)
list(TRANSFORM LWIP_SOURCES PREPEND "${LWIP_SRC}/src/")

# picoruby-socket's C port layer: the TCP server and socket state machines that
# sit on lwIP's raw API, written for PicoRuby and reused here. Its Ruby class
# layer is not built -- CRuby's ext/socket provides that, and the gem's version
# returns mruby Strings, where this kernel needs bytes to cross as addresses.
#
# Compiled here rather than as an mrbgem, which is how R2P2 does it too: the
# rake build only picks up ports/posix and ports/common, and only for a posix
# target, so ports/rp2040 has always been the embedder's job.
#
# PICORB_PLATFORM_LWIP has to be stated. The header would otherwise sniff
# __linux__ -- which clang defines even here -- and hand back the POSIX
# definition of picorb_socket_t while the lwIP one is what these files use.
set(PICORUBY_SOCKET_DIR ${PICORUBY_SRC}/mrbgems/picoruby-socket)
set(PICORUBY_SOCKET_SOURCES
  ${PICORUBY_SOCKET_DIR}/ports/rp2040/tcp_server.c
  ${PICORUBY_SOCKET_DIR}/ports/rp2040/tcp_socket.c
  ${PICORUBY_SOCKET_DIR}/ports/rp2040/udp_socket.c
  net/port.c)

set_source_files_properties(${PICORUBY_SOCKET_SOURCES} PROPERTIES
  COMPILE_DEFINITIONS "PICORB_PLATFORM_LWIP=1;PICORB_VM_MRUBY=1")

# NOTE:
# The chain of include paths is longer than it looks it should be because
# picoruby.h -- which these files want for picorb_alloc and picorb_free, and
# nothing else -- includes mruby-compiler2's headers, which include prism's.
# None of it is linked: the kernel runs precompiled bytecode and has no Ruby
# compiler in it. These are headers being read, not code being pulled in.
set(PICORUBY_SOCKET_INCLUDES
  ${PICORUBY_SOCKET_DIR}/include
  ${PICORUBY_SRC}/include
  ${PICORUBY_SRC}/mrbgems/mruby-compiler2/include
  ${PICORUBY_SRC}/mrbgems/mruby-compiler2/lib/prism/include
  ${PICORUBY_SRC}/mrbgems/picoruby-mruby/include
  ${PICORUBY_INCLUDE_DIRS}
  ${LWIP_SRC}/src/include
  ${CMAKE_CURRENT_SOURCE_DIR}/net)

set_source_files_properties(${PICORUBY_SOCKET_SOURCES} net.c PROPERTIES
  INCLUDE_DIRECTORIES "${PICORUBY_SOCKET_INCLUDES}")

# net.c reaches the port layer's API, so it needs the same platform selection.
set_source_files_properties(net.c PROPERTIES
  COMPILE_DEFINITIONS "PICORB_PLATFORM_LWIP=1;PICORB_VM_MRUBY=1")

add_executable(kernel64.elf
  entry64.S
  isr.S
  switch.S
  idt.c
  irq.c
  main.c
  serial.c
  vm.c
  hal.c
  syscall.c
  task.c
  libc_init.c
  timer.c
  musl_stubs.c
  memory.c
  enc.c
  cruby.c
  bridge.c
  net.c
  ${LWIP_SOURCES}
  ${PICORUBY_SOCKET_SOURCES}
  ${BOOT_BYTECODE}
  ${SYSCALL_BYTECODE}
  ${EMBEDDED_FILES_C}
  ${USERLAND_SCRIPT})

target_include_directories(kernel64.elf PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/net      # lwipopts.h, which lwIP includes by name
  ${LWIP_SRC}/src/include
  ${PICORUBY_INCLUDE_DIRS})

# NOTE:
# These have to match picoruby_build/x86_64-bare-metal.rb exactly. They change
# the layout of mrb_value and mrb_int, so a mismatch links cleanly and then
# misbehaves at run time: the kernel and the library disagree about what a
# Ruby object is, and every type check reads the wrong bytes. vm.c carries a
# static assertion so the next mismatch is a compile error instead.
if(BRIDGE_TRACE)
  target_compile_definitions(kernel64.elf PRIVATE BRIDGE_TRACE)
endif()

target_compile_definitions(kernel64.elf PRIVATE
  MRB_INT64
  MRB_NO_BOXING
  MRB_UTF8_STRING
  PICORB_ALLOC_ESTALLOC
  PICORB_ALLOC_ALIGN=8
  NO_CLOCK_GETTIME=1)

# NOTE:
# The full musl, not the stripped one. The VM allocates from its own pool, but
# musl's stdio still wants an allocator underneath it, and nothing in this
# kernel provides one yet. The stripped flavour becomes the right choice when
# CRuby arrives with its own.
# NOTE:
# The full musl, not the stripped flavour. Keeping musl's allocator is a
# deliberate choice: a bump allocator that never reuses memory is adequate for
# running a script once and fatal for a REPL, where every keystroke allocates.
# mallocng frees properly, and the kernel only has to supply pages beneath it.
#
# compiler-rt supplies the 128-bit division helpers CRuby's bignum code calls.
# Writing them by hand would be a needless reimplementation of the compiler's
# own runtime.
execute_process(COMMAND ${CMAKE_C_COMPILER} --rtlib=compiler-rt -print-libgcc-file-name
                OUTPUT_VARIABLE COMPILER_RT_BUILTINS
                OUTPUT_STRIP_TRAILING_WHITESPACE
                COMMAND_ERROR_IS_FATAL ANY)
if(NOT EXISTS ${COMPILER_RT_BUILTINS})
  message(FATAL_ERROR "compiler-rt builtins not found at ${COMPILER_RT_BUILTINS}")
endif()

target_link_libraries(kernel64.elf PRIVATE
  ${CRUBY_LIB}
  ${PICORUBY_LIB}
  ${MUSL_INSTALL}/lib/libc.a
  ${COMPILER_RT_BUILTINS})

target_link_options(kernel64.elf PRIVATE
  -nostdlib
  -static
  -fuse-ld=lld
  -Wl,-T,${CMAKE_CURRENT_SOURCE_DIR}/kernel64.ld
  # A build id would land in an allocated section and end up in the flat image.
  -Wl,--build-id=none)

set_target_properties(kernel64.elf PROPERTIES
  LINK_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/kernel64.ld)

# ---------------------------------------------------------------- flat image
# There is no loader on the other side, so program headers are of no use; the
# stub embeds the raw bytes and jumps to the first one.
add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/kernel64.bin
  COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:kernel64.elf>
          ${CMAKE_CURRENT_BINARY_DIR}/kernel64.bin
  DEPENDS kernel64.elf
  COMMENT "Flattening kernel64.elf")

# ---------------------------------------------------------------- 32-bit stub
# boot.S resolves "kernel64.bin" through the assembler's include path, which is
# why -I points at the build directory rather than the name being passed as a
# macro. Quoting a path through a preprocessor define survives neither CMake
# nor the shell reliably.
add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/boot.o
  COMMAND ${CMAKE_C_COMPILER} -m32 -c ${BOOT_DIR}/boot.S
          -I${CMAKE_CURRENT_BINARY_DIR}
          -o ${CMAKE_CURRENT_BINARY_DIR}/boot.o
  DEPENDS ${BOOT_DIR}/boot.S ${CMAKE_CURRENT_BINARY_DIR}/kernel64.bin
  COMMENT "Assembling the 32-bit Multiboot stub")

add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/kernel.elf
  COMMAND ${LLD_EXECUTABLE} -nostdlib -m elf_i386
          -z max-page-size=0x1000
          -T ${BOOT_DIR}/multiboot.ld
          -o ${CMAKE_CURRENT_BINARY_DIR}/kernel.elf
          ${CMAKE_CURRENT_BINARY_DIR}/boot.o
  DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/boot.o ${BOOT_DIR}/multiboot.ld
  COMMENT "Linking the bootable image")

add_custom_target(kernel ALL DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/kernel.elf)
