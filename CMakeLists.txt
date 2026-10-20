# NOTE:
# 3.25 is required by CMakePresets.json ("version": 6, needed for
# workflowPresets) and by the helper scripts under cmake/. Keep all three in
# sync: if this line is lowered, users on older CMake pass this check and then
# fail somewhere far less obvious.
cmake_minimum_required(VERSION 3.25.0)

# NOTE:
# LANGUAGES NONE keeps CMake from looking for a C compiler and running its
# try_compile check. Nothing is compiled at this layer, and it also keeps the
# freestanding toolchain question out of the superbuild: compiling is the
# responsibility of the child project added later.
project(picoruby_kernel_superbuild LANGUAGES NONE)

include(ExternalProject)
include(ProcessorCount)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/versions.cmake)

# NOTE:
# Resolved here rather than inside each step so a missing tool is a configure
# error naming the tool, not a build error deep inside a dependency.
find_package(Git REQUIRED)
find_program(CLANG_EXECUTABLE clang REQUIRED)
find_program(LLVM_AR_EXECUTABLE llvm-ar REQUIRED)
find_program(LLVM_RANLIB_EXECUTABLE llvm-ranlib REQUIRED)
find_program(LLVM_NM_EXECUTABLE llvm-nm REQUIRED)
find_program(LLVM_READELF_EXECUTABLE llvm-readelf REQUIRED)
find_program(LLVM_OBJDUMP_EXECUTABLE llvm-objdump REQUIRED)
find_program(MAKE_EXECUTABLE make REQUIRED)
find_program(RAKE_EXECUTABLE rake REQUIRED)  # PicoRuby and mruby build with rake
find_program(RUBY_EXECUTABLE ruby REQUIRED)  # BASERUBY for CRuby's code generators
# Optional: only the run target and the boot test need it, and neither is worth
# blocking a build over.
find_program(QEMU_EXECUTABLE qemu-system-x86_64)
find_program(AUTORECONF_EXECUTABLE autoreconf REQUIRED)  # CRuby ships no configure

# NOTE:
# "cmake --build --parallel" does not reach the make/rake invocations inside an
# ExternalProject, so the job count has to be passed down explicitly.
ProcessorCount(NPROC)
if(NPROC EQUAL 0)
  set(NPROC 1)
endif()

# NOTE:
# Collect the ExternalProject bookkeeping (stamp/, tmp/, log/) under one
# directory in the build tree. Without EP_BASE it is scattered per project.
# To re-run a single step, delete its stamp file, for example:
#   build/dev/ep/Stamp/picoruby/picoruby-download
set_property(DIRECTORY PROPERTY EP_BASE ${CMAKE_BINARY_DIR}/ep)

# NOTE:
# Sources live in third_party/ rather than under build/.
#   pro: "rm -rf build" does not force a re-download (CRuby alone is ~127MB)
#   con: it breaks the "everything generated lives in build/" rule
# third_party/ is listed in .gitignore.
set(TP ${CMAKE_SOURCE_DIR}/third_party)
set(DEPS_DIR ${CMAKE_CURRENT_LIST_DIR}/cmake/deps)

# NOTE:
# Every dependency is fetched through cmake/deps/fetch_sha.cmake rather than
# ExternalProject's own GIT_REPOSITORY, for three reasons:
#
#   1. A pinned full SHA cannot be combined with GIT_SHALLOW. The generated
#      clone script runs "git clone --depth 1 --no-single-branch" followed by
#      "git checkout <GIT_TAG>", and an arbitrary commit is not in that set.
#   2. The generated clone script runs "rm -rf <SOURCE_DIR>" whenever its stamp
#      is missing, so "rm -rf build" would re-download ~250MB. fetch_sha.cmake
#      keeps the existing checkout and skips the network when the commit is
#      already present.
#   3. The generated clone script runs "git submodule update --recursive --init",
#      which for PicoRuby would drag in pico-sdk, pico-extras and rp2040js.
#
# fetch_sha.cmake is idempotent by construction: it always resets to REF.
#
# Only the acquisition steps are defined here. Build steps are added later.

# ---------------------------------------------------------------- musl
# NOTE:
# patches/musl.patch replaces arch/x86_64/syscall_arch.h so that musl calls
# kernel_syscall() instead of issuing the syscall instruction, which would fault
# in ring0. It also drops the vDSO defines, since there is no auxv to resolve
# __vdso_clock_gettime from. This takes libc.a from 511 syscall instructions
# down to 8, all in hand-written assembly on paths this kernel does not take.
#
# Two libc flavours come out of this stage; see cmake/deps/musl_strip_objects.cmake.
ExternalProject_Add(musl
  SOURCE_DIR ${TP}/musl

  DOWNLOAD_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/musl -DURL=${MUSL_URL} -DREF=${MUSL_REF}
      -P ${DEPS_DIR}/fetch_sha.cmake

  UPDATE_COMMAND ""  # the ref is pinned, so never re-fetch; works offline

  PATCH_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/musl -DPATCH=${CMAKE_SOURCE_DIR}/patches/musl.patch
      -P ${DEPS_DIR}/apply_patch.cmake

  # musl's configure only supports building in the source tree.
  BUILD_IN_SOURCE 1
  CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env
      CC=${CLANG_EXECUTABLE} AR=${LLVM_AR_EXECUTABLE} RANLIB=${LLVM_RANLIB_EXECUTABLE}
      ./configure --target=x86_64 --prefix=<SOURCE_DIR>/install
                  --disable-shared --enable-static
  BUILD_COMMAND ${MAKE_EXECUTABLE} -j${NPROC}
  INSTALL_COMMAND ${MAKE_EXECUTABLE} install
          COMMAND ${CMAKE_COMMAND}
              -DDIR=<SOURCE_DIR> -DLLVM_AR=${LLVM_AR_EXECUTABLE}
              -P ${DEPS_DIR}/musl_strip_objects.cmake

  BUILD_BYPRODUCTS ${TP}/musl/install/lib/libc.a ${TP}/musl/lib/libc_kernel.a

  USES_TERMINAL_DOWNLOAD  ON  # stream progress; without it a long step looks hung
  USES_TERMINAL_PATCH     ON
  USES_TERMINAL_CONFIGURE ON
  USES_TERMINAL_BUILD     ON
  USES_TERMINAL_INSTALL   ON
  STEP_TARGETS download patch configure build install  # cmake --build build/dev -t musl-build
)

# ---------------------------------------------------------------- CRuby (host)
# NOTE:
# This stage builds the host miniruby, which is CRuby's own code generator, and
# then generates the Ripper sources with it. Both are inputs to the cross build
# rather than anything that ends up in the kernel.
#
# Extensions are switched off: the host side only has to generate code, and the
# extensions the kernel needs (io/console, ripper) are compiled later, into the
# cross library.
#
# This is the stage that demonstrates the toolchain claim. parse.c comes from
# Lrama, which is vendored in the CRuby tree as pure Ruby, and lex.c is copied
# from the checked-in lex.c.blt, so neither bison nor gperf is required.
set(CRUBY_HOST_DIR ${TP}/cruby/build_host)
set(MINIRUBY       ${CRUBY_HOST_DIR}/miniruby)

ExternalProject_Add(cruby
  SOURCE_DIR ${TP}/cruby
  BINARY_DIR ${CRUBY_HOST_DIR}

  DOWNLOAD_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/cruby -DURL=${CRUBY_URL} -DREF=${CRUBY_REF}
      -P ${DEPS_DIR}/fetch_sha.cmake

  UPDATE_COMMAND ""

  # NOTE:
  # Two changes CRuby needs to run without an OS underneath: builtin function
  # lookup has to tolerate a missing table, and thread stack discovery has to
  # be replaced with the fixed stack the linker script provides.
  PATCH_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/cruby -DPATCH=${CMAKE_SOURCE_DIR}/patches/cruby.patch
      -P ${DEPS_DIR}/apply_patch.cmake

  # autogen.sh derives the source directory from its own path, so running it
  # from the build directory is fine; it writes configure into the source tree.
  CONFIGURE_COMMAND <SOURCE_DIR>/autogen.sh
          COMMAND ${CMAKE_COMMAND} -E env CC=${CLANG_EXECUTABLE}
              <SOURCE_DIR>/configure
                  --disable-rubygems --disable-dln --disable-install-doc
                  --disable-yjit --disable-zjit --disable-shared
                  --with-ext= --with-out-ext=*

  BUILD_COMMAND ${MAKE_EXECUTABLE} miniruby -j${NPROC}
        COMMAND ${MAKE_EXECUTABLE} builtin_binary.rbbin

  # Sources the cross build needs and the CRuby tree does not ship: ripper's
  # parser, and ext/socket's constant tables.
  INSTALL_COMMAND ${CMAKE_COMMAND}
      -DSRC=<SOURCE_DIR> -DRUBY=${RUBY_EXECUTABLE}
      -P ${DEPS_DIR}/cruby_generate_ripper.cmake
      COMMAND ${CMAKE_COMMAND}
      -DSRC=<SOURCE_DIR> -DRUBY=${RUBY_EXECUTABLE}
      -P ${DEPS_DIR}/cruby_generate_socket.cmake

  BUILD_BYPRODUCTS ${MINIRUBY}
                   ${CRUBY_HOST_DIR}/parse.c
                   ${CRUBY_HOST_DIR}/lex.c
                   ${TP}/cruby/ext/ripper/ripper.c
                   ${TP}/cruby/ext/ripper/ripper_init.c
                   ${TP}/cruby/ext/socket/constdefs.h
                   ${TP}/cruby/ext/socket/constdefs.c

  USES_TERMINAL_DOWNLOAD  ON
  USES_TERMINAL_PATCH     ON
  USES_TERMINAL_CONFIGURE ON
  USES_TERMINAL_BUILD     ON
  USES_TERMINAL_INSTALL   ON
  STEP_TARGETS download patch configure build install
)

# ---------------------------------------------------------------- OpenSSL
# libcrypto and libssl, cross-compiled against musl with the same flags as
# everything else in the image, for CRuby's ext/openssl to link against.
#
# OpenSSL builds with its own Configure and make, so it is driven like musl
# rather than given a CMakeLists. Out of tree, so the source stays as fetched.
# Only the libraries are built: no apps, no tests, no docs.
#
# The options are what a kernel with no dynamic loader, no shared memory and no
# ucontext can support, and each removes something that would otherwise be
# reached for at run time:
#
#   no-shared no-pic no-dso no-module no-engine   one static image, no dlopen
#   no-async          ASYNC jobs switch stacks with makecontext
#   no-secure-memory  the secure heap wants mlock and guard pages
#   no-afalgeng no-ktls  Linux kernel crypto and kernel TLS
#   no-ui-console     reads passwords from /dev/tty
#   no-asm            the C implementations; CR4.OSXSAVE is never set here,
#                     so the AVX paths would not be taken anyway
#
# Threads stay on: pthreads are kernel tasks, and CRuby takes the GVL around
# every call regardless. The seed source is the OS, which is getrandom, which is
# RDSEED (kernel/random.c). OPENSSLDIR is /etc/ssl, so X509_STORE's default
# paths find the CA bundle the kernel embeds at /etc/ssl/cert.pem.
set(OPENSSL_BUILD_DIR ${CMAKE_BINARY_DIR}/openssl)
set(OPENSSL_LIBS ${OPENSSL_BUILD_DIR}/libssl.a ${OPENSSL_BUILD_DIR}/libcrypto.a)

execute_process(COMMAND ${CLANG_EXECUTABLE} -print-resource-dir
                OUTPUT_VARIABLE CLANG_RESOURCE_DIR
                OUTPUT_STRIP_TRAILING_WHITESPACE
                COMMAND_ERROR_IS_FATAL ANY)

# The same as BARE_METAL_FLAGS in cmake/toolchain-x86_64-bare-metal.cmake,
# which this cannot include: it is a toolchain file, and OpenSSL is not a CMake
# project.
set(OPENSSL_CFLAGS
    "-O2 -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -m64 -nostdinc -isystem ${CLANG_RESOURCE_DIR}/include -isystem ${TP}/musl/install/include")

find_program(PERL_EXECUTABLE perl REQUIRED)  # OpenSSL's Configure is Perl

ExternalProject_Add(openssl
  SOURCE_DIR ${TP}/openssl
  BINARY_DIR ${OPENSSL_BUILD_DIR}
  DEPENDS musl

  DOWNLOAD_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/openssl -DURL=${OPENSSL_URL} -DREF=${OPENSSL_REF}
      -P ${DEPS_DIR}/fetch_sha.cmake

  UPDATE_COMMAND ""
  PATCH_COMMAND ""
  CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env
      CC=${CLANG_EXECUTABLE} AR=${LLVM_AR_EXECUTABLE} RANLIB=${LLVM_RANLIB_EXECUTABLE}
      ${PERL_EXECUTABLE} <SOURCE_DIR>/Configure linux-x86_64
      no-shared no-pic no-dso no-module no-engine no-async no-secure-memory
      no-afalgeng no-ktls no-ui-console no-comp no-asm
      no-apps no-tests no-docs
      --openssldir=/etc/ssl --with-rand-seed=os
      "CFLAGS=${OPENSSL_CFLAGS}"
  BUILD_COMMAND ${MAKE_EXECUTABLE} -j${NPROC} build_libs
  INSTALL_COMMAND ""

  BUILD_BYPRODUCTS ${OPENSSL_LIBS}

  USES_TERMINAL_DOWNLOAD  ON
  USES_TERMINAL_CONFIGURE ON
  USES_TERMINAL_BUILD     ON
  STEP_TARGETS download configure build
)

# ---------------------------------------------------------------- CA bundle
# What OpenSSL checks a server's certificate chain against. Download only; the
# kernel embeds it at /etc/ssl/cert.pem.
set(CACERT_FILE ${TP}/cacert/cacert.pem)

ExternalProject_Add(cacert
  URL ${CACERT_URL}
  URL_HASH SHA256=${CACERT_SHA256}
  DOWNLOAD_DIR ${TP}/cacert
  DOWNLOAD_NAME cacert.pem
  DOWNLOAD_NO_EXTRACT TRUE
  SOURCE_DIR ${TP}/cacert/source
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ""
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS ${CACERT_FILE}
)

# ---------------------------------------------------------------- CRuby (cross)
# NOTE:
# This one is a child CMake project rather than a wrapped foreign build, so it
# can use the bare-metal toolchain file and be written as ordinary CMake. It has
# to be an ExternalProject for the same reason everything else here is: the
# libraries and generated sources it consumes do not exist at configure time.
set(CRUBY_CROSS_DIR ${CMAKE_BINARY_DIR}/cruby_cross)
set(CRUBY_LIB       ${CRUBY_CROSS_DIR}/libruby-static.a)

ExternalProject_Add(cruby_cross
  SOURCE_DIR ${CMAKE_SOURCE_DIR}/cruby_build
  BINARY_DIR ${CRUBY_CROSS_DIR}
  DEPENDS cruby musl openssl

  DOWNLOAD_COMMAND ""
  UPDATE_COMMAND   ""
  INSTALL_COMMAND  ""

  CMAKE_ARGS
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_SOURCE_DIR}/cmake/toolchain-x86_64-bare-metal.cmake
    -DMUSL_INSTALL=${TP}/musl/install
    -DCRUBY_SRC=${TP}/cruby
    -DOPENSSL_SRC=${TP}/openssl
    -DOPENSSL_BUILD=${OPENSSL_BUILD_DIR}
    -DGEMS_DIR=${GEMS_DIR}
    -DCRUBY_HOST_BUILD=${CRUBY_HOST_DIR}
    -DCMAKE_BUILD_TYPE=Release

  BUILD_BYPRODUCTS ${CRUBY_LIB}

  # NOTE:
  # ExternalProject cannot see into a child project, so edits to
  # cruby_build/CMakeLists.txt or its sources leave the build stamp looking
  # current and the change silently does not get built. Always entering the
  # child build fixes that; the child is Ninja and no-ops in well under a
  # second when nothing changed.
  BUILD_ALWAYS ON

  USES_TERMINAL_CONFIGURE ON
  USES_TERMINAL_BUILD     ON
  STEP_TARGETS configure build
)

# ---------------------------------------------------------------- PicoRuby
# NOTE:
# Two rake invocations are needed and neither subsumes the other: the picorbc
# config builds the host compiler, and the x86_64-bare-metal config builds the
# freestanding VM library but no binaries.
#
# The cross build compiles against musl's headers, hence DEPENDS musl.
set(PICORUBY_LIB ${TP}/picoruby/build/x86_64-bare-metal/lib/libmruby.a)
set(PICORBC      ${TP}/picoruby/bin/picorbc)
# Both the VM headers and the presym tables generated for this build config.
set(PICORUBY_INCLUDE_DIRS
    ${TP}/picoruby/mrbgems/picoruby-mruby/lib/mruby/include
    ${TP}/picoruby/include
    ${TP}/picoruby/build/x86_64-bare-metal/include
    ${TP}/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/include)
string(REPLACE ";" "|" PICORUBY_INCLUDE_DIRS_ARG "${PICORUBY_INCLUDE_DIRS}")

ExternalProject_Add(picoruby
  SOURCE_DIR ${TP}/picoruby
  DEPENDS musl

  DOWNLOAD_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/picoruby -DURL=${PICORUBY_URL} -DREF=${PICORUBY_REF}
      -P ${DEPS_DIR}/fetch_sha.cmake

  # NOTE:
  # Submodule initialization is part of acquiring the source, so it goes in the
  # patch step: CMake runs patch right after download and before configure.
  #
  # The patch is to picoruby-socket, whose C port layer the kernel compiles
  # directly -- see kernel/CMakeLists.txt. It is not built as an mrbgem: the
  # rake build only compiles ports/posix and ports/common, and only for a posix
  # target, which is why R2P2 compiles ports/rp2040 from its own CMake too.
  PATCH_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/picoruby -P ${DEPS_DIR}/picoruby_submodules.cmake
      COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/picoruby -DPATCH=${CMAKE_SOURCE_DIR}/patches/picoruby-socket.patch
      -P ${DEPS_DIR}/apply_patch.cmake

  UPDATE_COMMAND ""

  # mruby's build system only looks for build configs inside its own tree, so
  # the tracked original is copied in rather than referenced in place.
  BUILD_IN_SOURCE 1
  CONFIGURE_COMMAND ${CMAKE_COMMAND} -E copy_if_different
      ${CMAKE_SOURCE_DIR}/picoruby_build/x86_64-bare-metal.rb
      <SOURCE_DIR>/build_config/x86_64-bare-metal.rb

  BUILD_COMMAND ${CMAKE_COMMAND} -E env
          MRUBY_CONFIG=picorbc CC=${CLANG_EXECUTABLE} AR=${LLVM_AR_EXECUTABLE}
          ${RAKE_EXECUTABLE} -j${NPROC}
        COMMAND ${CMAKE_COMMAND} -E env
          MRUBY_CONFIG=x86_64-bare-metal CC=${CLANG_EXECUTABLE} AR=${LLVM_AR_EXECUTABLE}
          ${RAKE_EXECUTABLE} -j${NPROC}

  INSTALL_COMMAND ${CMAKE_COMMAND}
      -DARCHIVE=${PICORUBY_LIB} -DLLVM_AR=${LLVM_AR_EXECUTABLE}
      -P ${DEPS_DIR}/picoruby_strip_allocf.cmake

  BUILD_BYPRODUCTS ${PICORUBY_LIB} ${PICORBC}

  USES_TERMINAL_DOWNLOAD  ON
  USES_TERMINAL_PATCH     ON
  USES_TERMINAL_CONFIGURE ON
  USES_TERMINAL_BUILD     ON
  USES_TERMINAL_INSTALL   ON
  STEP_TARGETS download patch configure build install
)

# ---------------------------------------------------------------- lwIP
#
# Download only. lwIP has no configure and no build of its own worth using
# here: it is a set of C files that expect to be compiled with the flags of
# whatever is embedding them, against an lwipopts.h the embedder writes. So the
# kernel compiles it, and this stage exists to put the source where it can.
ExternalProject_Add(lwip
  SOURCE_DIR ${TP}/lwip

  DOWNLOAD_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/lwip -DURL=${LWIP_URL} -DREF=${LWIP_REF}
      -P ${DEPS_DIR}/fetch_sha.cmake

  UPDATE_COMMAND ""
  PATCH_COMMAND ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ""
  INSTALL_COMMAND ""

  USES_TERMINAL_DOWNLOAD ON
  STEP_TARGETS download
)

# ---------------------------------------------------------------- termfront
# Download only, like lwIP: it is pure Ruby, and the kernel embeds its lib/ and
# mission data into the filesystem. TERMFRONT_SOURCE_URL is where it comes
# from, the GitHub repository unless set: pointing it at a local clone builds
# against a commit that has not been pushed yet. The SHA is pinned either way.
set(TERMFRONT_SOURCE_URL ${TERMFRONT_URL} CACHE STRING "Where to fetch termfront from")

ExternalProject_Add(termfront
  SOURCE_DIR ${TP}/termfront

  DOWNLOAD_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/termfront -DURL=${TERMFRONT_SOURCE_URL} -DREF=${TERMFRONT_REF}
      -P ${DEPS_DIR}/fetch_sha.cmake

  UPDATE_COMMAND ""
  PATCH_COMMAND ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ""
  INSTALL_COMMAND ""

  USES_TERMINAL_DOWNLOAD ON
  STEP_TARGETS download
)

# ---------------------------------------------------------------- bundled gems
# NOTE:
# irb and reline ship as bundled gems rather than in the CRuby tree, so they
# are fetched at the versions gems/bundled_gems names. This is the one stage
# that reaches the network for something other than a git repository.
set(GEMS_DIR ${TP}/gems)
find_program(GEM_EXECUTABLE gem REQUIRED)


ExternalProject_Add(gems
  SOURCE_DIR ${GEMS_DIR}
  DEPENDS cruby

  DOWNLOAD_COMMAND ${CMAKE_COMMAND}
      -DBUNDLED_GEMS=${TP}/cruby/gems/bundled_gems
      -DDEST=${GEMS_DIR}
      -DGEM=${GEM_EXECUTABLE}
      -DNAMES=irb,reline
      -P ${DEPS_DIR}/fetch_gems.cmake

  UPDATE_COMMAND    ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND     ""
  INSTALL_COMMAND   ""
  USES_TERMINAL_DOWNLOAD ON
  STEP_TARGETS download
)

# ---------------------------------------------------------------- kernel
set(KERNEL_DIR   ${CMAKE_BINARY_DIR}/kernel)
set(KERNEL_ELF   ${KERNEL_DIR}/kernel.elf)
set(KERNEL64_ELF ${KERNEL_DIR}/kernel64.elf)

ExternalProject_Add(kernel
  SOURCE_DIR ${CMAKE_SOURCE_DIR}/kernel
  BINARY_DIR ${KERNEL_DIR}
  DEPENDS musl picoruby cruby_cross gems lwip termfront cacert

  DOWNLOAD_COMMAND ""
  UPDATE_COMMAND   ""
  INSTALL_COMMAND  ""

  # NOTE:
  # A CMake list reaching a child project through CMAKE_ARGS loses its
  # semicolons, so the whole list arrives as one path. LIST_SEPARATOR names a
  # stand-in that ExternalProject converts back on the way in.
  LIST_SEPARATOR |

  CMAKE_ARGS
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_SOURCE_DIR}/cmake/toolchain-x86_64-bare-metal.cmake
    -DMUSL_INSTALL=${TP}/musl/install
    -DBOOT_DIR=${CMAKE_SOURCE_DIR}/boot
    -DRUBY_DIR=${CMAKE_SOURCE_DIR}/ruby
    -DPICORBC=${PICORBC}
    -DPICORUBY_LIB=${PICORUBY_LIB}
    -DPICORUBY_INCLUDE_DIRS=${PICORUBY_INCLUDE_DIRS_ARG}
    -DCRUBY_LIB=${CRUBY_LIB}
    -DEMBED_SCRIPT=${DEPS_DIR}/embed_script.cmake
    -DEMBED_FILES=${DEPS_DIR}/embed_files.cmake
    -DCRUBY_SRC=${TP}/cruby
    -DLWIP_SRC=${TP}/lwip
    -DPICORUBY_SRC=${TP}/picoruby
    -DGEMS_DIR=${GEMS_DIR}
    -DTERMFRONT_SRC=${TP}/termfront
    -DCACERT_FILE=${CACERT_FILE}
    -DOPENSSL_BUILD=${OPENSSL_BUILD_DIR}
    -DCMAKE_BUILD_TYPE=Release

  BUILD_BYPRODUCTS ${KERNEL_ELF} ${KERNEL64_ELF}
  BUILD_ALWAYS ON

  USES_TERMINAL_CONFIGURE ON
  USES_TERMINAL_BUILD     ON
  STEP_TARGETS configure build
)

# The machine's network card, named once and used by every way of starting it.
#
# The MAC is stated rather than left to QEMU's default, which happens to be the
# same value: a test that asserts an address should be asserting one this file
# chose. User-mode networking needs no privileges and gives the guest
# 10.0.2.15, a gateway at 10.0.2.2 and a DHCP server -- enough for a network
# stack to come up without anything being configured by hand.
set(QEMU_NIC
  -netdev user,id=net0
  -device e1000,netdev=net0,mac=52:54:00:12:34:56)

# Boot it. Serial goes to stdio so the console is the terminal running this.
# -cpu max is for RDSEED and RDRAND, the kernel's only source of randomness;
# QEMU's default CPU model has neither, and kernel/random.c stops the boot
# rather than make keys from something predictable.
if(QEMU_EXECUTABLE)
  add_custom_target(run
    COMMAND ${QEMU_EXECUTABLE}
            -kernel ${KERNEL_ELF}
            -m 2048
            -cpu max
            -serial stdio
            -display none
            -no-reboot
            ${QEMU_NIC}
    DEPENDS kernel
    USES_TERMINAL
    COMMENT "Booting the kernel in QEMU")
endif()

# ---------------------------------------------------------------- verify for dev dependencies
# NOTE:
# These check the files that are the *reason* the dependency is here, not just
# that a directory exists. If lrama or lex.c.blt disappeared, the assumption
# that this project needs neither bison nor gperf has broken, and it is better
# to learn that here than halfway through a CRuby cross build.
enable_testing()

function(add_files_exist_test name)
  add_test(NAME ${name} COMMAND ${CMAKE_COMMAND}
           "-DFILES=${ARGN}" -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/files_exist.cmake)
endfunction()

add_files_exist_test(verify_clone_musl
  ${TP}/musl/configure ${TP}/musl/src/malloc/mallocng/malloc.c)

add_files_exist_test(verify_build_musl
  ${TP}/musl/install/lib/libc.a       # full musl, for the PicoRuby-only kernel
  ${TP}/musl/install/include/stdio.h  # headers the PicoRuby cross build compiles against
  ${TP}/musl/lib/libc_kernel.a)       # allocator removed, for the CRuby kernel

add_test(NAME verify_musl_patched COMMAND ${CMAKE_COMMAND}
         -DDIR=${TP}/musl
         -DLLVM_NM=${LLVM_NM_EXECUTABLE}
         -DLLVM_OBJDUMP=${LLVM_OBJDUMP_EXECUTABLE}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/musl_symbols.cmake)

add_files_exist_test(verify_clone_cruby
  ${TP}/cruby/parse.y
  ${TP}/cruby/tool/lrama/exe/lrama        # parse.c/ripper.c are generated without bison
  ${TP}/cruby/ext/ripper/tools/generate.rb
  ${TP}/cruby/lex.c.blt                   # lex.c is copied from here, so gperf is not needed
  ${TP}/cruby/ext/io/console/console.c    # statically linked later, not the io-console gem
  ${TP}/cruby/ext/socket/mkconstants.rb   # the constant tables are generated, not shipped
  ${TP}/cruby/ext/socket/lib/socket.rb    # Addrinfo#listen and Socket.tcp_server_sockets
  ${TP}/cruby/gems/bundled_gems)          # irb/reline versions are derived from this

add_files_exist_test(verify_build_picoruby
  ${PICORUBY_LIB}
  ${PICORBC}
  ${TP}/picoruby/build/x86_64-bare-metal/include/mruby/presym/id.h)  # generated headers the kernel compiles against

add_test(NAME verify_picoruby_symbols COMMAND ${CMAKE_COMMAND}
         -DARCHIVE=${PICORUBY_LIB} -DLLVM_NM=${LLVM_NM_EXECUTABLE}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/picoruby_symbols.cmake)

add_test(NAME verify_picorbc_compiles COMMAND ${CMAKE_COMMAND}
         -DPICORBC=${PICORBC} -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/picorbc_compiles.cmake)

add_files_exist_test(verify_build_cruby_host
  ${MINIRUBY}
  ${CRUBY_HOST_DIR}/parse.c            # generated by Lrama, not bison
  ${CRUBY_HOST_DIR}/lex.c              # copied from lex.c.blt, not generated by gperf
  ${CRUBY_HOST_DIR}/builtin_binary.rbbin
  ${TP}/cruby/ext/ripper/ripper.c
  ${TP}/cruby/ext/socket/constdefs.c)  # generated by mkconstants.rb

add_test(NAME verify_cruby_host COMMAND ${CMAKE_COMMAND}
         -DSRC=${TP}/cruby -DBUILD=${CRUBY_HOST_DIR}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/cruby_host.cmake)

add_files_exist_test(verify_build_cruby_cross ${CRUBY_LIB})

add_test(NAME verify_cruby_cross COMMAND ${CMAKE_COMMAND}
         -DARCHIVE=${CRUBY_LIB}
         -DLIBC=${TP}/musl/install/lib/libc.a
         "-DLIBRARIES=${OPENSSL_BUILD_DIR}/libssl.a|${OPENSSL_BUILD_DIR}/libcrypto.a"
         -DLLVM_NM=${LLVM_NM_EXECUTABLE}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/cruby_cross.cmake)

# Every Ruby file that goes into the image, parsed before anything is built.
# The kernel's Ruby is compiled by picorbc, so a mistake there is already a
# build error; the userland script is embedded as a string and evaluated at
# boot, where a syntax error becomes a page fault inside CRuby's exception
# machinery with no output at all.
set(IMAGE_RUBY
  ${CMAKE_SOURCE_DIR}/ruby/userland/init.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/vfs.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/fd.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/tty.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/clock.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/pci.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/e1000.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/arp.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/net.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/poll.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/sockets.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/syscall.rb
  ${CMAKE_SOURCE_DIR}/ruby/kernel/boot.rb)
string(JOIN "|" IMAGE_RUBY_ARG ${IMAGE_RUBY})

add_test(NAME verify_ruby_syntax COMMAND ${CMAKE_COMMAND}
         -DRUBY=${RUBY_EXECUTABLE}
         "-DFILES=${IMAGE_RUBY_ARG}"
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/ruby_syntax.cmake)

add_test(NAME verify_cruby_socket COMMAND ${CMAKE_COMMAND}
         -DARCHIVE=${CRUBY_LIB}
         -DLLVM_NM=${LLVM_NM_EXECUTABLE}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/cruby_socket.cmake)

add_files_exist_test(verify_build_kernel ${KERNEL_ELF} ${KERNEL64_ELF})

add_test(NAME verify_kernel_no_syscall_insn COMMAND ${CMAKE_COMMAND}
         -DELF=${KERNEL64_ELF} -DLLVM_OBJDUMP=${LLVM_OBJDUMP_EXECUTABLE}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/no_syscall_insn.cmake)

add_test(NAME verify_kernel_tls COMMAND ${CMAKE_COMMAND}
         -DELF=${KERNEL64_ELF} -DLLVM_READELF=${LLVM_READELF_EXECUTABLE}
         -DLLVM_NM=${LLVM_NM_EXECUTABLE}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/tls_segment.cmake)

if(QEMU_EXECUTABLE)
  add_test(NAME verify_kernel_boots COMMAND ${CMAKE_COMMAND}
           -DQEMU=${QEMU_EXECUTABLE}
           -DKERNEL=${KERNEL_ELF}
           # Enough Ruby to show the VM is genuinely executing: a literal, a
           # block with an integer method, and string interpolation.
           # Everything up to the point where the REPL starts waiting for
           # input. With no input the system sits at the prompt, which is
           # correct, so the summary printed after the REPL belongs to the
           # test that actually drives it.
           # The thread lines are pthread_create reaching kernel/task.c and
           # coming back: values through join, a Queue between two threads, a
           # contended Mutex, and Timeout, which is one thread raising into
           # another blocked on a condition variable -- all of it futex. Two
           # hundred threads, four at a time, is more than the kernel has
           # slots for, so finishing says slots and stacks are given back. The
           # preempt line is a thread spinning without a syscall, which only
           # gives way if the tick takes the CPU from it.
           #
           # The fs lines are the filesystem being written: a file created,
           # appended to and read back, a .rb written and then required --
           # Prism maps it, and must get a copy rather than the file's own
           # pages -- an mtime that moves, a rename, a delete, and a directory
           # listed through getdents64.
           #
           # The irq line counts ticks rather than announcing them: twenty
           # milliseconds by the TSC, and the number of timer interrupts that
           # arrived in them. A PIC left masked or a gate pointing nowhere both
           # print 0, which this does not match.
           #
           # The e1000 line is evidence rather than decoration: printing an
           # address means ruby/kernel/pci.rb found the card in configuration
           # space through two port instructions, that its BAR was read
           # correctly, and that e1000.rb drove the EEPROM read protocol --
           # write the word address, wait for done, take the top half of the
           # register -- from Ruby.
           #
           # The ARP line is the descriptor rings, end to end and on their
           # own: a frame built in the card's transmit buffer, handed over,
           # answered by another machine, written back into the receive buffer
           # by the card, and parsed in Ruby. The address is QEMU's, which
           # encodes the IP into the MAC -- so it cannot have come from here.
           #
           # The net line is lwIP, and the address is not in this image
           # anywhere: the interface is added with no address at all and DHCP
           # supplies one. Which means a conversation happened -- discover,
           # offer, request, acknowledge -- with every frame in both directions
           # carried by a driver written in Ruby and a pump called from the
           # syscall dispatcher.
           #
           # The listener line is picoruby-socket's port layer, reached from
           # Ruby: a pcb allocated, bound and put into listen, and an accept
           # that reports nothing waiting rather than something worse. What it
           # does not cover is a connection actually arriving, which is what
           # CRuby's own TCPServer will be asked to do next.
           #
           # The http lines are CRuby's own TCPServer: a descriptor, a bind,
           # a listen and an IO.select, all serviced by the Ruby kernel. Zero
           # requests is the right answer here -- nothing connects in this
           # check -- and it is still worth asserting, because it says the
           # server opened, waited and gave way rather than stopping at a
           # blocking accept.
           #
           # The socket lines say three separate things: the constant tables
           # mkconstants.rb generated survived the cross compile, uname(2)
           # answers so the server can name itself, musl resolves a numeric
           # address with no resolver behind it, and socket.rb was found in the
           # Ruby filesystem -- Addrinfo is defined there, not in the C half.
           "-DEXPECT=boot ok|traps ok|irq: timer 1000 Hz, [1-9][0-9]* ticks in 20 ms|random: rd[a-z]+|libc ok|picoruby vm ok|clock: 20[0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9] UTC|cruby init ok|2\\*\\*100 = 1267650600228229401496703205376|hello from a file served by the Ruby kernel|read 268 bytes from the Ruby VFS|io/console: IO#raw true|ripper: 5 tokens from Ripper.lex|threads: 4 joined [[]1, 2, 3, 4[]]|threads: 200 started and finished|queue: 100 items|mutex: 1000|preempt: a spinning thread gave way|timeout: Timeout::Error|fs: 2 lines, 36 bytes|fs: required a file written at run time, ANSWER = 42|fs: mtime moved true|fs: /tmp holds [[].[.]., .[.][.]., .renamed[.]txt.[]]|e1000: base [0-9a-f]+ mac 52:54:00:12:34:56 link up|arp: 10[.]0[.]2[.]2 is at 52:55:0a:00:02:02|net: 10[.]0[.]2[.]15/24 gw 10[.]0[.]2[.]2 up|net: tcp listener idle|socket: AF_INET 2, SOMAXCONN 128|socket: hostname picoruby-kernel|socket: Addrinfo #<Addrinfo: 10[.]0[.]2[.]15:80 TCP>|http: listening on 0[.]0[.]0[.]0:80|http: served 0 requests|irb 1[.0-9]* loaded|irb\\(main\\):001"
           # Nothing may reach rb_bug: CRuby's answer to an impossible libc
           # result is to abort, and it has no way to say so on this machine.
           # ThreadError likewise: threads are real now, and failing to make one
           # is a kernel bug rather than a limitation. An unhandled syscall
           # names what the kernel was asked for and did not do -- futex was
           # the first of those threads would hit -- and a futex wait inside a
           # dispatch is the one wait that could never be woken.
           "-DEXPECT_NONE=\\[BUG\\]|rb_bug|ThreadError|threads failed|fs failed|unhandled syscall|futex wait inside a dispatch|lwip: assertion failed|frames dropped"
           -DLOG=${CMAKE_CURRENT_BINARY_DIR}/boot_serial.log
           # The kernel halts instead of exiting, so QEMU always runs for the
           # full timeout. Booting takes well under a second here; the margin
           # is for slower machines, and grows as the kernel does more -- the
           # HTTP demo alone waits two seconds for a connection before giving
           # way to irb.
           -DSECONDS=10
           -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/boot_serial.cmake)

  # A machine with no network card still boots to a prompt. Worth its own check
  # because the probe runs at boot, before CRuby: a kernel that only works when
  # the hardware it looks for is present has made the hardware mandatory
  # without meaning to.
  add_test(NAME verify_kernel_boots_without_nic COMMAND ${CMAKE_COMMAND}
           -DQEMU=${QEMU_EXECUTABLE}
           -DKERNEL=${KERNEL_ELF}
           -DNO_NIC=ON
           # Errno::ENETDOWN rather than a crash or a hang: a machine with no
           # card cannot listen, and saying so is the whole of what a socket
           # layer owes a caller in that situation.
           "-DEXPECT=boot ok|e1000: no card|arp: no card|net: no card|cruby init ok|socket failed: Errno::ENETDOWN|irb\\(main\\):001"
           "-DEXPECT_NONE=\\[BUG\\]|rb_bug|ThreadError"
           -DLOG=${CMAKE_CURRENT_BINARY_DIR}/boot_serial_no_nic.log
           # The prompt arrives about 3.4 seconds in, after the thread checks
           # and irb's two hundred requires. Five left too little room: a busy
           # host pushed it past the end once in a full ctest run.
           -DSECONDS=10
           -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/boot_serial.cmake)

  # The whole stack, end to end, from outside the machine: a request made by
  # this process is answered by CRuby's TCPServer running on a kernel whose
  # socket policy is Ruby, whose TCP is lwIP, and whose network card is driven
  # by Ruby.
  #
  # The driver watches the console and knocks the moment the kernel says it is
  # listening, because the demo gives way to irb after a couple of seconds and
  # user-mode networking refuses a forward to a guest that is not listening
  # yet. Boot, sleep and hope would be a test that passes for the wrong reason
  # about as often as it fails for one.
  add_test(NAME verify_http COMMAND ${RUBY_EXECUTABLE}
           ${CMAKE_SOURCE_DIR}/test/http_driver.rb
           --qemu ${QEMU_EXECUTABLE}
           --kernel ${KERNEL_ELF}
           --log ${CMAKE_CURRENT_BINARY_DIR}/http_session.log
           # Not 8080: an unprivileged port on the host, forwarded to the
           # kernel's 80, and unlikely to be in use by anything else.
           --port 18080
           --requests 2
           --expect "hello from a Ruby kernel"
           --until "http: served"
           --seconds 45)

  # Drives irb through a stand-in terminal, exercising the three things that
  # separate this from the dumb terminal irb started out on. The session types
  # "1 + 9", backspaces over the 9 and types 3; recalls that line with the up
  # arrow; and completes "[1,2].ma" with Tab. Editing, history, completion.
  # It then allocates and drops 20MB 120 times, 2.4GB against an arena of
  # about 2GB, which only finishes if munmap gives the pages back.
  add_test(NAME verify_irb COMMAND ${CMAKE_COMMAND}
           -DRUBY=${RUBY_EXECUTABLE}
           -DDRIVER=${CMAKE_SOURCE_DIR}/test/terminal_driver.rb
           -DQEMU=${QEMU_EXECUTABLE}
           -DKERNEL=${KERNEL_ELF}
           -DINPUT=${CMAKE_SOURCE_DIR}/test/irb_session.txt
           -DLOG=${CMAKE_CURRENT_BINARY_DIR}/irb_session.log
           # irb loads 200-odd files through the VFS before the first prompt,
           # and the HTTP demo waits two seconds before that.
           -DSECONDS=60
           # No space: an escaped one does not survive the trip to the driver.
           -DUNTIL=irb.finished
                      # Character classes rather than backslash escapes: CMake's regular
           # expressions are not the ones the shell or Ruby would give you.
           "-DEXPECT=irb 1[.0-9]* loaded|irb[(]main[)]:001> 1 [+] 3|=> 4|irb[(]main[)]:002> 1 [+] 3|irb[(]main[)]:003> [[]1,2[]].map!|=> :reclaimed|irb finished"
           -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/irb_session.cmake)

  # A connection made from inside the kernel to a server outside it: CRuby's
  # TCPSocket.new, through connect and the poll for its handshake, to an echo
  # server test/echo_driver.rb runs on this side. One line goes out and comes
  # back. A port nothing listens on is refused, with the errno saying so,
  # because that is what SO_ERROR has to carry from lwIP to ext/socket.
  #
  # Name resolution is not checked here, because it needs a name server that
  # answers, and that is the network outside this machine.
  add_test(NAME verify_net_client COMMAND ${CMAKE_COMMAND}
           -DRUBY=${RUBY_EXECUTABLE}
           -DDRIVER=${CMAKE_SOURCE_DIR}/test/echo_driver.rb
           "-DDRIVER_ARGS=--echo-port;18500"
           -DQEMU=${QEMU_EXECUTABLE}
           -DKERNEL=${KERNEL_ELF}
           -DINPUT=${CMAKE_SOURCE_DIR}/test/net_client_session.txt
           -DLOG=${CMAKE_CURRENT_BINARY_DIR}/net_client_session.log
           -DSECONDS=60
           -DUNTIL=irb.finished
           "-DEXPECT==> .echo: hello[\\]n.|=> Errno::ECONNREFUSED|irb finished"
           -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/irb_session.cmake)

  # termfront, started from irb by its name. It loads -- its network layer
  # and so openssl, socket, json and date with it -- enters the alternate
  # screen, draws its title and demo through io/console from its writer
  # thread, and reads the "q" that quits it with IO.select and read_nonblock.
  # Then irb has the terminal back, cooked again, and answers the next line.
  #
  # The session has blank lines after the "q". The driver sends a line every
  # 0.4 seconds whatever is listening, and termfront reads its keys 64 bytes at
  # a time, so whatever arrives with the "q" goes with it.
  add_test(NAME verify_termfront COMMAND ${CMAKE_COMMAND}
           -DRUBY=${RUBY_EXECUTABLE}
           -DDRIVER=${CMAKE_SOURCE_DIR}/test/terminal_driver.rb
           -DQEMU=${QEMU_EXECUTABLE}
           -DKERNEL=${KERNEL_ELF}
           -DINPUT=${CMAKE_SOURCE_DIR}/test/termfront_session.txt
           -DLOG=${CMAKE_CURRENT_BINARY_DIR}/termfront_session.log
           -DSECONDS=90
           -DUNTIL=irb.finished
           "-DEXPECT=T E R M F R O N T|[[]S[]] Training|=> :back_from_termfront|irb finished"
           -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/irb_session.cmake)

  # TLS, end to end: OpenSSL in the kernel, through the socket layer above, to
  # a server test/tls_driver.rb runs on this side with a certificate for
  # 10.0.2.2 from a CA it made a moment ago. The kernel trusts that CA from a
  # file written at run time, verifies the chain and the address in the
  # certificate, and a line goes out and comes back encrypted. The digest line
  # is a known answer, SHA-256 of "abc", which says libcrypto itself computes
  # correctly in this image.
  add_test(NAME verify_tls_connection COMMAND ${CMAKE_COMMAND}
           -DRUBY=${RUBY_EXECUTABLE}
           -DDRIVER=${CMAKE_SOURCE_DIR}/test/tls_driver.rb
           "-DDRIVER_ARGS=--tls-port;18443"
           -DQEMU=${QEMU_EXECUTABLE}
           -DKERNEL=${KERNEL_ELF}
           -DINPUT=${CMAKE_SOURCE_DIR}/test/tls_session.txt
           -DLOG=${CMAKE_CURRENT_BINARY_DIR}/tls_session.log
           -DSECONDS=90
           -DUNTIL=irb.finished
           "-DEXPECT==> .ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.|=> :ca_written|=> .echo: over tls[\\]n.|irb finished"
           -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/irb_session.cmake)
endif()

add_files_exist_test(verify_clone_picoruby
  ${TP}/picoruby/build_config/picorbc.rb
  ${TP}/picoruby/mrbgems/picoruby-mruby/lib/mruby/include/mruby.h        # submodule
  ${TP}/picoruby/mrbgems/picoruby-mruby/lib/estalloc/estalloc.h          # submodule
  ${TP}/picoruby/mrbgems/mruby-compiler2/lib/prism/templates/template.rb)  # nested submodule
