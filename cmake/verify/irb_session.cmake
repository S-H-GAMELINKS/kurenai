# cmake -DRUBY=<ruby> -DDRIVER=<terminal_driver.rb> -DQEMU=<qemu> -DKERNEL=<elf>
#       -DINPUT=<file> -DLOG=<file> -DEXPECT=<a|b|c> [-DSECONDS=n] [-DUNTIL=re]
#       [-DWAKE=re]
#       -P irb_session.cmake
#
# Drives irb through a stand-in terminal and checks what came back.
#
# A pipe cannot be the far end here. Reline asks the terminal where the cursor
# is and waits for the answer, so piping input in stalls at the first prompt,
# and TERM=dumb -- which avoids the question -- would test the path that never
# touches the terminal. test/terminal_driver.rb answers instead.

cmake_minimum_required(VERSION 3.25)

foreach(v RUBY DRIVER QEMU KERNEL INPUT LOG EXPECT)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "irb_session.cmake: -D${v}=... is required")
  endif()
endforeach()
if(NOT DEFINED SECONDS)
  set(SECONDS 60)
endif()

set(driver_args ${DRIVER}
    --qemu ${QEMU} --kernel ${KERNEL} --log ${LOG} --input ${INPUT}
    --seconds ${SECONDS})
# The kernel boots into its web server and stays there, so a test that wants
# irb has to say so first. Anything on the console ends the accept loop.
if(DEFINED WAKE)
  list(APPEND driver_args --wake ${WAKE})
endif()
if(DEFINED UNTIL)
  list(APPEND driver_args --until ${UNTIL})
endif()

execute_process(COMMAND ${RUBY} ${driver_args}
                OUTPUT_QUIET
                RESULT_VARIABLE rc
                ERROR_VARIABLE err)

if(NOT EXISTS "${LOG}")
  message(FATAL_ERROR "the driver produced no log (result: ${rc})\n${err}")
endif()

file(READ "${LOG}" raw_session)

# Reline redraws the line as it is edited, so the byte stream carries the text
# interleaved with cursor movements and colour changes. What matters is what
# the terminal would show, so the escape sequences come out before matching.
string(ASCII 27 ESC)
string(REGEX REPLACE "${ESC}\\[[0-9;?]*[a-zA-Z]" "" session "${raw_session}")
string(REGEX REPLACE "${ESC}[()][A-Z0-9]" "" session "${session}")

string(REPLACE "|" ";" patterns "${EXPECT}")
set(unmatched "")
foreach(pattern IN LISTS patterns)
  if(NOT session MATCHES "${pattern}")
    list(APPEND unmatched "${pattern}")
  endif()
endforeach()

if(unmatched)
  string(REPLACE ";" "\n  " pretty "${unmatched}")
  message(FATAL_ERROR
    "irb did not produce:\n  ${pretty}\n"
    "the session was:\n${session}\n${err}")
endif()

list(LENGTH patterns n)
message(STATUS "ok: irb answered all ${n} expectations")
