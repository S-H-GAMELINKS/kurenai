/* Threads.
 *
 * musl's pthread_create asks for a thread with __clone and expects back
 * something that runs func(arg) on the stack it was given, with the TLS it was
 * given, alongside everything else. That is a task here: a saved stack pointer,
 * a saved FS base, and a state. There is one CPU and one address space, so
 * there is nothing else to save -- no page tables, no kernel stack separate
 * from the thread's own, because a syscall is a function call on the stack it
 * was made from.
 *
 * Everything a thread waits for comes through here: a futex, a deadline, or
 * the next tick when the Ruby side answered WAIT_AGAIN. A waiting task is
 * BLOCKED, and schedule() runs the next READY one, or halts until the tick if
 * there is none.
 *
 * Switching is preemptive, but only outside the kernel. Every syscall and
 * every entry musl makes directly raises the task's preempt_count for its
 * duration, and a tick that lands while it is raised only notes that the
 * slice is over; the switch happens when the count drops back to zero. So
 * kernel code -- the scheduler, futex, the bridge, the VM it calls -- never
 * has another task run in the middle of it, and needs no locks, because there
 * is one CPU. A tick that lands in CRuby or musl with the count at zero can
 * switch on the spot.
 *
 * This is the mechanism, in C, for the same reason memory pages are found in C
 * and handed out in Ruby: a context switch is a few instructions on registers,
 * and futex is on the path of every contended lock. What a thread is allowed to
 * do is still the Ruby side's to say. */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/syscall.h>

#include "kernel.h"

#define IA32_FS_BASE 0xC0000100

#define MAX_TASKS 64

/* How long a thread may run before another ready one gets the CPU, in ticks.
 * CRuby's own timer thread asks for the GVL to change hands every 100ms; this
 * only has to be short enough that the timer thread gets to say so. */
#define SLICE_TICKS 10

#define CLONE_VM             0x00000100
#define CLONE_SETTLS         0x00080000
#define CLONE_PARENT_SETTID  0x00100000
#define CLONE_CHILD_CLEARTID 0x00200000

#define FUTEX_WAIT          0
#define FUTEX_WAKE          1
#define FUTEX_REQUEUE       3
#define FUTEX_CMP_REQUEUE   4
#define FUTEX_WAIT_BITSET   9
#define FUTEX_WAKE_BITSET   10
#define FUTEX_CMD_MASK      127   /* drops FUTEX_PRIVATE_FLAG and FUTEX_CLOCK_REALTIME */

enum task_state { TASK_FREE, TASK_READY, TASK_BLOCKED, TASK_DEAD };

struct task {
    enum task_state state;
    int tid;

    uint64_t rsp;           /* saved by switch_to while not running */
    uint64_t fs_base;

    int *clear_tid;         /* zeroed and woken at exit: CLONE_CHILD_CLEARTID */

    /* What a BLOCKED task is waiting for. Any of the three ends the wait. */
    volatile uint32_t *futex;
    uint64_t wake_at;       /* nanoseconds since boot, 0 for never */
    long wake_result;       /* 0 woken, -ETIMEDOUT, -EINTR */

    struct syscall_retry retry;

    int preempt_count;      /* raised while in the kernel; see above */
};

/* What irq_timer in isr.S leaves on the IST stack: x87/SSE state, the fifteen
 * general registers in the order they were pushed, and the CPU's own frame. */
struct irq_frame {
    uint8_t  fx[512];
    uint64_t r15, r14, r13, r12, r11, r10, r9, r8;
    uint64_t rbp, rdi, rsi, rdx, rcx, rbx, rax;
    uint64_t rip, cs, rflags, rsp, ss;
};

_Static_assert(sizeof(struct irq_frame) == 672, "isr.S builds 672 bytes");
_Static_assert(sizeof(struct irq_frame) % 16 == 0, "fxsave wants 16-byte alignment");

static struct task tasks[MAX_TASKS];
static struct task *current;
static int next_tid = 2;

/* Before task_init there is no current task, only the boot code, and nothing
 * to switch to. */
static int boot_preempt_count = 1;

/* A tick arrived in the kernel after the slice was over. */
static volatile int need_resched;
static uint64_t slice_start;

extern volatile uint64_t irq_ticks;

/* A task that has just been switched away from, so the one switched to can
 * finish what it could not: free the slot of a task that exited, and give back
 * the stack it exited on. */
static struct task *switched_from;
static uintptr_t unmap_base;
static size_t unmap_size;

void switch_to(uint64_t *save_rsp, uint64_t next_rsp);
void switch_from_irq(uint64_t next_rsp) __attribute__((noreturn));
void task_trampoline(void);
void irq_resume_task(void);

static void schedule(void);

static uint64_t
read_fs_base(void)
{
    uint32_t lo, hi;
    __asm__ volatile ("rdmsr" : "=a"(lo), "=d"(hi) : "c"(IA32_FS_BASE));
    return ((uint64_t)hi << 32) | lo;
}

static void
write_fs_base(uint64_t value)
{
    __asm__ volatile ("wrmsr"
                      :
                      : "c"(IA32_FS_BASE),
                        "a"((uint32_t)(value & 0xFFFFFFFFu)),
                        "d"((uint32_t)(value >> 32)));
}

void
task_init(void)
{
    current = &tasks[0];
    current->state = TASK_READY;
    current->tid = 1;
    current->retry.deadline = SYSCALL_NO_DEADLINE;
    current->preempt_count = boot_preempt_count;
}

/* ---------------------------------------------------------------- preemption */

void
preempt_disable(void)
{
    if (current) current->preempt_count++;
    else boot_preempt_count++;
}

/* Leaving the kernel is where a tick that arrived inside it is acted on. The
 * count is still raised while schedule() runs, so the switch is not itself
 * preempted, and it is per task, so it comes back as it was. */
void
preempt_enable(void)
{
    if (!current) { boot_preempt_count--; return; }
    if (current->preempt_count == 1 && need_resched) {
        need_resched = 0;
        schedule();
    }
    current->preempt_count--;
}

int
task_current_tid(void)
{
    return current ? current->tid : 1;
}

struct syscall_retry *
task_retry_state(void)
{
    static struct syscall_retry before_tasks = { SYSCALL_NO_DEADLINE, 0 };
    return current ? &current->retry : &before_tasks;
}

/* ---------------------------------------------------------------- switching */

/* Runs on the task switched to, right after the switch -- in schedule() for a
 * task that was running before, in task_started for a new one, in
 * task_resumed for one a tick preempted. */
static void
finish_switch(void)
{
    if (switched_from && switched_from->state == TASK_DEAD)
        switched_from->state = TASK_FREE;
    switched_from = NULL;

    /* The stack a detached thread exited on, which it could not free while
     * standing on it. Given back through the ordinary munmap, so the pages go
     * to ruby/kernel/memory.rb's free list like any others. */
    if (unmap_size) {
        uintptr_t base = unmap_base;
        size_t size = unmap_size;
        unmap_size = 0;
        kernel_syscall(SYS_munmap, (long)base, (long)size, 0, 0, 0, 0);
    }
}

static void
wake_expired(uint64_t now)
{
    for (int i = 0; i < MAX_TASKS; i++) {
        struct task *t = &tasks[i];
        if (t->state == TASK_BLOCKED && t->wake_at && now >= t->wake_at) {
            t->state = TASK_READY;
            t->futex = NULL;
            t->wake_at = 0;
            t->wake_result = -ETIMEDOUT;
        }
    }
}

/* The next READY task after the current one, round robin, the current one
 * last; NULL if nothing can run. */
static struct task *
pick_next(void)
{
    int start = (int)(current - tasks);
    for (int k = 1; k <= MAX_TASKS; k++) {
        struct task *t = &tasks[(start + k) % MAX_TASKS];
        if (t->state == TASK_READY) return t;
    }
    return NULL;
}

static void
schedule(void)
{
    struct task *next;
    for (;;) {
        wake_expired(timer_nanos());
        next = pick_next();
        if (next) break;
        /* Nothing can run: every thread is waiting for time or for another
         * thread, and time is the only thing that will change that. */
        irq_wait();
    }

    if (next == current) return;

    struct task *prev = current;
    prev->fs_base = read_fs_base();
    switched_from = prev;
    current = next;
    slice_start = irq_ticks;
    write_fs_base(next->fs_base);
    switch_to(&prev->rsp, next->rsp);

    finish_switch();
}

/* First C a new task runs, from task_trampoline in switch.S. It was created
 * with its count raised, and leaves the kernel here for the first time. */
void
task_started(void)
{
    finish_switch();
    preempt_enable();
}

/* First C a preempted task runs when it is switched back to, from
 * irq_resume_task in switch.S, before its registers are restored. Its count
 * is zero -- it was preempted outside the kernel -- so it is raised around
 * what finishing the switch may do, munmap included. */
void
task_resumed(void)
{
    preempt_disable();
    finish_switch();
    preempt_enable();
}

/* ---------------------------------------------------------------- the tick */

/* Saves the interrupted task where irq_resume_task will find it -- on its own
 * stack, below the 128 bytes of red zone the code it was running may have
 * been using -- and switches to next. The frame on the IST stack is abandoned:
 * the next tick starts that stack from the top again. */
static void __attribute__((noreturn))
preempt(struct irq_frame *frame, struct task *next)
{
    uintptr_t sp = ((uintptr_t)frame->rsp - 128 - sizeof(*frame)) & ~(uintptr_t)15;
    __builtin_memcpy((void *)sp, frame, sizeof(*frame));

    /* What switch_to would have left: six callee-saved registers, which
     * irq_resume restores from the copy anyway, and a return address. */
    uint64_t *switch_frame = (uint64_t *)sp - 7;
    for (int i = 0; i < 6; i++) switch_frame[i] = 0;
    switch_frame[6] = (uint64_t)(uintptr_t)irq_resume_task;

    struct task *prev = current;
    prev->rsp = (uint64_t)(uintptr_t)switch_frame;
    prev->fs_base = read_fs_base();
    switched_from = prev;
    current = next;
    slice_start = irq_ticks;
    write_fs_base(next->fs_base);
    switch_from_irq(next->rsp);
}

/* Called by irq_timer in isr.S for every tick, with interrupts off. */
void
irq_tick(struct irq_frame *frame)
{
    irq_ticks++;
    outb(0x20, 0x20);   /* end of interrupt, to the master PIC */

    if (!current) return;
    int slice_over = irq_ticks - slice_start >= SLICE_TICKS;

    /* In the kernel nothing may be switched away from; say so for when it
     * leaves. Waking sleepers is left to schedule() too: the kernel may be in
     * the middle of changing the very task a wake would touch. */
    if (current->preempt_count > 0) {
        if (slice_over) need_resched = 1;
        return;
    }

    wake_expired(timer_nanos());
    if (!slice_over) return;

    struct task *next = pick_next();
    if (!next || next == current) {
        slice_start = irq_ticks;
        return;
    }
    preempt(frame, next);
}

/* Blocks the current task until woken, until deadline (0 for never), or until
 * tkill interrupts it. */
static long
block(volatile uint32_t *futex, uint64_t deadline)
{
    current->futex = futex;
    current->wake_at = deadline;
    current->wake_result = 0;
    current->state = TASK_BLOCKED;
    schedule();
    return current->wake_result;
}

/* ---------------------------------------------------------------- clone, exit */

long
task_clone(int (*func)(void *), void *stack, int flags, void *arg,
           int *ptid, void *tls, int *ctid)
{
    /* Threads only. A new address space would be fork, and there is one. */
    if (!(flags & CLONE_VM)) return -ENOSYS;

    /* musl calls this directly rather than through kernel_syscall, so it
     * enters the kernel here. */
    preempt_disable();

    struct task *t = NULL;
    for (int i = 0; i < MAX_TASKS; i++) {
        if (tasks[i].state == TASK_FREE) { t = &tasks[i]; break; }
    }
    if (!t) { preempt_enable(); return -EAGAIN; }

    *t = (struct task){0};
    t->tid = next_tid++;
    t->fs_base = (flags & CLONE_SETTLS) ? (uint64_t)(uintptr_t)tls : read_fs_base();
    t->clear_tid = (flags & CLONE_CHILD_CLEARTID) ? ctid : NULL;
    t->retry.deadline = SYSCALL_NO_DEADLINE;
    t->preempt_count = 1;   /* until task_started leaves the kernel */

    /* The frame switch_to pops: six callee-saved registers and a return
     * address. It returns into task_trampoline with func in r12 and arg in
     * r13, and with rsp 16-byte aligned, which is what a call expects to find
     * before it pushes. Everything is written below stack, so the arguments
     * pthread_create left above it are untouched. */
    uint64_t *top = (uint64_t *)((uintptr_t)stack & ~(uintptr_t)15);
    uint64_t *frame = top - 7;
    frame[0] = 0;                                   /* r15 */
    frame[1] = 0;                                   /* r14 */
    frame[2] = (uint64_t)(uintptr_t)arg;            /* r13 */
    frame[3] = (uint64_t)(uintptr_t)func;           /* r12 */
    frame[4] = 0;                                   /* rbx */
    frame[5] = 0;                                   /* rbp */
    frame[6] = (uint64_t)(uintptr_t)task_trampoline;
    t->rsp = (uint64_t)(uintptr_t)frame;

    if (flags & CLONE_PARENT_SETTID) *ptid = t->tid;
    t->state = TASK_READY;
    int tid = t->tid;
    preempt_enable();
    return tid;
}

static int
live_tasks(void)
{
    int n = 0;
    for (int i = 0; i < MAX_TASKS; i++)
        if (tasks[i].state == TASK_READY || tasks[i].state == TASK_BLOCKED) n++;
    return n;
}

void
task_exit(int code)
{
    (void)code;

    /* Reached from SYS_exit, from __unmapself, and from task_trampoline when
     * the thread's function returns -- the last of those outside the kernel.
     * A dead task never leaves, so the count is never lowered again. */
    preempt_disable();

    /* The last thread leaving is the system ending, as before. */
    if (!current || live_tasks() <= 1) {
        serial_puts("kernel: halted\n");
        for (;;) __asm__ volatile ("cli; hlt");
    }

    /* musl points this at __thread_list_lock, and the lock is released only
     * here: pthread_exit unlinks the thread under it, and the unlink becomes
     * visible when the kernel says the thread is gone. */
    if (current->clear_tid) {
        *current->clear_tid = 0;
        task_futex((uint32_t *)current->clear_tid, FUTEX_WAKE, 1, NULL, NULL, 0);
    }

    current->state = TASK_DEAD;
    schedule();
    for (;;) __asm__ volatile ("cli; hlt");   /* a dead task is never picked */
}

void
task_exit_unmapping(void *base, size_t size)
{
    preempt_disable();
    unmap_base = (uintptr_t)base;
    unmap_size = size;
    task_exit(0);
}

/* ---------------------------------------------------------------- futex */

static int
wake(volatile uint32_t *futex, int count)
{
    int woken = 0;
    for (int i = 0; i < MAX_TASKS && woken < count; i++) {
        struct task *t = &tasks[i];
        if (t->state == TASK_BLOCKED && t->futex == futex) {
            t->state = TASK_READY;
            t->futex = NULL;
            t->wake_at = 0;
            t->wake_result = 0;
            woken++;
        }
    }
    return woken;
}

static uint64_t
timespec_nanos(const struct timespec_compat *ts)
{
    return (uint64_t)ts->tv_sec * 1000000000u + (uint64_t)ts->tv_nsec;
}

long
task_futex(uint32_t *uaddr, int op, uint32_t val,
           const struct timespec_compat *timeout, uint32_t *uaddr2, uint32_t val3)
{
    volatile uint32_t *futex = uaddr;

    switch (op & FUTEX_CMD_MASK) {
    case FUTEX_WAIT:
    case FUTEX_WAIT_BITSET: {
        /* Inside a dispatch nothing else may run, so nothing could ever wake
         * this. It would mean C reached from the Ruby kernel took a lock some
         * thread holds -- a bug to name rather than a wait to hang in. */
        if (bridge_in_dispatch()) {
            serial_puts("kernel: futex wait inside a dispatch\n");
            return -EDEADLK;
        }
        if (*futex != val) return -EAGAIN;

        uint64_t deadline = 0;
        if (timeout) {
            /* FUTEX_WAIT's timeout is relative, FUTEX_WAIT_BITSET's absolute.
             * Every clock here is the same monotonic one, so the clock flag
             * needs no handling. */
            deadline = timespec_nanos(timeout);
            if ((op & FUTEX_CMD_MASK) == FUTEX_WAIT) deadline += timer_nanos();
            if (deadline == 0) deadline = 1;
        }
        return block(futex, deadline);
    }

    case FUTEX_WAKE:
    case FUTEX_WAKE_BITSET:
        return wake(futex, (int)val);

    case FUTEX_CMP_REQUEUE:
        if (*futex != val3) return -EAGAIN;
        /* fall through */
    case FUTEX_REQUEUE: {
        /* The fourth argument is a count here, not a timeout. */
        int requeue = (int)(uintptr_t)timeout;
        int woken = wake(futex, (int)val);
        int moved = 0;
        for (int i = 0; i < MAX_TASKS && moved < requeue; i++) {
            struct task *t = &tasks[i];
            if (t->state == TASK_BLOCKED && t->futex == futex) {
                t->futex = uaddr2;
                moved++;
            }
        }
        return woken + moved;
    }

    default:
        return -ENOSYS;
    }
}

/* ---------------------------------------------------------------- time */

long
task_sleep_until(uint64_t deadline)
{
    long result = block(NULL, deadline ? deadline : 1);
    return result == -EINTR ? -EINTR : 0;
}

/* For kernel/bridge.c, between a WAIT_AGAIN and the retry. */
long
task_sleep_tick(void)
{
    return task_sleep_until(timer_nanos() + 1000000u);
}

long
task_yield(void)
{
    if (current) schedule();
    return 0;
}

/* ---------------------------------------------------------------- signals
 *
 * No handler is ever run: there is no way to put a signal frame on a stack and
 * nothing to return through. What CRuby uses a signal for is narrower -- its
 * timer thread sends SIGVTALRM to a thread blocked in poll or on a condition
 * variable so that the call returns EINTR and the thread notices an interrupt,
 * Thread#kill or Thread#raise. Ending the wait is the whole of that, and it is
 * what this does for any signal. */
long
task_tkill(int tid, int sig)
{
    (void)sig;
    for (int i = 0; i < MAX_TASKS; i++) {
        struct task *t = &tasks[i];
        if ((t->state == TASK_READY || t->state == TASK_BLOCKED) && t->tid == tid) {
            if (t->state == TASK_BLOCKED) {
                t->state = TASK_READY;
                t->futex = NULL;
                t->wake_at = 0;
                t->wake_result = -EINTR;
            }
            return 0;
        }
    }
    return -ESRCH;
}

long
task_set_tid_address(int *ctid)
{
    if (current) current->clear_tid = ctid;
    return task_current_tid();
}
