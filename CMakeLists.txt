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
include(${CMAKE_CURRENT_LIST_DIR}/cmake/versions.cmake)

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
ExternalProject_Add(musl
  SOURCE_DIR ${TP}/musl

  DOWNLOAD_COMMAND ${CMAKE_COMMAND}
      -DDIR=${TP}/musl -DURL=${MUSL_URL} -DREF=${MUSL_REF}
      -P ${DEPS_DIR}/fetch_sha.cmake

  UPDATE_COMMAND    ""  # the ref is pinned, so never re-fetch; works offline
  CONFIGURE_COMMAND ""
  BUILD_COMMAND     ""
  INSTALL_COMMAND   ""

  USES_TERMINAL_DOWNLOAD ON  # stream progress; without it a long step looks hung
  STEP_TARGETS download      # enables: cmake --build build/dev -t musl-download
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
