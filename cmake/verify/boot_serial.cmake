# cmake -DQEMU=<qemu> -DKERNEL=<kernel.elf> -DEXPECT=<a|b|c> -DLOG=<file>
#       [-DSECONDS=n] -P boot_serial.cmake
#
# EXPECT is one or more regular expressions separated by "|", all of which must
# appear. A CMake list cannot be used: add_test splits arguments on semicolons.
#
# EXPECT_NONE is the same, for patterns that must not appear. Asserting on a
# line that is present says the kernel got somewhere; asserting on one that is
# absent says it did not get there the wrong way, and that is not the same
# check. A CRuby that reaches rb_bug prints and aborts, which from the outside
# looks a great deal like a kernel that booted and then stopped saying
# anything.
#
# Boots the kernel and looks for a string on the serial console. This is the
# only check that covers the whole path at once: the Multiboot header being
# found, the switch to long mode, the flat image landing where the stub jumps,
# BSS being zeroed, and the console working.
#
# The kernel halts rather than exiting, so QEMU is stopped by the timeout and
# its exit status carries no information. The serial log is the result.
#
# With INPUT, the console becomes bidirectional and the file is typed into it.
# It is sent after INPUT_DELAY seconds rather than immediately: enabling the
# UART's FIFOs resets them, so anything that arrived before the kernel got that
# far is gone.

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

if(DEFINED INPUT)
  if(NOT DEFINED INPUT_DELAY)
    set(INPUT_DELAY 2)
  endif()
  # -serial stdio, so the console is readable as well as writable. The delay
  # needs a shell; this project is Linux-only and already requires one.
  execute_process(
    COMMAND sh -c
            "(sleep ${INPUT_DELAY}; cat '${INPUT}') | '${QEMU}' -kernel '${KERNEL}' -m 2048 -serial stdio -display none -no-reboot > '${LOG}' 2>&1"
    TIMEOUT ${SECONDS}
    RESULT_VARIABLE rc
    OUTPUT_VARIABLE out
    ERROR_VARIABLE err)
else()
  execute_process(
    COMMAND ${QEMU}
            -kernel "${KERNEL}"
            -m 2048
            -serial file:${LOG}
            -display none
            -no-reboot
    TIMEOUT ${SECONDS}
    RESULT_VARIABLE rc
    OUTPUT_VARIABLE out
    ERROR_VARIABLE err)
endif()

if(NOT EXISTS "${LOG}")
  message(FATAL_ERROR
    "QEMU produced no serial log (result: ${rc}).\n${out}${err}")
endif()

file(READ "${LOG}" serial)

string(REPLACE "|" ";" patterns "${EXPECT}")
set(unmatched "")
foreach(pattern IN LISTS patterns)
  if(NOT serial MATCHES "${pattern}")
    list(APPEND unmatched "${pattern}")
  endif()
endforeach()

if(unmatched)
  string(REPLACE ";" "\n  " pretty "${unmatched}")
  message(FATAL_ERROR
    "the serial console did not show:\n  ${pretty}\n"
    "what it did show:\n${serial}\n"
    "QEMU result: ${rc}\n${err}")
endif()

set(forbidden "")
if(DEFINED EXPECT_NONE)
  string(REPLACE "|" ";" refused "${EXPECT_NONE}")
  foreach(pattern IN LISTS refused)
    if(serial MATCHES "${pattern}")
      list(APPEND forbidden "${pattern}")
    endif()
  endforeach()
endif()

if(forbidden)
  string(REPLACE ";" "\n  " pretty "${forbidden}")
  message(FATAL_ERROR
    "the serial console showed what it must not:\n  ${pretty}\n"
    "what it did show:\n${serial}\n"
    "QEMU result: ${rc}\n${err}")
endif()

list(LENGTH patterns n)
list(LENGTH refused m)
message(STATUS "ok: booted, printed all ${n} expected lines, none of ${m} refused")
