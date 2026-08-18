# cmake -DPICORBC=<picorbc> -DWORKDIR=<dir> -P picorbc_compiles.cmake
#
# Compiles a snippet of Ruby to bytecode. This is the end-to-end proof that the
# compiler works: the nested prism submodule was initialized, the templates
# were generated, and the binary runs. Checking that bin/picorbc merely exists
# does not establish any of that.

cmake_minimum_required(VERSION 3.25)

foreach(v PICORBC WORKDIR)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "picorbc_compiles.cmake: -D${v}=... is required")
  endif()
endforeach()

set(src "${WORKDIR}/picorbc_smoke.rb")
set(out "${WORKDIR}/picorbc_smoke.mrb")
file(WRITE "${src}" "x = 0\n3.times { |i| x += i }\nputs x\n")
file(REMOVE "${out}")

execute_process(COMMAND ${PICORBC} -o "${out}" "${src}"
                RESULT_VARIABLE rc
                OUTPUT_VARIABLE out_txt
                ERROR_VARIABLE err_txt)
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "picorbc failed (${rc}):\n${out_txt}${err_txt}")
endif()
if(NOT EXISTS "${out}")
  message(FATAL_ERROR "picorbc reported success but produced no ${out}")
endif()

# mruby bytecode starts with the RITE magic.
file(READ "${out}" magic LIMIT 4 HEX)
if(NOT magic STREQUAL "52495445")
  message(FATAL_ERROR "${out} does not start with the RITE magic (got ${magic})")
endif()

file(SIZE "${out}" size)
message(STATUS "ok: picorbc produced ${size} bytes of RITE bytecode")
