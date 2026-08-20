/* The bottom of the C library.
 *
 * musl is patched so every syscall becomes a call to kernel_syscall() rather
 * than the syscall instruction, which has nothing to trap into here. This file
 * is the whole of the kernel below libc: what a program running on this system
 * can actually ask for.
 *
 * Only what CRuby and the VM reach on the way up is implemented. Anything else
 * returns -ENOSYS and names itself on the console, which turns "the kernel
 * hangs" into "the kernel was asked for syscall 218".
 *
 * The policy half is moving into Ruby a syscall at a time; see kernel/bridge.c
 * and ruby/kernel/syscall.rb. What stays here is the mechanism half -- memory,
 * time, the CPU -- and everything not yet moved. */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/syscall.h>

#include "kernel.h"

#define IA32_FS_BASE 0xC0000100
#define IA32_GS_BASE 0xC0000101

#define ARCH_SET_GS 0x1001
#define ARCH_SET_FS 0x1002

struct iovec_compat {
    const char *base;
    size_t      len;
};

/* Linux's struct timespec on x86_64. */
struct timespec_compat {
    int64_t tv_sec;
    int64_t tv_nsec;
};

struct winsize_compat {
    uint16_t ws_row, ws_col, ws_xpixel, ws_ypixel;
};

/* NOTE:
 * There is no file descriptor table here. Descriptors are allocated by
 * ruby/kernel/fd.rb, and having a second allocator in C handing out numbers
 * from the same range was a real bug: an opened file and a pipe both received
 * descriptor 3, and reads went to whichever the caller did not mean. One
 * namespace, one allocator, and it is the Ruby one. */

/* Only reached before routing is switched on, or if the Ruby side declines. */
static long
sys_read(int fd, char *buf, size_t count)
{
    if (fd != 0) return -EBADF;
    return (long)serial_read(buf, count);
}

static long
sys_write(int fd, const char *buf, size_t count)
{
    if (fd != 1 && fd != 2) return -EBADF;
    serial_write(buf, count);
    return (long)count;
}

static long
sys_writev(int fd, const struct iovec_compat *iov, int iovcnt)
{
    long total = 0;
    for (int i = 0; i < iovcnt; i++) {
        long n = sys_write(fd, iov[i].base, iov[i].len);
        if (n < 0) return n;
        total += n;
    }
    return total;
}

static long
sys_clock_gettime(struct timespec_compat *tp)
{
    if (!tp) return -EFAULT;
    uint64_t ns = timer_nanos();
    tp->tv_sec = (int64_t)(ns / 1000000000u);
    tp->tv_nsec = (int64_t)(ns % 1000000000u);
    return 0;
}

static long
sys_ioctl(unsigned long request, void *arg)
{
    /* TIOCGWINSZ. A fixed size for now; the terminal is whatever is on the
     * other end of the serial port and cannot be asked. */
    if (request == 0x5413) {
        struct winsize_compat *ws = arg;
        if (!ws) return -EFAULT;
        ws->ws_row = 24;
        ws->ws_col = 80;
        ws->ws_xpixel = 0;
        ws->ws_ypixel = 0;
        return 0;
    }
    /* TCGETS. Reporting failure here is what makes CRuby treat the console as
     * a pipe rather than a terminal, which is the honest answer until the tty
     * driver exists. */
    return -ENOTTY;
}

static long
sys_arch_prctl(int code, unsigned long addr)
{
    uint32_t lo = (uint32_t)(addr & 0xFFFFFFFFu);
    uint32_t hi = (uint32_t)(addr >> 32);

    switch (code) {
    case ARCH_SET_FS:
        __asm__ volatile ("wrmsr" : : "c"(IA32_FS_BASE), "a"(lo), "d"(hi));
        return 0;
    case ARCH_SET_GS:
        __asm__ volatile ("wrmsr" : : "c"(IA32_GS_BASE), "a"(lo), "d"(hi));
        return 0;
    default:
        return -EINVAL;
    }
}

/* Not random. Nothing here depends on unpredictability yet; CRuby uses it to
 * seed hashing, and a fixed seed makes runs reproducible. Revisit before
 * anything security-relevant runs on this kernel. */
static long
sys_getrandom(uint8_t *buf, size_t len)
{
    uint64_t state = timer_nanos() | 1u;
    for (size_t i = 0; i < len; i++) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        buf[i] = (uint8_t)state;
    }
    return (long)len;
}

/* Machine identity. Six fixed-size fields, and musl's gethostname copies
 * nodename out of the second one -- which is the only reason this exists:
 * Socket.gethostname is how WEBrick fills in its :ServerName, and a server
 * that cannot name itself refuses to start.
 *
 * struct utsname is not declared here because sys/utsname.h puts domainname
 * behind _GNU_SOURCE; the offsets are what matter and they are fixed. */
#define UTSNAME_FIELD 65

static long
sys_uname(char *buf)
{
    static const char *const fields[] = {
        "Linux",            /* what the ABI is, and CRuby checks nothing else */
        "picoruby-kernel",
        "1.0.0",
        "#1 picoruby-kernel",
        "x86_64",
        "(none)",
    };

    if (!buf) return -EFAULT;

    for (unsigned i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
        char *field = buf + (size_t)i * UTSNAME_FIELD;
        __builtin_memset(field, 0, UTSNAME_FIELD);
        const char *src = fields[i];
        size_t n = 0;
        while (src[n] && n < UTSNAME_FIELD - 1) { field[n] = src[n]; n++; }
    }
    return 0;
}

static void
report_unhandled(long n)
{
    char digits[24];
    int i = 0;

    serial_puts("kernel: unhandled syscall ");
    if (n == 0) digits[i++] = '0';
    while (n > 0 && i < (int)sizeof(digits)) {
        digits[i++] = (char)('0' + (n % 10));
        n /= 10;
    }
    while (i-- > 0) serial_putc(digits[i]);
    serial_putc('\n');
}

/* Reached from kernel/bridge.c for everything not routed to Ruby. */
long
kernel_syscall_c(long n, long a1, long a2, long a3, long a4, long a5, long a6)
{
    (void)a4; (void)a5; (void)a6;

    switch (n) {
    /* ---- console ---- */
    case SYS_read:   return sys_read((int)a1, (char *)a2, (size_t)a3);
    case SYS_write:  return sys_write((int)a1, (const char *)a2, (size_t)a3);
    case SYS_writev: return sys_writev((int)a1, (const struct iovec_compat *)a2, (int)a3);
    case SYS_ioctl:  return sys_ioctl((unsigned long)a2, (void *)a3);
    case SYS_stat:
    case SYS_lstat:
    case SYS_newfstatat:
        /* No filesystem, so nothing to describe. */
        return -ENOENT;
    case SYS_fcntl:
        /* F_GETFL is the only one asked about; claim a plain read-write,
         * non-blocking descriptor. Everything else is accepted silently. */
        return (a2 == 3) ? 0x802 : 0;

    /* ---- memory ----
     * Pages belong to ruby/kernel/memory.rb, and one allocator is the point:
     * a second one here, handing out the same range, would be the descriptor
     * bug again. So reaching mmap in C -- before routing is on, or from inside
     * a dispatch -- is a mistake to name, not a request to serve. */
    case SYS_mmap:
        serial_puts("kernel: mmap reached C, but pages are the Ruby side's\n");
        return -ENOMEM;
    case SYS_munmap:  return 0;
    case SYS_mremap:  return -ENOMEM;   /* musl falls back to allocate and copy */
    case SYS_madvise: return 0;
    case SYS_mprotect: return 0;        /* one address space, one protection */
    case SYS_brk:     return -ENOMEM;   /* musl falls back to mmap */

    /* ---- time ---- */
    case SYS_clock_gettime: return sys_clock_gettime((struct timespec_compat *)a2);
    case SYS_nanosleep:     return 0;

    /* ---- cpu and process ---- */
    case SYS_arch_prctl: return sys_arch_prctl((int)a1, (unsigned long)a2);
    case SYS_getrandom:  return sys_getrandom((uint8_t *)a1, (size_t)a2);
    case SYS_uname:      return sys_uname((char *)a1);
    case SYS_getpid:     return 1;
    case SYS_gettid:     return 1;
    case SYS_getuid:
    case SYS_geteuid:
    case SYS_getgid:
    case SYS_getegid:    return 0;
    case SYS_set_tid_address: return 1;
    case SYS_prctl:      return 0;
    case SYS_readlink:
    case SYS_readlinkat:
        /* CRuby looks for /proc/self/exe to find its own path. There is no
         * executable file, and reporting that is the honest answer; it falls
         * back to the name given to ruby_script(). */
        return -ENOENT;
    case SYS_sigaltstack: return 0;   /* no signals, so no alternate stack */
    case SYS_tkill:      return 0;   /* the only thread is the one signalling */
    case SYS_sched_getaffinity: return -ENOSYS;

    /* IO.copy_stream tries sendfile before falling back to read and write, and
     * io.c treats ENOSYS as exactly that invitation. Naming it here rather
     * than letting report_unhandled print it keeps a correct fallback from
     * looking like a missing feature. */
    case SYS_sendfile:   return -ENOSYS;

    /* Signals can be registered but are never delivered: there is no source of
     * them. Reporting success keeps Signal.trap working, and its handlers are
     * simply dead code. */
    case SYS_rt_sigaction:
    case SYS_rt_sigprocmask:
        return 0;

    case SYS_exit:
    case SYS_exit_group:
        serial_puts("kernel: halted\n");
        for (;;) __asm__ volatile ("cli; hlt");

    default:
        report_unhandled(n);
        return -ENOSYS;
    }
}
