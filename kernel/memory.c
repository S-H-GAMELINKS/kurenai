/* The memory the kernel hands out through mmap.
 *
 * musl's allocator is left in place rather than replaced. That matters more
 * than it looks: a bump allocator that never reuses memory is fine for running
 * a script once and fatal for a long-lived REPL, where every keystroke
 * allocates. Keeping mallocng means free() genuinely frees, and the kernel only
 * has to supply the pages underneath it.
 *
 * Those pages come from RAM above the kernel image. It is already identity
 * mapped by the boot stub, so there is nothing to map: handing out an address
 * is the whole of it. */

#include <stdint.h>

#include "kernel.h"

/* Placed by the linker script at the end of the image. */
extern char _end[];

/* The boot stub identity maps the low 4GB, but only what the machine actually
 * has can be handed out. */
#define MAPPED_LIMIT 0x100000000UL

/* Saved by kernel/entry64.S from what the boot stub passed in rdi. Multiboot's
 * information structure begins with flags, then the low and high memory sizes
 * in kilobytes. */
extern uint64_t boot_info_pointer;

struct multiboot_info {
    uint32_t flags;
    uint32_t mem_lower;   /* KB below 1MB */
    uint32_t mem_upper;   /* KB above 1MB */
};

#define MULTIBOOT_FLAG_MEMORY 0x01

static uintptr_t arena_start;
static uintptr_t arena_next;
static uintptr_t arena_end;

void
memory_init(void)
{
    /* Start on a 2MB boundary past the image, which keeps the arena clear of
     * the kernel's own BSS however large that grows. */
    arena_start = ((uintptr_t)_end + 0x1FFFFF) & ~(uintptr_t)0x1FFFFF;
    arena_next = arena_start;

    /* Ask the bootloader how much memory there is rather than assuming. The
     * amount matters: CRuby's garbage collector reserves its heap in one
     * mapping, and this kernel cannot reserve address space without also
     * committing the memory behind it. */
    arena_end = 0x20000000UL;   /* 512MB, if nothing better is known */

    const struct multiboot_info *info =
        (const struct multiboot_info *)(uintptr_t)boot_info_pointer;
    if (info && (info->flags & MULTIBOOT_FLAG_MEMORY)) {
        uint64_t top = 0x100000UL + (uint64_t)info->mem_upper * 1024UL;
        if (top > MAPPED_LIMIT) top = MAPPED_LIMIT;
        /* Leave the last 2MB alone; nothing should be handed the very top. */
        if (top > 0x200000UL) arena_end = (uintptr_t)(top - 0x200000UL);
    }
}

void *
memory_alloc_pages(size_t length)
{
    size_t aligned = (length + 0xFFF) & ~(size_t)0xFFF;
    if (aligned == 0 || aligned > arena_end - arena_next) {
        /* Running out here is not a condition the caller can do anything
         * about, and the message it would print needs an allocation of its
         * own. Say so directly. */
        serial_puts("memory: cannot serve ");
        serial_put_uint(aligned);
        serial_puts(" bytes, ");
        serial_put_uint(arena_end - arena_next);
        serial_puts(" left\n");
        return 0;
    }

#ifdef MEMORY_TRACE
    serial_puts("mmap ");
    serial_put_uint(aligned);
    serial_putc('\n');
#endif
    void *p = (void *)arena_next;
    arena_next += aligned;

    /* mmap promises zeroed pages, and musl's allocator relies on it. */
    __builtin_memset(p, 0, aligned);
    return p;
}

/* The range handed out so far. Pages inside it may be given back through
 * munmap; anything outside it -- the image, the files served from it, memory
 * not yet handed out -- is not the arena's to take back. */
uintptr_t
memory_arena_start(void)
{
    return arena_start;
}

uintptr_t
memory_arena_next(void)
{
    return arena_next;
}

size_t
memory_used(void)
{
    return (size_t)(arena_next - arena_start);
}

size_t
memory_available(void)
{
    return (size_t)(arena_end - arena_next);
}

/* Reported at boot, because "how much is there" is the first question asked
 * when an allocation fails and the last one anyone can answer afterwards. */
void
serial_report_memory(void)
{
    serial_puts("memory: arena ");
    serial_put_uint(memory_available() / (1024 * 1024));
    serial_puts(" MB free\n");
}
