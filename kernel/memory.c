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

/* The boot stub identity maps the low 512MB. Stop short of the top to leave
 * room for anything that has to live at a fixed high address later. */
#define ARENA_LIMIT 0x1C000000UL   /* 448MB */

static uintptr_t arena_next;
static uintptr_t arena_end;

void
memory_init(void)
{
    /* Start on a 2MB boundary past the image, which keeps the arena clear of
     * the kernel's own BSS however large that grows. */
    uintptr_t start = ((uintptr_t)_end + 0x1FFFFF) & ~(uintptr_t)0x1FFFFF;
    arena_next = start;
    arena_end = ARENA_LIMIT;
}

void *
memory_alloc_pages(size_t length)
{
    size_t aligned = (length + 0xFFF) & ~(size_t)0xFFF;
    if (aligned == 0 || aligned > arena_end - arena_next) return 0;

    void *p = (void *)arena_next;
    arena_next += aligned;

    /* mmap promises zeroed pages, and musl's allocator relies on it. */
    __builtin_memset(p, 0, aligned);
    return p;
}

size_t
memory_used(void)
{
    return (size_t)(arena_next - (((uintptr_t)_end + 0x1FFFFF) & ~(uintptr_t)0x1FFFFF));
}

size_t
memory_available(void)
{
    return (size_t)(arena_end - arena_next);
}
