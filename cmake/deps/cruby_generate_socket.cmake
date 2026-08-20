# cmake/deps/cruby_generate_socket.cmake
#
# Generate the socket extension's constant tables. Script mode only:
#   cmake -DSRC=<cruby src> -DRUBY=<ruby> -P cruby_generate_socket.cmake
#
# ext/socket ships mkconstants.rb rather than the tables it produces, so the
# cross build has nothing to compile until this has run. Same situation as
# ext/ripper; see cruby_generate_ripper.cmake.
#
# Generating with the host Ruby cannot bake in the host's idea of what a socket
# constant is: every one of the 1800-odd entries mkconstants.rb emits is wrapped
# in an #ifdef on the constant's own name, so which constants exist is decided
# when the target compiles the file, against musl's headers. The host Ruby only
# has to be able to run optparse and erb.

cmake_minimum_required(VERSION 3.25)

foreach(v SRC RUBY)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "cruby_generate_socket.cmake: -D${v}=... is required")
  endif()
endforeach()

set(SOCKET_DIR "${SRC}/ext/socket")

execute_process(COMMAND ${RUBY} "${SOCKET_DIR}/mkconstants.rb"
                        -H constdefs.h -o constdefs.c
                WORKING_DIRECTORY "${SOCKET_DIR}"
                COMMAND_ERROR_IS_FATAL ANY)

foreach(f constdefs.h constdefs.c)
  if(NOT EXISTS "${SOCKET_DIR}/${f}")
    message(FATAL_ERROR "cruby_generate_socket: ${f} was not produced")
  endif()
endforeach()

file(SIZE "${SOCKET_DIR}/constdefs.c" size)
message(STATUS "cruby_generate_socket: constdefs.c is ${size} bytes")
