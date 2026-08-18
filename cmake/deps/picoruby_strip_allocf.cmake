# cmake/deps/picoruby_strip_allocf.cmake
#
# Remove allocf.o from libmruby.a. Script mode only:
#   cmake -DARCHIVE=<libmruby.a> -DLLVM_AR=<llvm-ar> -P picoruby_strip_allocf.cmake
#
# mruby's src/allocf.c and PicoRuby's Estalloc integration both define
# mrb_basic_alloc_func, and ld.lld rejects the link once both objects are
# pulled in. Estalloc's is the one this kernel wants, because the VM must
# allocate from the pool the kernel gives it rather than from libc.
#
# Removing a member that is already gone is a no-op, so this can re-run.

cmake_minimum_required(VERSION 3.25)

foreach(v ARCHIVE LLVM_AR)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "picoruby_strip_allocf.cmake: -D${v}=... is required")
  endif()
endforeach()
if(NOT EXISTS "${ARCHIVE}")
  message(FATAL_ERROR "picoruby_strip_allocf.cmake: no such archive: ${ARCHIVE}")
endif()

# llvm-ar removes only one member per name per invocation, so loop until the
# name is gone rather than assuming a single copy.
set(removed 0)
foreach(pass RANGE 1 4)
  execute_process(COMMAND ${LLVM_AR} t "${ARCHIVE}"
                  OUTPUT_VARIABLE members
                  OUTPUT_STRIP_TRAILING_WHITESPACE
                  COMMAND_ERROR_IS_FATAL ANY)
  string(REPLACE "\n" ";" members "${members}")
  if(NOT "allocf.o" IN_LIST members)
    break()
  endif()
  execute_process(COMMAND ${LLVM_AR} d "${ARCHIVE}" allocf.o
                  COMMAND_ERROR_IS_FATAL ANY)
  math(EXPR removed "${removed} + 1")
endforeach()

message(STATUS "picoruby_strip_allocf: removed ${removed} allocf.o from ${ARCHIVE}")
