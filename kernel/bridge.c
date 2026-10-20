/* The boundary between CRuby and the Ruby kernel.
 *
 * musl calls kernel_syscall for everything. Numbers in the routing table go to
 * Kernel::Syscall.dispatch in the PicoRuby VM; the rest stay in C. The table
 * is a bitmap so syscalls can be moved across one at a time, which also means
 * a regression can be bisected by moving one back.
 *
 * Three rules hold this together, and all three are load-bearing:
 *
 *   Re-entrancy. Anything the dispatcher does that reaches libc would come
 *   back through kernel_syscall. The guard sends that back to the C path
 *   instead of recursing into a VM that is already running.
 *
 *   The GC arena. Values created while servicing a call are dead as soon as it
 *   returns; without saving and restoring the arena they accumulate for the
 *   lifetime of the system.
 *
 *   Exceptions. There is nothing above this frame to catch one. An exception
 *   that escapes has to be turned back into an errno, or it unwinds into
 *   CRuby, which has no idea the VM exists.
 *
 * And one rule about time: a dispatch never waits. There is one VM for every
 * thread, so a caller sitting in it would stop all the others. A call that
 * has to wait answers WAIT_AGAIN instead, and the waiting happens here, in C,
 * outside the VM: until the next tick, and then the same call again. */

#include <errno.h>
#include <stdint.h>

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include "kernel.h"

/* Room for every Linux syscall number in use. */
#define ROUTE_WORDS 8
static uint64_t routed[ROUTE_WORDS];

static int in_dispatch;
static struct RClass *syscall_module;

/* Kernel::Syscall::WAIT_AGAIN. Linux's ERESTARTSYS, and like it, never seen by
 * the program making the call. */
#define WAIT_AGAIN (-512)

/* The deadline of the call being retried lives with the thread making it,
 * in task_retry_state(): set by the first dispatch of a call and kept until
 * the call finishes, so a timeout counts from when the program asked rather
 * than from the latest retry. */

/* The VM's C recursion, and lwIP's beneath it, runs on this rather than on the
 * caller's stack. It does not need to be per caller: there is only ever one
 * dispatch at a time, which is what in_dispatch enforces. Its own stack also
 * means a caller with a small one -- musl gives a thread 128KB unless asked --
 * is not the one that decides how deep the Ruby kernel may go. */
static uint8_t dispatch_stack[1024 * 1024] __attribute__((aligned(16)));

long call_on_stack(long (*fn)(void *), void *arg, void *stack_top);

void
bridge_route(long number)
{
    if (number < 0 || number >= ROUTE_WORDS * 64) return;
    routed[number / 64] |= (uint64_t)1 << (number % 64);
}

int
bridge_in_dispatch(void)
{
    return in_dispatch;
}

static int
is_routed(long number)
{
    if (number < 0 || number >= ROUTE_WORDS * 64) return 0;
    return (routed[number / 64] >> (number % 64)) & 1;
}

/* ---------------------------------------------------------------- primitives
 *
 * What the Ruby side is allowed to do. Everything the dispatcher needs that
 * cannot be expressed in Ruby lives here, and nothing more: this is the whole
 * surface between the kernel's Ruby and the machine. */

static mrb_value
prim_serial_write(mrb_state *mrb, mrb_value self)
{
    mrb_int address, count;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &count);
    if (count > 0) serial_write((const char *)(uintptr_t)address, (size_t)count);
    return mrb_nil_value();
}

static mrb_value
prim_serial_read(mrb_state *mrb, mrb_value self)
{
    mrb_int address, count;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &count);
    if (count <= 0) return mrb_int_value(mrb, 0);
    size_t n = serial_read((char *)(uintptr_t)address, (size_t)count);
    return mrb_int_value(mrb, (mrb_int)n);
}

/* Moves bytes between two places the Ruby side only knows as addresses: out of
 * the image and into a caller's buffer. Ruby decides the ranges, C moves them,
 * and nothing becomes a Ruby object on the way. */
static mrb_value
prim_copy_out(mrb_state *mrb, mrb_value self)
{
    mrb_int dest, src, length;
    (void)self;

    mrb_get_args(mrb, "iii", &dest, &src, &length);
    if (length > 0)
        __builtin_memcpy((void *)(uintptr_t)dest, (const void *)(uintptr_t)src,
                         (size_t)length);
    return mrb_nil_value();
}

static mrb_value
prim_memzero(mrb_state *mrb, mrb_value self)
{
    mrb_int address, length;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &length);
    if (length > 0)
        __builtin_memset((void *)(uintptr_t)address, 0, (size_t)length);
    return mrb_nil_value();
}

/* Reads a NUL-terminated string out of the caller's memory. This one does
 * create a Ruby object, and has to: a path is something the Ruby kernel
 * compares and looks up, not a range it forwards. The bytes are copied, so the
 * result belongs to the VM that made it. */
static mrb_value
prim_cstring(mrb_state *mrb, mrb_value self)
{
    mrb_int address;
    (void)self;

    mrb_get_args(mrb, "i", &address);
    if (address == 0) return mrb_str_new_lit(mrb, "");

    const char *p = (const char *)(uintptr_t)address;
    size_t len = 0;
    while (len < 4096 && p[len]) len++;
    return mrb_str_new(mrb, p, len);
}

/* The table the linker built, handed over once at boot. Each entry is
 * [path, address, size]; ruby/kernel/vfs.rb turns it into a lookup. */
struct embedded_file {
    const char          *path;
    const unsigned char *data;
    size_t               size;
};
extern const struct embedded_file embedded_files[];
extern const size_t embedded_file_count;

static mrb_value
prim_embedded_files(mrb_state *mrb, mrb_value self)
{
    (void)self;

    mrb_value list = mrb_ary_new_capa(mrb, (mrb_int)embedded_file_count);
    for (size_t i = 0; i < embedded_file_count; i++) {
        mrb_value entry = mrb_ary_new_capa(mrb, 3);
        mrb_ary_push(mrb, entry, mrb_str_new_cstr(mrb, embedded_files[i].path));
        mrb_ary_push(mrb, entry,
                     mrb_int_value(mrb, (mrb_int)(uintptr_t)embedded_files[i].data));
        mrb_ary_push(mrb, entry, mrb_int_value(mrb, (mrb_int)embedded_files[i].size));
        mrb_ary_push(mrb, list, entry);
    }
    return list;
}

static mrb_value
prim_peek32(mrb_state *mrb, mrb_value self)
{
    mrb_int address;
    (void)self;

    mrb_get_args(mrb, "i", &address);
    return mrb_int_value(mrb, (mrb_int)*(uint32_t *)(uintptr_t)address);
}

static mrb_value
prim_poke16(mrb_state *mrb, mrb_value self)
{
    mrb_int address, value;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &value);
    *(uint16_t *)(uintptr_t)address = (uint16_t)value;
    return mrb_nil_value();
}

/* Has a byte arrived? Asked by the poll implementation and by the raw-mode
 * read, both of which have to decide whether to wait without committing to it. */
static mrb_value
prim_serial_ready(mrb_state *mrb, mrb_value self)
{
    (void)mrb; (void)self;
    return serial_data_ready() ? mrb_true_value() : mrb_false_value();
}

/* Reads only what has already arrived, unlike serial_read, which blocks for
 * the first byte. Raw mode needs the distinction. */
static mrb_value
prim_serial_read_ready(mrb_state *mrb, mrb_value self)
{
    mrb_int address, count;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &count);

    char *out = (char *)(uintptr_t)address;
    mrb_int n = 0;
    while (n < count && serial_data_ready())
        out[n++] = (char)serial_getc();
    return mrb_int_value(mrb, n);
}

/* What the deadline of the call in progress is. The first dispatch of a call
 * proposes one and has it kept; a retry of the same call gets the kept one
 * back, whatever it proposes. */
static mrb_value
prim_held_deadline(mrb_state *mrb, mrb_value self)
{
    mrb_int proposed;
    (void)self;

    mrb_get_args(mrb, "i", &proposed);
    struct syscall_retry *retry = task_retry_state();
    if (!retry->retrying) retry->deadline = (long)proposed;
    return mrb_int_value(mrb, (mrb_int)retry->deadline);
}

/* Lets the CPU rest between polls, until the next tick: at most a
 * millisecond, and nothing at all is spent while waiting. */
static mrb_value
prim_idle(mrb_state *mrb, mrb_value self)
{
    (void)mrb; (void)self;
    irq_wait();
    return mrb_nil_value();
}

static mrb_value
prim_poke32(mrb_state *mrb, mrb_value self)
{
    mrb_int address, value;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &value);
    *(uint32_t *)(uintptr_t)address = (uint32_t)value;
    return mrb_nil_value();
}

/* Copies bytes out of the caller's memory into a Ruby Array of integers. Used
 * for pipe writes, where the kernel has to keep the bytes rather than forward
 * them, so they must become objects the Ruby side owns. */
static mrb_value
prim_read_bytes(mrb_state *mrb, mrb_value self)
{
    mrb_int address, length;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &length);
    if (length < 0) length = 0;

    const unsigned char *p = (const unsigned char *)(uintptr_t)address;
    mrb_value list = mrb_ary_new_capa(mrb, (mrb_int)length);
    for (mrb_int i = 0; i < length; i++)
        mrb_ary_push(mrb, list, mrb_int_value(mrb, p[i]));
    return list;
}

static mrb_value
prim_write_bytes(mrb_state *mrb, mrb_value self)
{
    mrb_int address;
    mrb_value list;
    (void)self;

    mrb_get_args(mrb, "iA", &address, &list);

    unsigned char *p = (unsigned char *)(uintptr_t)address;
    mrb_int len = RARRAY_LEN(list);
    for (mrb_int i = 0; i < len; i++)
        p[i] = (unsigned char)mrb_integer(mrb_ary_entry(list, i));
    return mrb_int_value(mrb, len);
}

/* The three facts about memory the Ruby side cannot find out itself: where
 * the image ends, where the bootloader's information is, and how much of the
 * address space the boot stub mapped. Each entry is [image_end, boot_info,
 * mapped_limit]; ruby/kernel/memory.rb reads the bootloader's structure from
 * there with peek32. */
static mrb_value
prim_memory_layout(mrb_state *mrb, mrb_value self)
{
    (void)self;

    mrb_value layout = mrb_ary_new_capa(mrb, 3);
    mrb_ary_push(mrb, layout, mrb_int_value(mrb, (mrb_int)memory_image_end()));
    mrb_ary_push(mrb, layout, mrb_int_value(mrb, (mrb_int)memory_boot_info()));
    mrb_ary_push(mrb, layout, mrb_int_value(mrb, (mrb_int)memory_mapped_limit()));
    return layout;
}

static mrb_value
prim_clock_millis(mrb_state *mrb, mrb_value self)
{
    (void)self;
    return mrb_int_value(mrb, (mrb_int)timer_millis());
}

static mrb_value
prim_peek64(mrb_state *mrb, mrb_value self)
{
    mrb_int address;
    (void)self;

    mrb_get_args(mrb, "i", &address);
    return mrb_int_value(mrb, (mrb_int)*(uint64_t *)(uintptr_t)address);
}

static mrb_value
prim_poke64(mrb_state *mrb, mrb_value self)
{
    mrb_int address, value;
    (void)self;

    mrb_get_args(mrb, "ii", &address, &value);
    *(uint64_t *)(uintptr_t)address = (uint64_t)value;
    return mrb_nil_value();
}

/* Port I/O, which is the one thing a device driver written in Ruby cannot do
 * for itself. Memory-mapped registers are already reachable through peek32 and
 * poke32 -- the low 4GB is identity mapped, so a register at a physical
 * address is that address -- but the PCI configuration space is not memory. It
 * is a pair of ports: write which register you want to 0xCF8, read it from
 * 0xCFC. Without these two the Ruby side cannot find a card to talk to.
 *
 * Only the 32-bit pair, because that is the width PCI configuration space is
 * defined in. inb and outb exist in kernel.h for the PIT and can be exposed
 * when something needs them. */
static mrb_value
prim_inl(mrb_state *mrb, mrb_value self)
{
    mrb_int port;
    (void)self;

    mrb_get_args(mrb, "i", &port);
    return mrb_int_value(mrb, (mrb_int)inl((uint16_t)port));
}

static mrb_value
prim_outl(mrb_state *mrb, mrb_value self)
{
    mrb_int port, value;
    (void)self;

    mrb_get_args(mrb, "ii", &port, &value);
    outl((uint16_t)port, (uint32_t)value);
    return mrb_nil_value();
}

/* One register of the CMOS clock. Selecting the register and reading it are
 * two port accesses that must not be split, so they are one primitive; what
 * the registers mean -- BCD or binary, 12 or 24 hours, whether an update is in
 * progress -- is read on the Ruby side. Bit 7 of the index port is the NMI
 * mask, and is left clear. */
static mrb_value
prim_cmos_read(mrb_state *mrb, mrb_value self)
{
    mrb_int reg;
    (void)self;

    mrb_get_args(mrb, "i", &reg);
    outb(0x70, (uint8_t)(reg & 0x7F));
    return mrb_int_value(mrb, (mrb_int)inb(0x71));
}

/* The Unix time the Ruby side worked out from the CMOS clock. From here the
 * wall clock runs on the TSC; see kernel/timer.c. */
static mrb_value
prim_set_realtime(mrb_state *mrb, mrb_value self)
{
    mrb_int seconds;
    (void)self;

    mrb_get_args(mrb, "i", &seconds);
    if (seconds > 0) timer_set_realtime((uint64_t)seconds);
    return mrb_nil_value();
}

static mrb_value
prim_halt(mrb_state *mrb, mrb_value self)
{
    (void)mrb; (void)self;
    for (;;) __asm__ volatile ("cli; hlt");
}

void
bridge_init(mrb_state *mrb)
{
    struct RClass *kernel = mrb_module_get(mrb, "Kernel");
    syscall_module = mrb_module_get_under(mrb, kernel, "Syscall");

    /* Module functions, so the dispatcher calls them unqualified. */
    mrb_define_module_function(mrb, syscall_module, "serial_write",
                               prim_serial_write, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "clock_millis",
                               prim_clock_millis, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "serial_read",
                               prim_serial_read, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "copy_out",
                               prim_copy_out, MRB_ARGS_REQ(3));
    mrb_define_module_function(mrb, syscall_module, "memzero",
                               prim_memzero, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "cstring",
                               prim_cstring, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, syscall_module, "embedded_files",
                               prim_embedded_files, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "memory_layout",
                               prim_memory_layout, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "peek32",
                               prim_peek32, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, syscall_module, "poke16",
                               prim_poke16, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "serial_ready?",
                               prim_serial_ready, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "serial_read_ready",
                               prim_serial_read_ready, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "held_deadline",
                               prim_held_deadline, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, syscall_module, "idle",
                               prim_idle, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "poke32",
                               prim_poke32, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "read_bytes",
                               prim_read_bytes, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "write_bytes",
                               prim_write_bytes, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "peek64",
                               prim_peek64, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, syscall_module, "poke64",
                               prim_poke64, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "inl",
                               prim_inl, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, syscall_module, "outl",
                               prim_outl, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "halt",
                               prim_halt, MRB_ARGS_NONE());
    mrb_define_module_function(mrb, syscall_module, "cmos_read",
                               prim_cmos_read, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, syscall_module, "set_realtime",
                               prim_set_realtime, MRB_ARGS_REQ(1));

    /* The network's primitives live in kernel/net.c, next to the lwIP they
     * drive, but they are registered here so that the whole surface between
     * the kernel's Ruby and the machine is declared in one place. */
    net_init(mrb, syscall_module);
}

static long
dispatch_in_ruby(mrb_state *mrb, long n, long a1, long a2, long a3,
                 long a4, long a5, long a6)
{
    mrb_value argv[7];
    argv[0] = mrb_int_value(mrb, (mrb_int)n);
    argv[1] = mrb_int_value(mrb, (mrb_int)a1);
    argv[2] = mrb_int_value(mrb, (mrb_int)a2);
    argv[3] = mrb_int_value(mrb, (mrb_int)a3);
    argv[4] = mrb_int_value(mrb, (mrb_int)a4);
    argv[5] = mrb_int_value(mrb, (mrb_int)a5);
    argv[6] = mrb_int_value(mrb, (mrb_int)a6);

    int arena = mrb_gc_arena_save(mrb);
    mrb_value result = mrb_funcall_argv(mrb, mrb_obj_value(syscall_module),
                                        mrb_intern_lit(mrb, "dispatch"),
                                        7, argv);

    long ret;
    if (mrb->exc) {
#ifdef BRIDGE_TRACE
        mrb_print_error(mrb);
#endif
        /* Do not try to describe it: printing would need the console, which
         * may be the very thing that failed. */
        mrb->exc = 0;
        ret = -ENOSYS;
    }
    else if (mrb_integer_p(result)) {
        ret = (long)mrb_integer(result);
    }
    else {
        ret = -ENOSYS;
    }
    mrb_gc_arena_restore(mrb, arena);
    return ret;
}

struct dispatch_call {
    mrb_state *mrb;
    long n, a[6];
};

static long
dispatch_trampoline(void *arg)
{
    struct dispatch_call *call = arg;
    return dispatch_in_ruby(call->mrb, call->n, call->a[0], call->a[1],
                            call->a[2], call->a[3], call->a[4], call->a[5]);
}

static long kernel_syscall_inner(long n, long a1, long a2, long a3,
                                 long a4, long a5, long a6);

/* The way into the kernel for every syscall. Nothing in here is preempted:
 * a tick that lands while the count is raised is acted on as it drops. */
long
kernel_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6)
{
    preempt_disable();
    long ret = kernel_syscall_inner(n, a1, a2, a3, a4, a5, a6);
    preempt_enable();
    return ret;
}

static long
kernel_syscall_inner(long n, long a1, long a2, long a3, long a4, long a5, long a6)
{
    mrb_state *mrb = vm_state();

    if (mrb && !in_dispatch && is_routed(n)) {
#ifdef BRIDGE_TRACE
        { char b[8]; int i=0; long v=n; if(!v)b[i++]='0';
          while(v){b[i++]=(char)('0'+v%10);v/=10;}
          serial_puts("<sys "); while(i--) serial_putc(b[i]); serial_puts(">"); }
#endif
        struct dispatch_call call = { mrb, n, { a1, a2, a3, a4, a5, a6 } };
        struct syscall_retry *retry = task_retry_state();
        long ret;
        for (;;) {
            in_dispatch = 1;
            ret = call_on_stack(dispatch_trampoline, &call,
                                dispatch_stack + sizeof(dispatch_stack));
            in_dispatch = 0;
            if (ret != WAIT_AGAIN) break;
            retry->retrying = 1;
            /* Other threads run until the next tick. A signal -- CRuby's
             * timer thread saying this one has an interrupt to look at --
             * ends the wait, and the call returns EINTR as poll would. */
            if (task_sleep_tick() == -EINTR) { ret = -EINTR; break; }
        }
        retry->retrying = 0;
        retry->deadline = SYSCALL_NO_DEADLINE;
#ifdef BRIDGE_TRACE
        { char b[16]; int i=0; long v=ret<0?-ret:ret; if(ret<0)serial_putc('-');
          if(!v)b[i++]='0'; while(v){b[i++]=(char)('0'+v%10);v/=10;}
          serial_puts("=> "); while(i--) serial_putc(b[i]); serial_puts("\n"); }
#endif
        return ret;
    }

    return kernel_syscall_c(n, a1, a2, a3, a4, a5, a6);
}
