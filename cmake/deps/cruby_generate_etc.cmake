# cmake/deps/cruby_generate_etc.cmake
#
# Generate the etc extension's constant header. Script mode only:
#   cmake -DSRC=<cruby src> -DRUBY=<ruby> -P cruby_generate_etc.cmake
#
# Same situation as ext/socket's tables: the tree ships mkconstants.rb rather
# than constdefs.h. Every entry is guarded by the constant's own name, so which
# _SC_* and _PC_* names exist is still decided against musl's headers when the
# target compiles etc.c.

cmake_minimum_required(VERSION 3.25)

foreach(v SRC RUBY)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "cruby_generate_etc.cmake: -D${v}=... is required")
  endif()
endforeach()

set(ETC_DIR "${SRC}/ext/etc")

execute_process(COMMAND ${RUBY} "${ETC_DIR}/mkconstants.rb" -o constdefs.h
                WORKING_DIRECTORY "${ETC_DIR}"
                COMMAND_ERROR_IS_FATAL ANY)

if(NOT EXISTS "${ETC_DIR}/constdefs.h")
  message(FATAL_ERROR "cruby_generate_etc: constdefs.h was not produced")
endif()
