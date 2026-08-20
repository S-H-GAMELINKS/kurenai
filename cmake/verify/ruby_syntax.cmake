# cmake -DRUBY=<ruby> -DFILES=<a|b|c> -P ruby_syntax.cmake
#
# Parses every Ruby file that goes into the image, before anything is built.
#
# This exists because of an hour spent reading a page fault. A missing closing
# quote in ruby/userland/init.rb became a SyntaxError raised inside
# rb_eval_string_protect, and reporting it faulted -- so the symptom was a null
# dereference in CRuby's exception machinery, with no output at all, several
# layers away from the typo. The kernel has no compiler and no way to say
# "syntax error" from where that happens.
#
# The host Ruby has both. It parses the userland script with the same Prism the
# kernel embeds; the kernel's own Ruby is compiled by picorbc, whose failure is
# a build error already, but checking it here names the file and the line
# instead of failing inside a bytecode generator.
#
# Files are separated by "|", as elsewhere: add_test splits arguments on
# semicolons.

cmake_minimum_required(VERSION 3.25)

foreach(v RUBY FILES)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "ruby_syntax.cmake: -D${v}=... is required")
  endif()
endforeach()

string(REPLACE "|" ";" files "${FILES}")

set(bad "")
foreach(file IN LISTS files)
  if(NOT EXISTS "${file}")
    message(FATAL_ERROR "ruby_syntax: no such file: ${file}")
  endif()
  execute_process(COMMAND ${RUBY} -c "${file}"
                  RESULT_VARIABLE rc
                  OUTPUT_QUIET
                  ERROR_VARIABLE err)
  if(NOT rc EQUAL 0)
    list(APPEND bad "${file}\n${err}")
  endif()
endforeach()

if(bad)
  string(REPLACE ";" "\n" pretty "${bad}")
  message(FATAL_ERROR "Ruby that would go into the image does not parse:\n${pretty}")
endif()

list(LENGTH files n)
message(STATUS "ok: ${n} Ruby files parse")
