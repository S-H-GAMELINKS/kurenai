/* Replacements for musl's hand-written syscall assembly.
 *
 * Five files in musl issue the syscall instruction directly and are therefore
 * untouched by patches/musl.patch. Linking CRuby pulls four of them in, by way
 * of pthread_create, sigaction and TLS setup. None is reached in practice, but
 * "not reached" is an argument, and reaching one would fault with nothing to
 * explain why.
 *
 * Defining the same symbols here removes the argument. These are ordinary
 * objects rather than archive members, so the linker takes them and never
 * extracts musl's; each of those objects defines exactly one symbol, so
 * nothing else is lost with it. verify_kernel_no_syscall_insn then holds at
 * zero, and holds for a reason rather than by luck. */

#include <errno.h>
#include <stdint.h>

#include "kernel.h"

#define IA32_FS_BASE 0xC0000100

/* Sets the thread pointer. musl calls this from __init_tls; the kernel also
 * sets FS directly during boot, before libc is used at all. Doing it with
 * wrmsr is what the real one does through arch_prctl. */
int
__set_thread_area(void *p)
{
    uint64_t addr = (uint64_t)(uintptr_t)p;
    __asm__ volatile ("wrmsr"
                      :
                      : "c"(IA32_FS_BASE),
                        "a"((uint32_t)(addr & 0xFFFFFFFFu)),
                        "d"((uint32_t)(addr >> 32)));
    return 0;
}

/* Thread creation. There is one CPU, no scheduler and no second stack, so this
 * refuses rather than pretending. pthread_create turns the negative return
 * into EAGAIN, which callers are required to handle. */
int
__clone(int (*func)(void *), void *stack, int flags,
        void *arg, void *ptid, void *tls, void *ctid)
{
    (void)func; (void)stack; (void)flags;
    (void)arg; (void)ptid; (void)tls; (void)ctid;
    return -EAGAIN;
}

/* The signal return trampoline. Only ever entered by a kernel delivering a
 * signal, and nothing here delivers signals, so arriving is a bug worth
 * stopping on rather than continuing past. */
void
__restore_rt(void)
{
    serial_puts("kernel: __restore_rt reached, but no signal was delivered\n");
    for (;;) __asm__ volatile ("cli; hlt");
}

/* Unmaps a thread's own stack as it exits. Unreachable while __clone refuses. */
void
__unmapself(void *base, unsigned long size)
{
    (void)base; (void)size;
    serial_puts("kernel: __unmapself reached, but no thread was ever created\n");
    for (;;) __asm__ volatile ("cli; hlt");
}
