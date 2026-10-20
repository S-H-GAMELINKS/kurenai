/* The parts of libc startup the kernel has to do itself.
 *
 * musl normally reaches a usable state through __libc_start_main, which sets
 * up the thread pointer and records the auxiliary vector the kernel handed the
 * process. Nothing calls it here: CRuby is entered directly, not executed as a
 * program. So the same ground has to be covered by hand, and anything missed
 * shows up much later as libc reading through a pointer nobody set.
 *
 * Everything done here was found that way. */

#include <elf.h>
#include <stddef.h>
#include <stdint.h>

#include "kernel.h"

#define IA32_FS_BASE 0xC0000100

/* ---------------------------------------------------------------- TLS
 *
 * musl reaches errno through the thread pointer, and rather more besides: the
 * per-thread locale, which strerror uses, and the robust mutex list. And
 * CRuby keeps its current execution context in a _Thread_local, so every
 * thread needs its own copy of the TLS segment, laid out the way the linker
 * assumed when it compiled %fs-relative accesses into the image.
 *
 * musl knows how to do all of that -- from the PT_TLS program header the
 * kernel would normally pass in the auxiliary vector. There is no loader
 * here and the headers are not in the image, so kernel64.ld states the
 * segment's extent as symbols, a header is built from them below, and musl's
 * own __init_tls is handed it: it records the TLS image for pthread_create's
 * __copy_tls, lays out the main thread's block, and installs the thread
 * pointer through __set_thread_area, which kernel/musl_stubs.c provides.
 *
 * Reaching for a library's internal initialiser is not obviously right, but
 * the alternative is hand-computing struct pthread's size and the variant II
 * layout, and keeping both in step with a musl the build pins anyway. */
extern char __tls_start[], __tls_filesz[], __tls_memsz[], __tls_align[];

void __init_tls(size_t *aux);

static Elf64_Phdr program_headers[1];

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

static unsigned char random_bytes[16];
static size_t auxv[] = {
    AT_PAGESZ, 4096,
    AT_RANDOM, 0,     /* filled in below; the address is not a constant */
    AT_PHDR,   0,     /* likewise */
    AT_PHENT,  sizeof(Elf64_Phdr),
    AT_PHNUM,  1,
    AT_NULL,   0,
};

void
libc_init(void)
{
    /* The symbols' addresses are the values: kernel64.ld assigns numbers, not
     * locations. */
    program_headers[0] = (Elf64_Phdr){
        .p_type   = PT_TLS,
        .p_vaddr  = (uintptr_t)__tls_start,
        .p_filesz = (uintptr_t)__tls_filesz,
        .p_memsz  = (uintptr_t)__tls_memsz,
        .p_align  = (uintptr_t)__tls_align,
    };
    auxv[5] = (size_t)(uintptr_t)program_headers;

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

    /* Lays out the main thread's TLS, sets the self-pointer, the locale, the
     * robust list and the thread id, and installs the thread pointer. The
     * block fits in musl's own static buffer, which matters: the alternative
     * is mmap, and pages are not served this early. It also concludes, from
     * the thread pointer being installable, that threads can be created --
     * which is now true. */
    __init_tls(auxv);
}
