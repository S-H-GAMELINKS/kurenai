# cmake -DQEMU=<qemu> -DKERNEL=<kernel.elf> -DEXPECT=<text> -DLOG=<file> [-DSECONDS=n]
#       -P boot_serial.cmake
#
# Boots the kernel and looks for a string on the serial console. This is the
# only check that covers the whole path at once: the Multiboot header being
# found, the switch to long mode, the flat image landing where the stub jumps,
# BSS being zeroed, and the console working.
#
# The kernel halts rather than exiting, so QEMU is stopped by the timeout and
# its exit status carries no information. The serial log is the result.

cmake_minimum_required(VERSION 3.25)

foreach(v QEMU KERNEL EXPECT LOG)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "boot_serial.cmake: -D${v}=... is required")
  endif()
endforeach()
if(NOT DEFINED SECONDS)
  set(SECONDS 15)
endif()

file(REMOVE "${LOG}")

execute_process(
  COMMAND ${QEMU}
          -kernel "${KERNEL}"
          -m 512M
          -serial file:${LOG}
          -display none
          -no-reboot
  TIMEOUT ${SECONDS}
  RESULT_VARIABLE rc
  OUTPUT_VARIABLE out
  ERROR_VARIABLE err)

if(NOT EXISTS "${LOG}")
  message(FATAL_ERROR
    "QEMU produced no serial log (result: ${rc}).\n${out}${err}")
endif()

file(READ "${LOG}" serial)
if(NOT serial MATCHES "${EXPECT}")
  string(LENGTH "${serial}" n)
  message(FATAL_ERROR
    "expected '${EXPECT}' on the serial console, got ${n} bytes:\n${serial}\n"
    "QEMU result: ${rc}\n${err}")
endif()

message(STATUS "ok: booted and printed '${EXPECT}'")
