/* Thread-local storage for musl.
 *
 * musl reaches errno through the thread pointer: __errno_location() returns a
 * field of the pthread struct that FS points at. Nothing has set FS at this
 * point, so every errno access would land at physical address 0, which is
 * mapped here and therefore corrupts memory silently instead of faulting.
 *
 * There is one thread, so one statically allocated block is enough. musl only
 * requires that the thread pointer's first field points at itself; the rest of
 * the structure stays zero, which is the state a single-threaded program with
 * no cancellation wants anyway. */

#include <stdint.h>

#include "kernel.h"

#define IA32_FS_BASE 0xC0000100

/* On x86_64 the TLS block sits *below* the thread pointer, at negative offsets,
 * and the pthread struct sits at the pointer itself. Placing the pointer in the
 * middle leaves room on both sides without having to know either size. */
static unsigned char tls_block[8192] __attribute__((aligned(4096)));

void
tls_init(void)
{
    void *tp = tls_block + sizeof(tls_block) / 2;

    /* musl's __pthread_self() reads this self-pointer. */
    *(void **)tp = tp;

    uint64_t addr = (uint64_t)(uintptr_t)tp;
    __asm__ volatile ("wrmsr"
                      :
                      : "c"(IA32_FS_BASE),
                        "a"((uint32_t)(addr & 0xFFFFFFFFu)),
                        "d"((uint32_t)(addr >> 32)));
}
