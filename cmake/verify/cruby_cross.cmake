# cmake -DARCHIVE=<libruby-static.a> -DLIBC=<libc.a> -DLLVM_NM=<llvm-nm>
#       [-DLIBRARIES=<a.a;b.a>] -P cruby_cross.cmake
#
# Establishes what the kernel still has to provide before CRuby can be linked,
# and pins it. Everything libruby-static.a needs is either defined inside it,
# comes from musl, or comes from a library linked beside it -- libssl and
# libcrypto, for ext/openssl -- except for a short list. Naming that list here means a CRuby
# or musl bump that lengthens it is a test failure rather than a wall of
# undefined symbols at the final link.

cmake_minimum_required(VERSION 3.25)

foreach(v ARCHIVE LIBC LLVM_NM)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "cruby_cross.cmake: -D${v}=... is required")
  endif()
endforeach()

function(read_symbols archive out_defined out_undefined)
  execute_process(COMMAND ${LLVM_NM} "${archive}"
                  OUTPUT_VARIABLE nm_out ERROR_QUIET
                  COMMAND_ERROR_IS_FATAL ANY)
  string(REPLACE "\n" ";" lines "${nm_out}")
  set(defs "")
  set(undefs "")
  foreach(line IN LISTS lines)
    if(line MATCHES "^[0-9a-f]+ [A-TV-Z] (.+)$")
      list(APPEND defs "${CMAKE_MATCH_1}")
    elseif(line MATCHES "^ +U (.+)$")
      list(APPEND undefs "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  list(REMOVE_DUPLICATES defs)
  list(REMOVE_DUPLICATES undefs)
  set(${out_defined} "${defs}" PARENT_SCOPE)
  set(${out_undefined} "${undefs}" PARENT_SCOPE)
endfunction()

read_symbols("${ARCHIVE}" ruby_defined ruby_undefined)
read_symbols("${LIBC}" libc_defined libc_undefined)

# Separated by | on the command line, because a ; would split the argument.
string(REPLACE "|" ";" LIBRARIES "${LIBRARIES}")
set(library_defined "")
foreach(library IN LISTS LIBRARIES)
  read_symbols("${library}" defined undefined)
  list(APPEND library_defined ${defined})
endforeach()

# The entry points the kernel calls, and the two statically registered
# extensions irb depends on.
foreach(sym ruby_init ruby_options rb_eval_string Init_ext Init_console Init_ripper)
  if(NOT sym IN_LIST ruby_defined)
    message(FATAL_ERROR "${ARCHIVE} does not define ${sym}")
  endif()
endforeach()

# What is left over once the archive resolves itself and musl fills the rest.
#
#   Init_enc   normally comes from the generated enc/encinit.c; the kernel
#              registers the built-in encodings itself instead.
#   __modti3   128-bit integer division helpers, normally from compiler-rt or
#   __umodti3  libgcc, neither of which is linked here.
set(EXPECTED_FROM_KERNEL Init_enc __modti3 __umodti3)

set(missing "")
foreach(sym IN LISTS ruby_undefined)
  if(NOT sym IN_LIST ruby_defined AND NOT sym IN_LIST libc_defined AND
     NOT sym IN_LIST library_defined)
    list(APPEND missing "${sym}")
  endif()
endforeach()
list(SORT missing)

set(expected "${EXPECTED_FROM_KERNEL}")
list(SORT expected)
if(NOT missing STREQUAL expected)
  string(REPLACE ";" "\n  " got "${missing}")
  string(REPLACE ";" "\n  " want "${expected}")
  message(FATAL_ERROR
    "the symbols the kernel must supply have changed.\n"
    "expected:\n  ${want}\n"
    "actual:\n  ${got}\n"
    "Implement the new ones in the kernel and update this list together.")
endif()

list(LENGTH ruby_undefined n)
message(STATUS "ok: libruby-static.a needs ${n} external symbols, all but 3 from musl and the libraries beside it")
