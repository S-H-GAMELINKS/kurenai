# cmake -DFILES=a;b;c -P files_exist.cmake
#
# Reports every missing path at once rather than stopping at the first, so one
# run is enough to see how much of a dependency failed to materialize.
cmake_minimum_required(VERSION 3.25)
set(missing "")
foreach(f IN LISTS FILES)
  if(NOT EXISTS "${f}")
    list(APPEND missing "${f}")
  endif()
endforeach()
if(missing)
  string(REPLACE ";" "\n  " pretty "${missing}")
  message(FATAL_ERROR "missing:\n  ${pretty}")
endif()
message(STATUS "ok: all files present")
