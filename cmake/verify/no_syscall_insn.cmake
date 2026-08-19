# cmake -DELF=<kernel elf> -DLLVM_OBJDUMP=<llvm-objdump> -P no_syscall_insn.cmake
#
# Asserts the linked kernel contains no syscall instruction (opcode 0f 05).
#
# musl is patched to call kernel_syscall() instead, but the patch only reaches
# the C paths; a handful of hand-written assembly files in musl still issue the
# instruction directly. Those are harmless while nothing references them, and
# fatal the moment something does, since there is no kernel below this one to
# trap into. Whether they were pulled in is a property of the link, so this is
# the only place the question can actually be answered.

cmake_minimum_required(VERSION 3.25)

foreach(v ELF LLVM_OBJDUMP)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "no_syscall_insn.cmake: -D${v}=... is required")
  endif()
endforeach()

execute_process(COMMAND ${LLVM_OBJDUMP} -d "${ELF}"
                OUTPUT_VARIABLE disasm ERROR_QUIET
                COMMAND_ERROR_IS_FATAL ANY)

string(REGEX MATCHALL "\n[ \t]+[0-9a-f]+:[ \t]+0f 05[ \t]" hits "${disasm}")
list(LENGTH hits n)
if(NOT n EQUAL 0)
  message(FATAL_ERROR
    "${ELF} contains ${n} syscall instructions.\n"
    "Something pulled in one of musl's hand-written assembly paths (vfork,\n"
    "__restore_rt, __set_thread_area, __unmapself, __syscall_cp_asm). Find the\n"
    "reference and route it through kernel_syscall instead.")
endif()

message(STATUS "ok: no syscall instructions in the linked kernel")
