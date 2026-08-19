/* Layout for the 64-bit kernel.
 *
 * Loaded at 2MB, which is where the Multiboot stub jumps. The image is
 * extracted from this ELF as a flat binary and embedded in the stub, so there
 * is no loader to interpret program headers at run time. */

ENTRY(_start64)

SECTIONS
{
  . = 0x200000;

  .text : {
    *(.text.entry)
    *(.text*)
  }

  /* mruby decides whether a pointer is read-only data with
   *     &etext < p && p < &edata
   * (mrbconf.h turns that on for __linux__, which clang defines for this
   * target). Bytecode and string literals live in .rodata and must fall inside
   * the range so mruby treats them as static and does not copy them; the VM
   * pool lives in .bss and must fall outside. Placing etext after .text and
   * edata after .data gives exactly that. */
  etext = .;

  .rodata : { *(.rodata*) }
  .data   : { *(.data*) }

  edata = .;

  .bss : {
    . = ALIGN(8);
    __bss64_start = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(8);
    __bss64_end = .;
  }

  /* Where the image stops and free RAM begins. kernel/memory.c hands out pages
   * from here upwards. */
  _end = .;
}
