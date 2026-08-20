# cmake -DARCHIVE=<libruby-static.a> -DLLVM_NM=<llvm-nm> -P cruby_socket.cmake
#
# What ext/socket was built to be, asserted per object file.
#
# verify_cruby_cross already pins the symbols the kernel must supply, but it
# cannot see this: musl defines getifaddrs, sendmsg and socketpair, so an
# ext/socket that called them would link and the archive-level check would
# notice nothing. The decision to leave them out lives in
# cruby_build/socket_extconf.h, one absent HAVE_* at a time, and an absent
# define is exactly the kind of thing that comes back silently.
#
# The pthread pair is the one that matters most. ext/socket has two code paths
# that create threads -- raddrinfo.c resolves names in a dedicated pthread, and
# ipsocket.c runs Happy Eyeballs with a thread, a pipe and a select loop per
# connect. Which path is compiled is decided by HAVE_PTHREAD_CREATE and by the
# two IMPL macros in cruby_build/CMakeLists.txt. On this machine __clone
# refuses, so choosing wrong means every name lookup fails at runtime rather
# than at build time.

cmake_minimum_required(VERSION 3.25)

foreach(v ARCHIVE LLVM_NM)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "cruby_socket.cmake: -D${v}=... is required")
  endif()
endforeach()

# Undefined symbols, tagged with the object they came from.
execute_process(COMMAND ${LLVM_NM} -u --print-file-name "${ARCHIVE}"
                OUTPUT_VARIABLE nm_out ERROR_QUIET
                COMMAND_ERROR_IS_FATAL ANY)
string(REPLACE "\n" ";" lines "${nm_out}")

# ar stores members by basename, so the objects are named rather than matched
# by path. Listing them also checks that all fifteen are there: none can be
# dropped, because rsock_init_socket_init calls every rsock_init_* whether or
# not the file behind it has any contents.
set(SOCKET_OBJECTS
  init.c.obj constants.c.obj basicsocket.c.obj socket.c.obj ipsocket.c.obj
  tcpsocket.c.obj tcpserver.c.obj sockssocket.c.obj udpsocket.c.obj
  unixsocket.c.obj unixserver.c.obj option.c.obj ancdata.c.obj
  raddrinfo.c.obj ifaddr.c.obj)

set(REFUSED
  # Thread creation. __clone refuses on this machine, so a build that compiled
  # either of ext/socket's threaded paths would fail at the first name lookup.
  pthread_create pthread_detach pthread_attr_setdetachstate
  # An interface list, fd passing and a unix socket, none of which exist here.
  getifaddrs sendmsg recvmsg socketpair
  # A proxy and a resolver.
  SOCKSinit gethostbyname2 getipnodebyname)

# NOTE:
# getservbyport is deliberately not on that list. CRuby 4.0 compiles
# sock_s_getservbyport unconditionally and no longer consults the
# HAVE_GETSERVBYPORT probe at all, so the reference cannot be switched off from
# socket_extconf.h. musl resolves it, and with no /etc/services to read it
# returns NULL, which surfaces as Socket.getservbyport raising SocketError --
# the truthful answer on a machine with no service database. Listing a symbol
# here that cannot be removed would only teach the next person to delete the
# check.

set(offenders "")
set(seen "")
foreach(line IN LISTS lines)
  if(line MATCHES "^[^:]+:([^:]+):[ ]+U (.+)$")
    set(object "${CMAKE_MATCH_1}")
    set(symbol "${CMAKE_MATCH_2}")
    if(NOT object IN_LIST SOCKET_OBJECTS)
      continue()
    endif()
    list(APPEND seen "${object}")
    if(symbol IN_LIST REFUSED)
      list(APPEND offenders "${object} references ${symbol}")
    endif()
  endif()
endforeach()
list(REMOVE_DUPLICATES seen)
list(REMOVE_DUPLICATES offenders)

# An object with no undefined symbols at all never appears in this listing, and
# that is the normal outcome for the ones socket_extconf.h emptied. So presence
# is checked against the archive's index rather than against the listing.
execute_process(COMMAND ${LLVM_NM} --print-armap "${ARCHIVE}"
                OUTPUT_VARIABLE armap ERROR_QUIET
                COMMAND_ERROR_IS_FATAL ANY)
set(absent "")
foreach(object IN LISTS SOCKET_OBJECTS)
  if(NOT armap MATCHES "${object}" AND NOT object IN_LIST seen)
    list(APPEND absent "${object}")
  endif()
endforeach()
if(absent)
  string(REPLACE ";" "\n  " pretty "${absent}")
  message(FATAL_ERROR
    "ext/socket objects missing from ${ARCHIVE}:\n  ${pretty}\n"
    "All fifteen have to be linked; see the note in cruby_build/CMakeLists.txt.")
endif()

if(offenders)
  string(REPLACE ";" "\n  " pretty "${offenders}")
  message(FATAL_ERROR
    "ext/socket was compiled with more than this kernel can answer:\n  ${pretty}\n"
    "Each of these is switched off by leaving a HAVE_* out of "
    "cruby_build/socket_extconf.h; one has come back.")
endif()

# The extension has to be reachable, not merely present. Init_socket is what
# extinit.c registers as socket.so, and require "socket" resolves against that
# name rather than against a file.
execute_process(COMMAND ${LLVM_NM} --defined-only "${ARCHIVE}"
                OUTPUT_VARIABLE defined_out ERROR_QUIET
                COMMAND_ERROR_IS_FATAL ANY)
foreach(sym Init_socket Init_nonblock rsock_init_socket_init)
  if(NOT defined_out MATCHES "[ ]${sym}\n")
    message(FATAL_ERROR "${ARCHIVE} does not define ${sym}")
  endif()
endforeach()

list(LENGTH SOCKET_OBJECTS n)
message(STATUS
  "ok: ${n} ext/socket objects, none reaching for threads, fd passing or a resolver")
