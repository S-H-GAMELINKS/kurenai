# cmake/deps/apply_patch.cmake
#
# Apply a patch to a git checkout. Script mode only:
#   cmake -DDIR=<dir> -DPATCH=<file> -P apply_patch.cmake
#
# Like fetch_sha.cmake, this is idempotent by resetting first rather than by
# detecting whether the patch is already applied. "git apply" fails on an
# already-patched tree, which would otherwise make re-running a patch step
# (cmake --build . -t musl-patch) an error instead of a no-op.
#
# Only tracked files are reverted, so build outputs and other untracked files
# are left alone.

cmake_minimum_required(VERSION 3.25)

foreach(v DIR PATCH)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "apply_patch.cmake: -D${v}=... is required")
  endif()
endforeach()
if(NOT EXISTS "${PATCH}")
  message(FATAL_ERROR "apply_patch.cmake: no such patch: ${PATCH}")
endif()

find_package(Git REQUIRED)

execute_process(COMMAND ${GIT_EXECUTABLE} checkout -f -- .
                WORKING_DIRECTORY ${DIR}
                COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND ${GIT_EXECUTABLE} apply "${PATCH}"
                WORKING_DIRECTORY ${DIR}
                COMMAND_ERROR_IS_FATAL ANY)

message(STATUS "apply_patch: ${PATCH} -> ${DIR}")
