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
#include <sys/stat.h>
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

/* ---------------------------------------------------------------- pipes
 *
 * CRuby will not finish starting without one. It builds a self-pipe so a
 * signal handler can wake the main loop, and treats failure to create it as
 * fatal even though no signal will ever arrive here.
 *
 * These are pipes in the only sense that matters to that: a buffer, two ends,
 * and a read that reports emptiness rather than blocking. Nothing writes to
 * them in practice. */

#define PIPE_CAPACITY 512
#define PIPE_MAX      4
#define FD_MAX        32
#define FD_FIRST_PIPE 3

struct pipe_buffer {
    int      used;
    unsigned head, tail;
    char     data[PIPE_CAPACITY];
};

struct fd_entry {
    int used;
    int writable;                 /* which end of the pipe this is */
    struct pipe_buffer *pipe;
};

static struct pipe_buffer pipes[PIPE_MAX];
static struct fd_entry fds[FD_MAX];

static int
alloc_fd(struct pipe_buffer *pipe, int writable)
{
    for (int i = FD_FIRST_PIPE; i < FD_MAX; i++) {
        if (fds[i].used) continue;
        fds[i].used = 1;
        fds[i].writable = writable;
        fds[i].pipe = pipe;
        return i;
    }
    return -EMFILE;
}

static long
sys_pipe(int *out)
{
    if (!out) return -EFAULT;

    for (int i = 0; i < PIPE_MAX; i++) {
        if (pipes[i].used) continue;

        int rfd = alloc_fd(&pipes[i], 0);
        if (rfd < 0) return rfd;
        int wfd = alloc_fd(&pipes[i], 1);
        if (wfd < 0) { fds[rfd].used = 0; return wfd; }

        pipes[i].used = 1;
        pipes[i].head = pipes[i].tail = 0;
        out[0] = rfd;
        out[1] = wfd;
        return 0;
    }
    return -ENFILE;
}

static long
pipe_read(struct fd_entry *fd, char *buf, size_t count)
{
    struct pipe_buffer *p = fd->pipe;
    size_t n = 0;
    while (n < count && p->head != p->tail) {
        buf[n++] = p->data[p->head];
        p->head = (p->head + 1) % PIPE_CAPACITY;
    }
    /* Empty means "nothing yet", not end of file: the writing end is still
     * open, and reporting EOF would tell CRuby the pipe had been closed. */
    return n ? (long)n : -EAGAIN;
}

static long
pipe_write(struct fd_entry *fd, const char *buf, size_t count)
{
    struct pipe_buffer *p = fd->pipe;
    size_t n = 0;
    while (n < count) {
        unsigned next = (p->tail + 1) % PIPE_CAPACITY;
        if (next == p->head) break;      /* full; drop the rest */
        p->data[p->tail] = buf[n++];
        p->tail = next;
    }
    return (long)n;
}

static long
sys_close(int fd)
{
    if (fd < FD_FIRST_PIPE || fd >= FD_MAX) return 0;
    if (!fds[fd].used) return -EBADF;

    struct pipe_buffer *p = fds[fd].pipe;
    fds[fd].used = 0;
    fds[fd].pipe = 0;

    /* Release the buffer once neither end refers to it. */
    for (int i = FD_FIRST_PIPE; i < FD_MAX; i++)
        if (fds[i].used && fds[i].pipe == p) return 0;
    if (p) p->used = 0;
    return 0;
}

static long
sys_read(int fd, char *buf, size_t count)
{
    if (fd == 0) return (long)serial_read(buf, count);
    if (fd >= FD_FIRST_PIPE && fd < FD_MAX && fds[fd].used)
        return pipe_read(&fds[fd], buf, count);
    return -EBADF;
}

static long
sys_write(int fd, const char *buf, size_t count)
{
    if (fd == 1 || fd == 2) {
        serial_write(buf, count);
        return (long)count;
    }
    if (fd >= FD_FIRST_PIPE && fd < FD_MAX && fds[fd].used)
        return pipe_write(&fds[fd], buf, count);
    return -EBADF;
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

/* The kernel is compiled against musl's headers, so struct stat is laid out
 * exactly as the caller expects and can be filled by name rather than by
 * offset. */
static long
sys_fstat(int fd, struct stat *st)
{
    if (!st) return -EFAULT;
    if (fd < 0 || (fd >= FD_MAX)) return -EBADF;
    if (fd >= FD_FIRST_PIPE && !fds[fd].used) return -EBADF;

    __builtin_memset(st, 0, sizeof(*st));
    /* Everything here is either the console or a pipe, and neither is a
     * regular file. Saying so keeps stdio from trying to seek. */
    st->st_mode = (fd < FD_FIRST_PIPE) ? (S_IFCHR | 0620) : (S_IFIFO | 0600);
    st->st_nlink = 1;
    st->st_blksize = 1024;
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
    case SYS_close:  return sys_close((int)a1);
    case SYS_fstat:  return sys_fstat((int)a1, (struct stat *)a2);
    case SYS_stat:
    case SYS_lstat:
    case SYS_newfstatat:
        /* No filesystem, so nothing to describe. */
        return -ENOENT;
    case SYS_pipe:   return sys_pipe((int *)a1);
    case SYS_pipe2:  return sys_pipe((int *)a1);
    case SYS_open:
    case SYS_openat:
        /* No filesystem yet. The VFS is meant to live in Ruby, so this stays
         * a refusal until the dispatcher moves there. */
        return -ENOENT;
    case SYS_fcntl:
        /* F_GETFL is the only one asked about; claim a plain read-write,
         * non-blocking descriptor. Everything else is accepted silently. */
        return (a2 == 3) ? 0x802 : 0;

    /* ---- memory ----
     * The arena is identity mapped already, so mmap only has to pick an
     * address. munmap keeps its pages: musl's allocator reuses inside its own
     * groups and only unmaps large blocks, so what leaks here is bounded. */
    case SYS_mmap: {
        void *p = memory_alloc_pages((size_t)a2);
        return p ? (long)(uintptr_t)p : -ENOMEM;
    }
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
