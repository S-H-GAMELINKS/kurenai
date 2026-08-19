/* The parts of libc startup the kernel has to do itself.
 *
 * musl normally reaches a usable state through __libc_start_main, which sets
 * up the thread pointer and records the auxiliary vector the kernel handed the
 * process. Nothing calls it here: CRuby is entered directly, not executed as a
 * program. So the same ground has to be covered by hand, and anything missed
 * shows up much later as libc reading through a pointer nobody set.
 *
 * Both of the things done here were found that way. */

#include <stddef.h>
#include <stdint.h>

#include "kernel.h"

#define IA32_FS_BASE 0xC0000100

/* ---------------------------------------------------------------- TLS
 *
 * musl reaches errno through the thread pointer: __errno_location() returns a
 * field of the pthread struct that FS points at. There is one thread, so one
 * statically allocated block is enough, and musl only requires that the
 * pointer's first field points at itself. The rest stays zero, which is the
 * state a single-threaded program with no cancellation wants anyway.
 *
 * On x86_64 the TLS block sits below the thread pointer, at negative offsets,
 * and the pthread struct sits at the pointer itself. Putting the pointer in
 * the middle leaves room on both sides without having to know either size. */
static unsigned char tls_block[8192] __attribute__((aligned(4096)));

/* ---------------------------------------------------------------- auxv
 *
 * musl's allocator scans the auxiliary vector for AT_RANDOM to seed itself.
 * With __libc.auxv left null it walked from address zero, which the boot stub
 * used to map -- so it read zeros, found no entries, and carried on. Unmapping
 * the page turned that into a fault, which is how it was noticed at all.
 *
 * Only the head of struct __libc is declared, up to the field being set. The
 * layout has to match musl's, and it is checked below rather than trusted. */
struct musl_libc_head {
    char                 can_do_threads;
    char                 threaded;
    char                 secure;
    volatile signed char need_locks;
    int                  threads_minus_1;
    size_t              *auxv;
};

extern struct musl_libc_head __libc;

_Static_assert(offsetof(struct musl_libc_head, auxv) == 8,
               "struct __libc layout must match musl's");

#define AT_NULL   0
#define AT_PAGESZ 6
#define AT_RANDOM 25

static unsigned char random_bytes[16];
static size_t auxv[] = {
    AT_PAGESZ, 4096,
    AT_RANDOM, 0,     /* filled in below; the address is not a constant */
    AT_NULL,   0,
};

void
libc_init(void)
{
    void *tp = tls_block + sizeof(tls_block) / 2;

    /* musl's __pthread_self() reads this self-pointer. */
    *(void **)tp = tp;

    uint64_t address = (uint64_t)(uintptr_t)tp;
    __asm__ volatile ("wrmsr"
                      :
                      : "c"(IA32_FS_BASE),
                        "a"((uint32_t)(address & 0xFFFFFFFFu)),
                        "d"((uint32_t)(address >> 32)));

    /* Not unpredictable, and not claimed to be: the timer is all there is this
     * early. It is enough for the allocator, which only wants the bytes to
     * differ between builds, and nothing here depends on secrecy. */
    uint64_t seed = timer_nanos() | 1u;
    for (size_t i = 0; i < sizeof(random_bytes); i++) {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        random_bytes[i] = (unsigned char)seed;
    }

    auxv[3] = (size_t)(uintptr_t)random_bytes;
    __libc.auxv = auxv;
}
