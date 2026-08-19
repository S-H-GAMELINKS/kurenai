# cmake -DINPUT=<file> -DOUTPUT=<file.c> -DSYMBOL=<name> -P embed_script.cmake
#
# Turns a text file into a C string constant. Used for Ruby source the kernel
# evaluates at boot: there is no filesystem to read it from, and escaping it by
# hand in a C file would put the same text in two places.

cmake_minimum_required(VERSION 3.25)

foreach(v INPUT OUTPUT SYMBOL)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "embed_script.cmake: -D${v}=... is required")
  endif()
endforeach()

file(READ "${INPUT}" text)

# Order matters: backslashes first, or the escapes added below get escaped too.
string(REPLACE "\\" "\\\\" text "${text}")
string(REPLACE "\"" "\\\"" text "${text}")
string(REPLACE "\n" "\\n\"\n\"" text "${text}")

file(WRITE "${OUTPUT}"
  "/* Generated from ${INPUT}. Do not edit. */\n"
  "const char ${SYMBOL}[] =\n\"${text}\";\n")
