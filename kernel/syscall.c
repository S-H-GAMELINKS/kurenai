/* The bottom of the C library.
 *
 * musl is patched so every syscall becomes a call to kernel_syscall() rather
 * than the syscall instruction, which has nothing to trap into here. This file
 * is the whole of the kernel below libc: what a program running on this system
 * can actually ask for.
 *
 * Only what the VM reaches on the way up is implemented. Anything else returns
 * -ENOSYS and says so on the console, which turns "the kernel hangs" into "the
 * kernel was asked for syscall 218". */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/syscall.h>

#include "kernel.h"

/* musl's stdio allocates its buffers. mruby does not use this: it allocates
 * from the pool the kernel hands the VM. */
#define HEAP_SIZE (16u * 1024u * 1024u)
static uint8_t heap[HEAP_SIZE];
static size_t heap_used;

static long
sys_write(int fd, const char *buf, size_t count)
{
    /* stdout and stderr are the serial console. Nothing else is open. */
    if (fd != 1 && fd != 2) return -EBADF;
    serial_write(buf, count);
    return (long)count;
}

static long
sys_writev(int fd, const void *iov_base, int iovcnt)
{
    const struct { const char *base; size_t len; } *iov = iov_base;
    long total = 0;
    for (int i = 0; i < iovcnt; i++) {
        long n = sys_write(fd, iov[i].base, iov[i].len);
        if (n < 0) return n;
        total += n;
    }
    return total;
}

/* A bump allocator. Nothing is ever unmapped, which is fine while the only
 * caller is musl's stdio setting up a handful of buffers. It stops being fine
 * once CRuby's garbage collector is above it, and is replaced then. */
static long
sys_mmap(size_t length)
{
    size_t aligned = (length + 0xFFF) & ~(size_t)0xFFF;
    if (aligned > HEAP_SIZE - heap_used) return -ENOMEM;
    void *p = &heap[heap_used];
    heap_used += aligned;
    return (long)(uintptr_t)p;
}

static void
report_unhandled(long n)
{
    char digits[24];
    int i = 0;
    if (n < 0) { serial_putc('-'); n = -n; }
    if (n == 0) digits[i++] = '0';
    while (n > 0 && i < (int)sizeof(digits)) {
        digits[i++] = (char)('0' + (n % 10));
        n /= 10;
    }
    serial_puts("kernel: unhandled syscall ");
    while (i-- > 0) serial_putc(digits[i]);
    serial_putc('\n');
}

long
kernel_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6)
{
    (void)a4; (void)a5; (void)a6;

    switch (n) {
    case SYS_write:
        return sys_write((int)a1, (const char *)a2, (size_t)a3);
    case SYS_writev:
        return sys_writev((int)a1, (const void *)a2, (int)a3);
    case SYS_mmap:
        return sys_mmap((size_t)a2);
    case SYS_munmap:
        return 0;               /* the bump allocator has nothing to give back */
    case SYS_brk:
        return -ENOMEM;         /* musl falls back to mmap */
    case SYS_exit:
    case SYS_exit_group:
        serial_puts("kernel: halted\n");
        for (;;) __asm__ volatile ("cli; hlt");
    case SYS_ioctl:
        return -ENOTTY;         /* the console is not a tty yet */
    default:
        report_unhandled(n);
        return -ENOSYS;
    }
}
