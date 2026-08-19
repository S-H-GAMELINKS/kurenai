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

  .rodata : { *(.rodata*) }
  .data   : { *(.data*) }

  .bss : {
    . = ALIGN(8);
    __bss64_start = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(8);
    __bss64_end = .;
  }
}
