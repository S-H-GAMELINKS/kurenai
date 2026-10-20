# cmake -DELF=<kernel elf> -DLLVM_READELF=<llvm-readelf> -DLLVM_NM=<llvm-nm>
#       -P tls_segment.cmake
#
# Asserts the TLS segment kernel/libc_init.c describes to musl is the one the
# linker emitted.
#
# There is no loader here, so nothing reads the PT_TLS program header at run
# time. kernel64.ld restates it as four symbols, and libc_init builds the
# header musl is handed from those. If they disagree with the real one -- a
# section the script does not name, alignment it did not foresee -- every
# thread's copy of TLS is laid out differently from what the code compiled
# against the image expects, and %fs-relative accesses land on the wrong
# bytes. Nothing would fault. CRuby's current execution context would simply
# be someone else's.

cmake_minimum_required(VERSION 3.25)

foreach(v ELF LLVM_READELF LLVM_NM)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "tls_segment.cmake: -D${v}=... is required")
  endif()
endforeach()

execute_process(COMMAND ${LLVM_READELF} -lW "${ELF}"
                OUTPUT_VARIABLE headers COMMAND_ERROR_IS_FATAL ANY)
if(NOT headers MATCHES "\n[ \t]+TLS[ \t]+0x[0-9a-f]+[ \t]+0x([0-9a-f]+)[ \t]+0x[0-9a-f]+[ \t]+0x([0-9a-f]+)[ \t]+0x([0-9a-f]+)[ \t]+[RWE ]+[ \t]+0x([0-9a-f]+)")
  message(FATAL_ERROR "${ELF} has no PT_TLS program header")
endif()
set(segment_start  ${CMAKE_MATCH_1})
set(segment_filesz ${CMAKE_MATCH_2})
set(segment_memsz  ${CMAKE_MATCH_3})
set(segment_align  ${CMAKE_MATCH_4})

execute_process(COMMAND ${LLVM_NM} "${ELF}"
                OUTPUT_VARIABLE symbols COMMAND_ERROR_IS_FATAL ANY)

set(problems "")
foreach(pair "start;${segment_start}" "filesz;${segment_filesz}"
             "memsz;${segment_memsz}" "align;${segment_align}")
  list(GET pair 0 name)
  list(GET pair 1 expected)
  if(NOT symbols MATCHES "([0-9a-f]+) [A-Za-z] __tls_${name}\n")
    string(APPEND problems "  __tls_${name} is not defined\n")
    continue()
  endif()
  # Both sides as numbers: readelf pads to the field, nm to sixteen digits.
  math(EXPR got "0x${CMAKE_MATCH_1}" OUTPUT_FORMAT HEXADECIMAL)
  math(EXPR want "0x${expected}" OUTPUT_FORMAT HEXADECIMAL)
  if(NOT got STREQUAL want)
    string(APPEND problems "  __tls_${name} is ${got}, PT_TLS says ${want}\n")
  endif()
endforeach()

if(problems)
  message(FATAL_ERROR "kernel64.ld's TLS symbols disagree with the linker:\n${problems}")
endif()

message(STATUS "ok: TLS segment at 0x${segment_start}, "
               "${segment_filesz}/${segment_memsz} bytes, align ${segment_align}")
