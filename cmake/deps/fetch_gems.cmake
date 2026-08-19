# cmake -DBUNDLED_GEMS=<file> -DDEST=<dir> -DGEM=<gem executable> -DNAMES=<a,b>
#       -P fetch_gems.cmake
#
# Names are comma separated: a semicolon would be split into separate arguments
# on the way here, since CMake treats it as a list separator.
#
# Fetches bundled gems at the versions the pinned CRuby ships, and unpacks each
# under its bare name rather than name-version. The version belongs to this
# script; nothing downstream should have to know it, and a versioned directory
# would have to be resolved before the build has fetched anything.
#
# irb and reline are not in the CRuby source tree; gems/bundled_gems only lists
# their names, versions and repositories. The versions are read from that file
# rather than written here, so bumping CRuby moves them together. Taking them
# from the machine's installed gems instead would work here and nowhere else.

cmake_minimum_required(VERSION 3.25)

foreach(v BUNDLED_GEMS DEST GEM NAMES)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "fetch_gems.cmake: -D${v}=... is required")
  endif()
endforeach()

string(REPLACE "," ";" gem_names "${NAMES}")

file(STRINGS "${BUNDLED_GEMS}" lines)
file(MAKE_DIRECTORY "${DEST}")

foreach(name IN LISTS gem_names)
  set(version "")
  foreach(line IN LISTS lines)
    if(line MATCHES "^${name} +([0-9][^ ]*)")
      set(version "${CMAKE_MATCH_1}")
      break()
    endif()
  endforeach()
  if(NOT version)
    message(FATAL_ERROR "fetch_gems.cmake: ${name} is not listed in ${BUNDLED_GEMS}")
  endif()

  set(unpacked "${DEST}/${name}-${version}")
  set(final "${DEST}/${name}")
  if(EXISTS "${final}/.version-${version}")
    message(STATUS "fetch_gems: ${name} ${version} already present")
    continue()
  endif()
  file(REMOVE_RECURSE "${final}")

  message(STATUS "fetch_gems: fetching ${name} ${version}")
  execute_process(COMMAND ${GEM} fetch ${name} --version ${version}
                  WORKING_DIRECTORY "${DEST}"
                  COMMAND_ERROR_IS_FATAL ANY)
  execute_process(COMMAND ${GEM} unpack "${DEST}/${name}-${version}.gem"
                  WORKING_DIRECTORY "${DEST}"
                  COMMAND_ERROR_IS_FATAL ANY)
  if(NOT EXISTS "${unpacked}")
    message(FATAL_ERROR "fetch_gems: ${name} did not unpack to ${unpacked}")
  endif()
  file(RENAME "${unpacked}" "${final}")
  file(WRITE "${final}/.version-${version}" "${version}\n")
endforeach()
