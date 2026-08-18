# cmake -DDIR=<musl src> -DLLVM_NM=<llvm-nm> -DLLVM_OBJDUMP=<llvm-objdump> -P musl_symbols.cmake
#
# Checks that the musl patch actually took effect, rather than just that the
# build succeeded. Three properties matter:
#
#   1. libc.a calls kernel_syscall instead of issuing syscall instructions.
#   2. libc_kernel.a no longer defines the allocator the kernel replaces.
#   3. Only the known hand-written assembly files still contain a syscall
#      instruction, so a musl bump that adds a new one is noticed here.

cmake_minimum_required(VERSION 3.25)

foreach(v DIR LLVM_NM LLVM_OBJDUMP)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "musl_symbols.cmake: -D${v}=... is required")
  endif()
endforeach()

set(FULL_LIB   "${DIR}/install/lib/libc.a")
set(KERNEL_LIB "${DIR}/lib/libc_kernel.a")

# 1. syscalls are routed through the kernel.
execute_process(COMMAND ${LLVM_NM} "${FULL_LIB}"
                OUTPUT_VARIABLE nm_full ERROR_QUIET
                COMMAND_ERROR_IS_FATAL ANY)
if(NOT nm_full MATCHES "U kernel_syscall")
  message(FATAL_ERROR
    "${FULL_LIB} has no reference to kernel_syscall.\n"
    "patches/musl.patch did not take effect.")
endif()

# 2. the allocator is gone from the kernel flavour.
execute_process(COMMAND ${LLVM_NM} "${KERNEL_LIB}"
                OUTPUT_VARIABLE nm_kernel ERROR_QUIET
                COMMAND_ERROR_IS_FATAL ANY)
foreach(sym malloc free realloc calloc mmap munmap)
  if(nm_kernel MATCHES "[0-9a-f]+ [TDW] ${sym}\n")
    message(FATAL_ERROR "${KERNEL_LIB} still defines ${sym}")
  endif()
endforeach()

# 3. no unexpected syscall instructions (opcode 0f 05).
#    The 8 that remain live in vfork.lo, restore.lo, __set_thread_area.lo,
#    __unmapself.lo and syscall_cp.lo, all hand-written assembly on paths this
#    kernel does not take. They are only a problem if they end up linked, which
#    is checked against the kernel ELF once there is one to check.
set(EXPECTED_SYSCALL_INSNS 8)
execute_process(COMMAND ${LLVM_OBJDUMP} -d "${FULL_LIB}"
                OUTPUT_VARIABLE disasm ERROR_QUIET
                COMMAND_ERROR_IS_FATAL ANY)
string(REGEX MATCHALL "\n[ \t]+[0-9a-f]+:[ \t]+0f 05[ \t]" hits "${disasm}")
list(LENGTH hits n)
if(NOT n EQUAL EXPECTED_SYSCALL_INSNS)
  message(FATAL_ERROR
    "expected ${EXPECTED_SYSCALL_INSNS} syscall instructions in libc.a, found ${n}.\n"
    "An unpatched syscall path may have appeared; check which objects contain\n"
    "opcode 0f 05 before changing this number.")
endif()

message(STATUS "ok: musl patched (${n} known syscall instructions remain)")
