/* What the machine says about memory.
 *
 * Deciding which pages a program gets, and taking them back, is
 * ruby/kernel/memory.rb. What it cannot find out from Ruby is here: where the
 * image ends, where the bootloader left its description of the machine, and
 * how much of the address space the boot stub mapped. Three facts, decided by
 * the linker, the bootloader and boot.S, and nothing that chooses between
 * them.
 *
 * musl's allocator is left in place rather than replaced. That matters more
 * than it looks: free() genuinely frees, and the kernel only has to supply the
 * pages underneath it. */

#include <stdint.h>

#include "kernel.h"

/* Placed by the linker script at the end of the image. */
extern char _end[];

/* Saved by kernel/entry64.S from what the boot stub passed in rdi. */
extern uint64_t boot_info_pointer;

/* The boot stub identity maps the low 4GB. Nothing above it can be handed out
 * however much RAM the machine has. */
#define MAPPED_LIMIT 0x100000000UL

uintptr_t
memory_image_end(void)
{
    return (uintptr_t)_end;
}

uintptr_t
memory_boot_info(void)
{
    return (uintptr_t)boot_info_pointer;
}

uintptr_t
memory_mapped_limit(void)
{
    return MAPPED_LIMIT;
}
