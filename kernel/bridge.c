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
 *   CRuby, which has no idea the VM exists. */

#include <errno.h>
#include <stdint.h>

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/variable.h>

#include "kernel.h"

/* Room for every Linux syscall number in use. */
#define ROUTE_WORDS 8
static uint64_t routed[ROUTE_WORDS];

static int in_dispatch;
static struct RClass *syscall_module;

void
bridge_route(long number)
{
    if (number < 0 || number >= ROUTE_WORDS * 64) return;
    routed[number / 64] |= (uint64_t)1 << (number % 64);
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
    mrb_define_module_function(mrb, syscall_module, "peek64",
                               prim_peek64, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, syscall_module, "poke64",
                               prim_poke64, MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, syscall_module, "halt",
                               prim_halt, MRB_ARGS_NONE());
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

long
kernel_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6)
{
    mrb_state *mrb = vm_state();

    if (mrb && !in_dispatch && is_routed(n)) {
        in_dispatch = 1;
        long ret = dispatch_in_ruby(mrb, n, a1, a2, a3, a4, a5, a6);
        in_dispatch = 0;
        return ret;
    }

    return kernel_syscall_c(n, a1, a2, a3, a4, a5, a6);
}
