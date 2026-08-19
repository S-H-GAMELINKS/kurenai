# cmake/deps/cruby_generate_ripper.cmake
#
# Generate the Ripper extension sources. Script mode only:
#   cmake -DSRC=<cruby src> -DRUBY=<ruby> -P cruby_generate_ripper.cmake
#
# irb needs Ripper: IRB::RubyLex uses Ripper::Lexer to decide whether an input
# line is complete, so ext/ripper has to be part of the CRuby cross build. Its
# sources are generated rather than shipped.
#
# Nothing here needs bison. Since Ruby 3.3 the parser generator is Lrama, a
# pure Ruby implementation vendored at tool/lrama, so the host Ruby is the only
# requirement.

cmake_minimum_required(VERSION 3.25)

foreach(v SRC RUBY)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "cruby_generate_ripper.cmake: -D${v}=... is required")
  endif()
endforeach()

set(RIPPER_DIR "${SRC}/ext/ripper")
set(GENERATE "${RIPPER_DIR}/tools/generate.rb")
set(PREPROC  "${RIPPER_DIR}/tools/preproc.rb")

function(run_ruby)
  cmake_parse_arguments(A "" "INPUT_FILE;OUTPUT_FILE" "ARGS" ${ARGN})
  set(redirect "")
  if(A_INPUT_FILE)
    list(APPEND redirect INPUT_FILE "${A_INPUT_FILE}")
  endif()
  if(A_OUTPUT_FILE)
    list(APPEND redirect OUTPUT_FILE "${A_OUTPUT_FILE}")
  endif()
  execute_process(COMMAND ${RUBY} ${A_ARGS}
                  WORKING_DIRECTORY "${RIPPER_DIR}"
                  ${redirect}
                  COMMAND_ERROR_IS_FATAL ANY)
endfunction()

# Event id tables, derived from the parser grammar and from eventids2.c.
run_ruby(ARGS ${GENERATE} --mode=eventids1_h --ids1src=${SRC}/parse.y --output=eventids1.h)
run_ruby(ARGS ${GENERATE} --mode=eventids1   --ids1src=${SRC}/parse.y --output=eventids1.c)
run_ruby(ARGS ${GENERATE} --mode=eventids2table
              --ids2src=${RIPPER_DIR}/eventids2.c --output=eventids2table.c)

# parse.y -> ripper.y -> ripper.c. id2token.rb rewrites token names first, then
# preproc.rb strips the parts Ripper does not want.
run_ruby(ARGS ${SRC}/tool/id2token.rb ${SRC}/parse.y
         OUTPUT_FILE "${RIPPER_DIR}/tokenized_parse.y")
run_ruby(ARGS ${PREPROC} --output=ripper.y tokenized_parse.y)

# Lrama reads the grammar from stdin; the "-" argument is only the name used in
# diagnostics, which is why ripper.y appears twice.
run_ruby(ARGS ${SRC}/tool/lrama/exe/lrama -o ripper.c - ripper.y
         INPUT_FILE "${RIPPER_DIR}/ripper.y")

run_ruby(ARGS ${PREPROC} --output=ripper_init.c
              --template=${RIPPER_DIR}/ripper_init.c.tmpl ${SRC}/internal/ruby_parser.h)

file(REMOVE "${RIPPER_DIR}/tokenized_parse.y")

file(SIZE "${RIPPER_DIR}/ripper.c" size)
message(STATUS "cruby_generate_ripper: ripper.c is ${size} bytes")
