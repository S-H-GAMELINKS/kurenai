/* Replacements for musl's hand-written syscall assembly.
 *
 * Five files in musl issue the syscall instruction directly and are therefore
 * untouched by patches/musl.patch. Linking CRuby pulls four of them in, by way
 * of pthread_create, sigaction and TLS setup, and two of them -- __clone and
 * __unmapself -- are now how every thread starts and ends. musl's would trap
 * into a kernel with the syscall instruction; here the kernel is a function
 * call away.
 *
 * Defining the same symbols here is what makes that so. These are ordinary
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

/* Thread creation: kernel/task.c. musl's clone.s would trap into a kernel
 * with the syscall instruction and then, in the child, call func(arg); here
 * the kernel is a function call away and does both. */
int
__clone(int (*func)(void *), void *stack, int flags,
        void *arg, void *ptid, void *tls, void *ctid)
{
    return (int)task_clone(func, stack, flags, arg, ptid, tls, ctid);
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

/* Unmaps a thread's own stack as it exits -- how every detached thread ends,
 * and CRuby's threads are all detached. The stack is the one being stood on,
 * so the task that runs next gives it back. */
void
__unmapself(void *base, unsigned long size)
{
    task_exit_unmapping(base, size);
}
