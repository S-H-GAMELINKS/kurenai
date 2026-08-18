# cmake/deps/fetch_sha.cmake
#
# Shallow-fetch a pinned commit SHA. Script mode only:
#   cmake -DDIR=<dir> -DURL=<url> -DREF=<40hex> -P fetch_sha.cmake
#
# On idempotency:
#   This script is idempotent because it unconditionally resets to REF, not
#   because it detects what changed. Detect-and-branch logic cannot recover
#   once the tree has drifted through an interrupted run or a manual edit.

cmake_minimum_required(VERSION 3.25)

foreach(v DIR URL REF)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "fetch_sha.cmake: -D${v}=... is required")
  endif()
endforeach()

# "git fetch" cannot resolve an abbreviated SHA, so catch the mistake here
# rather than in a confusing git error. CMake regular expressions have no {n}
# repetition operator, hence the explicit length check.
string(LENGTH "${REF}" _ref_len)
if(NOT _ref_len EQUAL 40 OR NOT REF MATCHES "^[0-9a-f]+$")
  message(FATAL_ERROR
    "fetch_sha.cmake: REF must be a full 40-hex SHA (given: ${REF})\n"
    "An abbreviated SHA fails with \"fatal: couldn't find remote ref\".")
endif()

find_package(Git REQUIRED)

# Run git, tolerating failure.
function(git_try out_rc)
  execute_process(COMMAND ${GIT_EXECUTABLE} ${ARGN}
                  WORKING_DIRECTORY ${DIR}
                  RESULT_VARIABLE rc)
  set(${out_rc} ${rc} PARENT_SCOPE)
endfunction()

# Run git, aborting on failure.
function(git_run)
  execute_process(COMMAND ${GIT_EXECUTABLE} ${ARGN}
                  WORKING_DIRECTORY ${DIR}
                  COMMAND_ERROR_IS_FATAL ANY)
endfunction()

if(NOT EXISTS "${DIR}/.git")
  message(STATUS "fetch_sha: initializing ${DIR}")
  file(MAKE_DIRECTORY "${DIR}")
  git_run(init -q .)
  git_run(remote add origin "${URL}")
else()
  # Follow along when the URL is changed in versions.cmake.
  git_run(remote set-url origin "${URL}")
endif()

# Skip the network entirely when the commit is already present, so a rebuild
# after "rm -rf build" works offline.
git_try(have cat-file -e "${REF}^{commit}")
if(NOT have EQUAL 0)
  message(STATUS "fetch_sha: shallow fetching ${REF}")
  git_try(rc fetch --depth 1 origin "${REF}")
  if(NOT rc EQUAL 0)
    # Fallback for servers that refuse to serve an arbitrary SHA directly.
    message(STATUS "fetch_sha: shallow fetch failed, falling back to full fetch")
    git_run(fetch origin)
  endif()
endif()

# Always force the tree back to the pinned ref. This is what structurally
# prevents "the patch got applied twice" once patch steps are added.
#
# Keep clean at -fd, not -ffd: -fd skips directories that are separate git
# repositories, so submodules initialized by the later patch step (PicoRuby's
# mruby, prism and friends) survive. -ffd would delete them and force a
# re-fetch on every run.
git_run(checkout -f "${REF}")
git_run(clean -fdq)

message(STATUS "fetch_sha: ${DIR} @ ${REF}")
