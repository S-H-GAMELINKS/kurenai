# cmake -DARCHIVE=<libmruby.a> -DLLVM_NM=<llvm-nm> -P picoruby_symbols.cmake
#
# Checks the two things about libmruby.a that the kernel link depends on:
#
#   1. mrb_basic_alloc_func is defined exactly once. mruby's allocf.o and
#      PicoRuby's Estalloc both define it, and the duplicate only shows up as a
#      link error much later, in the kernel link.
#   2. The symbols the kernel is expected to supply are still undefined, and
#      nothing new has joined them. This is the HAL contract; if a PicoRuby
#      bump adds another one, the kernel needs a matching implementation and
#      it is better to learn that here.

cmake_minimum_required(VERSION 3.25)

foreach(v ARCHIVE LLVM_NM)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "picoruby_symbols.cmake: -D${v}=... is required")
  endif()
endforeach()

execute_process(COMMAND ${LLVM_NM} "${ARCHIVE}"
                OUTPUT_VARIABLE nm_out ERROR_QUIET
                COMMAND_ERROR_IS_FATAL ANY)
string(REPLACE "\n" ";" nm_lines "${nm_out}")

# Split the symbol table into what the archive defines and what it leaves open.
set(defined "")
set(undefined "")
foreach(line IN LISTS nm_lines)
  if(line MATCHES "^[0-9a-f]+ [A-TV-Z] (.+)$")
    list(APPEND defined "${CMAKE_MATCH_1}")
  elseif(line MATCHES "^ +U (.+)$")
    list(APPEND undefined "${CMAKE_MATCH_1}")
  endif()
endforeach()

# 1. exactly one allocator entry point
set(n 0)
foreach(sym IN LISTS defined)
  if(sym STREQUAL "mrb_basic_alloc_func")
    math(EXPR n "${n} + 1")
  endif()
endforeach()
if(NOT n EQUAL 1)
  message(FATAL_ERROR
    "mrb_basic_alloc_func is defined ${n} times in ${ARCHIVE}, expected 1.\n"
    "Two definitions mean allocf.o was not removed; zero means Estalloc was\n"
    "not built in (check PICORB_ALLOC_ESTALLOC in the build config).")
endif()

# The VM must be able to run on a kernel-provided pool.
foreach(sym mrb_open_with_custom_alloc est_init)
  if(NOT sym IN_LIST defined)
    message(FATAL_ERROR "${ARCHIVE} does not define ${sym}")
  endif()
endforeach()

# 2. the kernel's side of the contract
#
# The scheduler HAL the kernel implements with the timer and cli/sti, plus two
# symbols that need stubs: pm_constant_pool_id_to_constant comes from Prism,
# which is not linked in this configuration, and mrb_io_fileno comes from
# mruby-io.
set(EXPECTED_FROM_KERNEL
  mrb_hal_task_init
  mrb_hal_task_final
  mrb_hal_task_idle_cpu
  mrb_hal_task_sleep_us
  mrb_task_enable_irq
  mrb_task_disable_irq
  pm_constant_pool_id_to_constant
  mrb_io_fileno)

set(missing "")
foreach(sym IN LISTS EXPECTED_FROM_KERNEL)
  if(sym IN_LIST defined)
    list(APPEND missing "${sym} (unexpectedly defined)")
  elseif(NOT sym IN_LIST undefined)
    list(APPEND missing "${sym} (no longer referenced)")
  endif()
endforeach()
if(missing)
  string(REPLACE ";" "\n  " pretty "${missing}")
  message(FATAL_ERROR
    "the set of symbols the kernel must supply has changed:\n  ${pretty}\n"
    "Update the kernel HAL and this list together.")
endif()

list(LENGTH EXPECTED_FROM_KERNEL n)
message(STATUS "ok: libmruby.a leaves ${n} symbols to the kernel, as expected")
