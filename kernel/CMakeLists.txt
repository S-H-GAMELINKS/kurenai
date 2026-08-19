# The kernel itself.
#
# Configured by the superbuild as a child project so it can use the bare-metal
# toolchain file, the same one the CRuby cross library uses.
#
# The build has two halves because the machine starts in 32-bit protected mode
# and the kernel is 64-bit:
#
#   kernel64.elf  the kernel, linked at 2MB
#   kernel64.bin  the same, as a flat image
#   kernel.elf    the 32-bit Multiboot stub with kernel64.bin embedded in it
#
# Only the 64-bit half is an ordinary CMake target. The stub is built with
# explicit commands: it is a different ABI, and a CMake project has one
# toolchain, so expressing it as a target would mean a second child project for
# a single assembly file.

cmake_minimum_required(VERSION 3.25)
project(picoruby_kernel LANGUAGES C ASM)

if(NOT BOOT_DIR)
  message(FATAL_ERROR "kernel: -DBOOT_DIR=<boot source dir> is required")
endif()

find_program(LLD_EXECUTABLE ld.lld REQUIRED)

# ---------------------------------------------------------------- 64-bit kernel
add_executable(kernel64.elf
  entry64.S
  main.c
  serial.c)

target_include_directories(kernel64.elf PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

target_link_options(kernel64.elf PRIVATE
  -nostdlib
  -static
  -fuse-ld=lld
  -Wl,-T,${CMAKE_CURRENT_SOURCE_DIR}/kernel64.ld
  # A build id would land in an allocated section and end up in the flat image.
  -Wl,--build-id=none)

set_target_properties(kernel64.elf PROPERTIES
  LINK_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/kernel64.ld)

# ---------------------------------------------------------------- flat image
# There is no loader on the other side, so program headers are of no use; the
# stub embeds the raw bytes and jumps to the first one.
add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/kernel64.bin
  COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:kernel64.elf>
          ${CMAKE_CURRENT_BINARY_DIR}/kernel64.bin
  DEPENDS kernel64.elf
  COMMENT "Flattening kernel64.elf")

# ---------------------------------------------------------------- 32-bit stub
# boot.S resolves "kernel64.bin" through the assembler's include path, which is
# why -I points at the build directory rather than the name being passed as a
# macro. Quoting a path through a preprocessor define survives neither CMake
# nor the shell reliably.
add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/boot.o
  COMMAND ${CMAKE_C_COMPILER} -m32 -c ${BOOT_DIR}/boot.S
          -I${CMAKE_CURRENT_BINARY_DIR}
          -o ${CMAKE_CURRENT_BINARY_DIR}/boot.o
  DEPENDS ${BOOT_DIR}/boot.S ${CMAKE_CURRENT_BINARY_DIR}/kernel64.bin
  COMMENT "Assembling the 32-bit Multiboot stub")

add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/kernel.elf
  COMMAND ${LLD_EXECUTABLE} -nostdlib -m elf_i386
          -z max-page-size=0x1000
          -T ${BOOT_DIR}/multiboot.ld
          -o ${CMAKE_CURRENT_BINARY_DIR}/kernel.elf
          ${CMAKE_CURRENT_BINARY_DIR}/boot.o
  DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/boot.o ${BOOT_DIR}/multiboot.ld
  COMMENT "Linking the bootable image")

add_custom_target(kernel ALL DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/kernel.elf)
