/* The PicoRuby VM, and the kernel's boot logic written in Ruby.
 *
 * The VM allocates from a pool in BSS rather than from libc. That is a
 * bare-metal requirement, and it will matter more later: once the syscall
 * dispatcher is written in Ruby, an allocation that reached musl's malloc
 * would call back into the VM that is servicing the call.
 *
 * puts and print are registered from C. In a full PicoRuby they come from the
 * picoruby-machine gem, which brings a console HAL and a dependency tree this
 * kernel has no use for; the console here is one serial port. */

#include <mruby.h>
#include <mruby/irep.h>
#include <mruby/string.h>
#include <mruby/proc.h>

#include "kernel.h"

/* The kernel must be compiled with the same mruby configuration as
 * libmruby.a. MRB_NO_BOXING makes mrb_value a struct rather than a packed
 * word, and MRB_INT64 makes mrb_int 64 bits; getting either wrong still links,
 * and then every type check in this file reads the wrong bytes. */
_Static_assert(sizeof(mrb_int) == 8, "MRB_INT64 must match libmruby.a");
_Static_assert(sizeof(mrb_value) > sizeof(void *), "MRB_NO_BOXING must match libmruby.a");

/* Declared by mruby's Estalloc integration rather than a public header. */
mrb_state *mrb_open_with_custom_alloc(void *mem, size_t bytes);

/* Generated from ruby/kernel/boot.rb by picorbc at build time. */
extern const uint8_t kernel_bytecode[];

/* In BSS, so it is outside the etext/edata range and mruby treats what lives
 * here as heap rather than as read-only data. */
#define VM_POOL_SIZE (8u * 1024u * 1024u)
static uint8_t vm_pool[VM_POOL_SIZE];

static void
write_value(mrb_state *mrb, mrb_value v)
{
    mrb_value s = mrb_obj_as_string(mrb, v);
    serial_write(RSTRING_PTR(s), (size_t)RSTRING_LEN(s));
}

static mrb_value
kernel_print(mrb_state *mrb, mrb_value self)
{
    mrb_value *argv;
    mrb_int argc;
    (void)self;

    mrb_get_args(mrb, "*", &argv, &argc);
    for (mrb_int i = 0; i < argc; i++) write_value(mrb, argv[i]);
    return mrb_nil_value();
}

static mrb_value
kernel_puts(mrb_state *mrb, mrb_value self)
{
    mrb_value *argv;
    mrb_int argc;
    (void)self;

    mrb_get_args(mrb, "*", &argv, &argc);
    if (argc == 0) {
        serial_putc('\n');
        return mrb_nil_value();
    }
    for (mrb_int i = 0; i < argc; i++) {
        write_value(mrb, argv[i]);
        serial_putc('\n');
    }
    return mrb_nil_value();
}

void
vm_start(void)
{
    mrb_state *mrb = mrb_open_with_custom_alloc(vm_pool, sizeof(vm_pool));
    if (!mrb) {
        serial_puts("vm: mrb_open failed\n");
        return;
    }

    mrb_define_method(mrb, mrb->kernel_module, "print", kernel_print, MRB_ARGS_ANY());
    mrb_define_method(mrb, mrb->kernel_module, "puts",  kernel_puts,  MRB_ARGS_ANY());

    mrb_load_irep(mrb, kernel_bytecode);

    /* An exception here means the kernel's own boot script failed, so say so
     * rather than continuing into an unknown state. */
    if (mrb->exc) {
        serial_puts("vm: exception in boot.rb\n");
        mrb_print_error(mrb);
    }

    mrb_close(mrb);
}
