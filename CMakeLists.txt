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

  INSTALL_COMMAND ${CMAKE_COMMAND}
      -DSRC=<SOURCE_DIR> -DRUBY=${RUBY_EXECUTABLE}
      -P ${DEPS_DIR}/cruby_generate_ripper.cmake

  BUILD_BYPRODUCTS ${MINIRUBY}
                   ${CRUBY_HOST_DIR}/parse.c
                   ${CRUBY_HOST_DIR}/lex.c
                   ${TP}/cruby/ext/ripper/ripper.c
                   ${TP}/cruby/ext/ripper/ripper_init.c

  USES_TERMINAL_DOWNLOAD  ON
  USES_TERMINAL_PATCH     ON
  USES_TERMINAL_CONFIGURE ON
  USES_TERMINAL_BUILD     ON
  USES_TERMINAL_INSTALL   ON
  STEP_TARGETS download patch configure build install
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
  DEPENDS cruby musl

  DOWNLOAD_COMMAND ""
  UPDATE_COMMAND   ""
  INSTALL_COMMAND  ""

  CMAKE_ARGS
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_SOURCE_DIR}/cmake/toolchain-x86_64-bare-metal.cmake
    -DMUSL_INSTALL=${TP}/musl/install
    -DCRUBY_SRC=${TP}/cruby
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
  PATCH_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/picoruby -P ${DEPS_DIR}/picoruby_submodules.cmake

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

# ---------------------------------------------------------------- kernel
set(KERNEL_DIR   ${CMAKE_BINARY_DIR}/kernel)
set(KERNEL_ELF   ${KERNEL_DIR}/kernel.elf)
set(KERNEL64_ELF ${KERNEL_DIR}/kernel64.elf)

ExternalProject_Add(kernel
  SOURCE_DIR ${CMAKE_SOURCE_DIR}/kernel
  BINARY_DIR ${KERNEL_DIR}
  DEPENDS musl picoruby cruby_cross

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
    -DCMAKE_BUILD_TYPE=Release

  BUILD_BYPRODUCTS ${KERNEL_ELF} ${KERNEL64_ELF}
  BUILD_ALWAYS ON

  USES_TERMINAL_CONFIGURE ON
  USES_TERMINAL_BUILD     ON
  STEP_TARGETS configure build
)

# Boot it. Serial goes to stdio so the console is the terminal running this.
if(QEMU_EXECUTABLE)
  add_custom_target(run
    COMMAND ${QEMU_EXECUTABLE}
            -kernel ${KERNEL_ELF}
            -m 512M
            -serial stdio
            -display none
            -no-reboot
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
  ${TP}/cruby/ext/ripper/ripper.c)

add_test(NAME verify_cruby_host COMMAND ${CMAKE_COMMAND}
         -DSRC=${TP}/cruby -DBUILD=${CRUBY_HOST_DIR}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/cruby_host.cmake)

add_files_exist_test(verify_build_cruby_cross ${CRUBY_LIB})

add_test(NAME verify_cruby_cross COMMAND ${CMAKE_COMMAND}
         -DARCHIVE=${CRUBY_LIB}
         -DLIBC=${TP}/musl/install/lib/libc.a
         -DLLVM_NM=${LLVM_NM_EXECUTABLE}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/cruby_cross.cmake)

add_files_exist_test(verify_build_kernel ${KERNEL_ELF} ${KERNEL64_ELF})

add_test(NAME verify_kernel_no_syscall_insn COMMAND ${CMAKE_COMMAND}
         -DELF=${KERNEL64_ELF} -DLLVM_OBJDUMP=${LLVM_OBJDUMP_EXECUTABLE}
         -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/no_syscall_insn.cmake)

if(QEMU_EXECUTABLE)
  add_test(NAME verify_kernel_boots COMMAND ${CMAKE_COMMAND}
           -DQEMU=${QEMU_EXECUTABLE}
           -DKERNEL=${KERNEL_ELF}
           # Enough Ruby to show the VM is genuinely executing: a literal, a
           # block with an integer method, and string interpolation.
           # The last one is the point of the whole arrangement: CRuby's
           # output reached the console by way of Ruby code running in the
           # other VM. A count kept on the Ruby side is the only evidence,
           # since the output looks the same either way. The number is left
           # open so editing the userland script does not break the test.
           "-DEXPECT=boot ok|tls ok|picoruby vm ok|cruby init ok|2\\*\\*100 = 1267650600228229401496703205376|hello from a file served by the Ruby kernel|read 268 bytes from the Ruby VFS|ruby serviced [1-9][0-9]* writes, [0-9]+ bytes, [1-9][0-9]* opens"
           -DLOG=${CMAKE_CURRENT_BINARY_DIR}/boot_serial.log
           # The kernel halts instead of exiting, so QEMU always runs for the
           # full timeout. Booting takes well under a second here; the margin
           # is for slower machines, and grows as the kernel does more.
           -DSECONDS=5
           -P ${CMAKE_CURRENT_LIST_DIR}/cmake/verify/boot_serial.cmake)
endif()

add_files_exist_test(verify_clone_picoruby
  ${TP}/picoruby/build_config/picorbc.rb
  ${TP}/picoruby/mrbgems/picoruby-mruby/lib/mruby/include/mruby.h        # submodule
  ${TP}/picoruby/mrbgems/picoruby-mruby/lib/estalloc/estalloc.h          # submodule
  ${TP}/picoruby/mrbgems/mruby-compiler2/lib/prism/templates/template.rb)  # nested submodule
