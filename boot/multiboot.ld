/* Layout for the 32-bit Multiboot stub.
 *
 * The Multiboot header has to appear in the first 8KB of the file, so it comes
 * first. The 64-bit kernel image is placed at exactly 2MB, which is the
 * address the stub jumps to. */

ENTRY(_start)

SECTIONS
{
  . = 1M;

  .multiboot : { *(.multiboot) }

  .text : {
    *(.text.boot)
    *(.text*)
  }

  .rodata : { *(.rodata*) }
  .data   : { *(.data*) }

  . = ALIGN(4096);
  .bss : {
    __bss_start = .;
    *(.bss*)
    *(COMMON)
    __bss_end = .;
  }

  . = 2M;
  .kernel64 : { *(.kernel64) }
}
