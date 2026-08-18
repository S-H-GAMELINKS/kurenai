# cmake/deps/musl_strip_objects.cmake
#
# Produce lib/libc_kernel.a from lib/libc.a by dropping the allocator and
# memory-mapping objects. Script mode only:
#   cmake -DDIR=<musl src> -DLLVM_AR=<llvm-ar> -P musl_strip_objects.cmake
#
# Two libc flavours are needed:
#   install/lib/libc.a  full musl. Used by the PicoRuby-only kernel, which has
#                       no allocator of its own.
#   lib/libc_kernel.a   used once CRuby is linked in, where the kernel supplies
#                       malloc and mmap itself. Keeping musl's versions would
#                       give duplicate definitions at link time.
#
# NOTE:
# pthread objects are deliberately NOT dropped. musl defines pthread_create and
# friends as weak symbols, so the kernel's own single-threaded stubs win at link
# time, while musl-internal locking still resolves. Dropping them risks breaking
# references from stdio that nothing else provides. (The reference project
# appears to strip them, but its regex ends in "pthread_\." which cannot match
# "pthread_create.lo", so in practice it does not.)

cmake_minimum_required(VERSION 3.25)

foreach(v DIR LLVM_AR)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "musl_strip_objects.cmake: -D${v}=... is required")
  endif()
endforeach()

set(FULL_LIB   "${DIR}/lib/libc.a")
set(KERNEL_LIB "${DIR}/lib/libc_kernel.a")
if(NOT EXISTS "${FULL_LIB}")
  message(FATAL_ERROR "musl_strip_objects.cmake: no such archive: ${FULL_LIB}")
endif()

# Object names are matched exactly. musl ships some names twice: free.lo and
# realloc.lo exist under both src/malloc and src/malloc/mallocng, and "llvm-ar d"
# removes only one member per name per invocation. Hence the loop below, which
# re-lists and repeats until nothing matches; deleting a deduplicated list once
# would silently leave the second copy behind.
set(DROP_PATTERN "^(malloc|calloc|realloc|free|memalign|posix_memalign|aligned_alloc|malloc_usable_size|malloc_trim|lite_malloc|expand_heap|donate|mmap|munmap|mprotect|mremap|madvise)\\.lo$")

file(COPY_FILE "${FULL_LIB}" "${KERNEL_LIB}")

set(removed 0)
set(MAX_PASSES 8)
foreach(pass RANGE 1 ${MAX_PASSES})
  execute_process(COMMAND ${LLVM_AR} t "${KERNEL_LIB}"
                  OUTPUT_VARIABLE members
                  OUTPUT_STRIP_TRAILING_WHITESPACE
                  COMMAND_ERROR_IS_FATAL ANY)
  string(REPLACE "\n" ";" members "${members}")

  set(drop "")
  foreach(m IN LISTS members)
    if(m MATCHES "${DROP_PATTERN}")
      list(APPEND drop "${m}")
    endif()
  endforeach()
  list(REMOVE_DUPLICATES drop)

  if(NOT drop)
    break()
  endif()

  execute_process(COMMAND ${LLVM_AR} d "${KERNEL_LIB}" ${drop}
                  COMMAND_ERROR_IS_FATAL ANY)
  list(LENGTH drop n)
  math(EXPR removed "${removed} + ${n}")
endforeach()

if(removed EQUAL 0)
  message(FATAL_ERROR
    "musl_strip_objects.cmake: nothing matched, so libc_kernel.a would be a\n"
    "plain copy of libc.a. musl's object naming probably changed.")
endif()

message(STATUS "musl_strip_objects: removed ${removed} objects -> ${KERNEL_LIB}")
