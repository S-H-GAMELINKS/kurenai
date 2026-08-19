# cmake -DSRC=<cruby src> -DBUILD=<host build dir> -P cruby_host.cmake
#
# Checks the host build produced a working code generator and the generated
# sources the cross build will consume, and that it did so without bison or
# gperf. That last part is the reason this project needs no tools beyond a
# host Ruby, so it is worth asserting rather than assuming.

cmake_minimum_required(VERSION 3.25)

foreach(v SRC BUILD)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "cruby_host.cmake: -D${v}=... is required")
  endif()
endforeach()

# 1. miniruby actually runs. It is the code generator the cross build drives,
#    so "the file exists" is not enough.
execute_process(COMMAND "${BUILD}/miniruby" -e "print 1 + 1"
                OUTPUT_VARIABLE out
                ERROR_VARIABLE err
                RESULT_VARIABLE rc)
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "miniruby failed (${rc}):\n${err}")
endif()
if(NOT out STREQUAL "2")
  message(FATAL_ERROR "miniruby printed '${out}', expected '2'")
endif()

# 2. gperf was not needed. When defs/lex.c.src matches defs/keywords, the build
#    copies the checked-in lex.c.blt instead of running gperf, so the two files
#    being identical is what proves gperf never ran.
file(SIZE "${BUILD}/lex.c" lex_size)
file(MD5 "${BUILD}/lex.c" lex_md5)
file(MD5 "${SRC}/lex.c.blt" blt_md5)
if(NOT lex_md5 STREQUAL blt_md5)
  message(FATAL_ERROR
    "${BUILD}/lex.c differs from ${SRC}/lex.c.blt.\n"
    "That means gperf regenerated it, so gperf is now a build requirement.\n"
    "Check whether defs/keywords changed.")
endif()

# 3. bison was not needed. Lrama stamps the files it generates.
file(READ "${BUILD}/parse.c" parse_head LIMIT 4096)
if(NOT parse_head MATCHES "[Ll]rama")
  message(FATAL_ERROR
    "${BUILD}/parse.c carries no Lrama marker, so it may have been generated\n"
    "by bison. bison is supposed to be unnecessary for this project.")
endif()

# 4. the generated Ripper sources exist and are plausible.
foreach(f ripper.c ripper_init.c eventids1.c eventids1.h eventids2table.c)
  if(NOT EXISTS "${SRC}/ext/ripper/${f}")
    message(FATAL_ERROR "missing generated file: ext/ripper/${f}")
  endif()
endforeach()

file(SIZE "${SRC}/ext/ripper/ripper.c" ripper_size)
if(ripper_size LESS 500000)
  message(FATAL_ERROR
    "ext/ripper/ripper.c is only ${ripper_size} bytes; the generator probably\n"
    "produced a stub rather than the real parser.")
endif()

file(READ "${SRC}/ext/ripper/ripper_init.c" init_src)
if(NOT init_src MATCHES "Init_ripper")
  message(FATAL_ERROR "ext/ripper/ripper_init.c does not define Init_ripper")
endif()

message(STATUS "ok: miniruby runs, lex.c came from lex.c.blt, ripper.c is ${ripper_size} bytes")
