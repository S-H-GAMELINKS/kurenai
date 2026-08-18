# cmake/deps/picoruby_submodules.cmake
#   cmake -DDIR=<picoruby src> -P picoruby_submodules.cmake
#
# PicoRuby's .gitmodules lists 11 submodules, including pico-sdk, pico-extras
# and rp2040js, which are large and irrelevant to an x86_64 kernel. So each
# needed submodule is initialized individually instead of using --recursive.

cmake_minimum_required(VERSION 3.25)
if(NOT DEFINED DIR)
  message(FATAL_ERROR "picoruby_submodules.cmake: -DDIR=... is required")
endif()
find_package(Git REQUIRED)

set(SUBMODULES
  mrbgems/picoruby-mruby/lib/mruby          # the mruby VM itself
  mrbgems/picoruby-mruby/lib/estalloc       # Estalloc allocator
  mrbgems/mruby-compiler2                   # picorbc, the compiler
  mrbgems/mruby-bin-mrbc2
  mrbgems/picoruby-regexp_light/lib/regex_light
)

function(init_submodule work path)
  # Try shallow first.
  # Keep the failure output instead of discarding it: when shallow does not
  # work in someone else's environment, "why did it fall back?" is the only
  # thing worth knowing, and silence makes it unanswerable.
  execute_process(
    COMMAND ${GIT_EXECUTABLE} submodule update --init --depth 1 -- ${path}
    WORKING_DIRECTORY ${work}
    RESULT_VARIABLE rc
    OUTPUT_QUIET
    ERROR_VARIABLE shallow_err)
  if(NOT rc EQUAL 0)
    # A shallow fetch can fail when the pinned SHA is not the remote tip.
    message(STATUS "submodule ${path}: shallow failed, retrying with full history")
    if(shallow_err)
      message(STATUS "  reason: ${shallow_err}")
    endif()
    execute_process(
      COMMAND ${GIT_EXECUTABLE} submodule update --init -- ${path}
      WORKING_DIRECTORY ${work}
      COMMAND_ERROR_IS_FATAL ANY)
  endif()
  message(STATUS "submodule ok: ${path}")
endfunction()

foreach(sm IN LISTS SUBMODULES)
  init_submodule(${DIR} ${sm})
endforeach()

# The nested one: prism (the Prism parser) inside mruby-compiler2. Forgetting
# it makes rake fail with "status 127" when it tries to run
# templates/template.rb, which is a genuinely hard error to trace back.
init_submodule(${DIR}/mrbgems/mruby-compiler2 lib/prism)
