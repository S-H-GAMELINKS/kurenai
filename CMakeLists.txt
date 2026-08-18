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

# ---------------------------------------------------------------- CRuby
ExternalProject_Add(cruby
  SOURCE_DIR ${TP}/cruby

  DOWNLOAD_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/cruby -DURL=${CRUBY_URL} -DREF=${CRUBY_REF}
      -P ${DEPS_DIR}/fetch_sha.cmake

  UPDATE_COMMAND    ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND     ""
  INSTALL_COMMAND   ""
  USES_TERMINAL_DOWNLOAD ON
  STEP_TARGETS download
)

# ---------------------------------------------------------------- PicoRuby
ExternalProject_Add(picoruby
  SOURCE_DIR ${TP}/picoruby

  DOWNLOAD_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/picoruby -DURL=${PICORUBY_URL} -DREF=${PICORUBY_REF}
      -P ${DEPS_DIR}/fetch_sha.cmake

  # NOTE:
  # Submodule initialization is part of acquiring the source, so it goes in the
  # patch step: CMake runs patch right after download and before configure.
  PATCH_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/picoruby -P ${DEPS_DIR}/picoruby_submodules.cmake

  UPDATE_COMMAND    ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND     ""
  INSTALL_COMMAND   ""
  USES_TERMINAL_DOWNLOAD ON
  USES_TERMINAL_PATCH    ON
  STEP_TARGETS download patch
)

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

add_files_exist_test(verify_clone_picoruby
  ${TP}/picoruby/build_config/picorbc.rb
  ${TP}/picoruby/mrbgems/picoruby-mruby/lib/mruby/include/mruby.h        # submodule
  ${TP}/picoruby/mrbgems/picoruby-mruby/lib/estalloc/estalloc.h          # submodule
  ${TP}/picoruby/mrbgems/mruby-compiler2/lib/prism/templates/template.rb)  # nested submodule
