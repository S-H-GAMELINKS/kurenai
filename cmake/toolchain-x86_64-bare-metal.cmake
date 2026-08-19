# Toolchain for everything that ends up inside the kernel image: the CRuby
# cross library now, the kernel itself later.
#
# Pass MUSL_INSTALL when configuring; the target libc is musl, not the host's.

set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

# NOTE:
# CMake checks a compiler by linking a test executable. Nothing can be linked
# for this target without the kernel's own linker script, so the check is told
# to build a static library instead. Without this, configure fails before
# reaching any of the project's own code.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# NOTE:
# CMake re-reads this file inside the small projects it generates for compiler
# detection, and those do not inherit the cache. MUSL_INSTALL has to be listed
# explicitly or the include path is empty exactly when the compiler is being
# probed, which fails with a message about the compiler rather than the path.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES MUSL_INSTALL)

if(NOT MUSL_INSTALL)
  message(FATAL_ERROR "toolchain: -DMUSL_INSTALL=<musl install prefix> is required")
endif()

find_program(CMAKE_C_COMPILER clang REQUIRED)
find_program(CMAKE_ASM_COMPILER clang REQUIRED)
find_program(CMAKE_AR llvm-ar REQUIRED)
find_program(CMAKE_RANLIB llvm-ranlib REQUIRED)
find_program(CMAKE_OBJCOPY llvm-objcopy REQUIRED)

# clang's own headers (stddef.h, stdarg.h and friends) still belong on the
# include path under -nostdinc; only the C library headers change.
execute_process(COMMAND ${CMAKE_C_COMPILER} -print-resource-dir
                OUTPUT_VARIABLE CLANG_RESOURCE_DIR
                OUTPUT_STRIP_TRAILING_WHITESPACE
                COMMAND_ERROR_IS_FATAL ANY)

# These have to stay in step with picoruby_build/x86_64-bare-metal.rb. Objects
# compiled with different assumptions about pointer size, PIC or struct layout
# link successfully and then fail at run time.
set(BARE_METAL_FLAGS
    "-ffreestanding -fno-builtin -fno-stack-protector -fno-pic -m64 \
-nostdinc -isystem ${CLANG_RESOURCE_DIR}/include -isystem ${MUSL_INSTALL}/include")

set(CMAKE_C_FLAGS_INIT "${BARE_METAL_FLAGS}")
# Assembly needs the same treatment. Without -nostdinc the assembler resolves
# includes against the host's /usr/include and reports C declarations as
# invalid instruction mnemonics, which reads like a broken assembler rather
# than a wrong include path.
set(CMAKE_ASM_FLAGS_INIT "${BARE_METAL_FLAGS}")

# Nothing on the target comes from the host filesystem.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BEFORE)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
